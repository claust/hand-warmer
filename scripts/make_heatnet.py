#!/usr/bin/env python3
"""Generate HeatNet.mlpackage, the Neural Engine booster's load generator.

The model computes nothing meaningful. It is a stack of fp16 convolutions
chosen purely because convolution is what the Apple Neural Engine accelerates,
so running it keeps the ANE — and only the ANE — busy.

The shape is picked for arithmetic per byte of weights: a large spatial size
costs nothing in file size, so the network is wide and shallow rather than
deep. Roughly 22 GFLOP per prediction out of ~1.3 MB of weights.

The generated .mlpackage is committed to the repo, so this script only needs
running if the load ever needs retuning. It needs coremltools, which does not
ship with macOS:

    python3.11 -m venv /tmp/cmt && /tmp/cmt/bin/pip install coremltools
    /tmp/cmt/bin/python scripts/make_heatnet.py
"""

import argparse
import pathlib

import numpy as np
import coremltools as ct
from coremltools.converters.mil import Builder as mb

CHANNELS = 96
SIDE = 128
LAYERS = 8


def build(path: pathlib.Path) -> None:
    @mb.program(input_specs=[mb.TensorSpec(shape=(1, CHANNELS, SIDE, SIDE))])
    def heatnet(x):
        for i in range(LAYERS):
            # Seeded per layer so regenerating produces the identical package
            # rather than a fresh multi-megabyte blob in every diff. The scale
            # keeps activations from either exploding or dying out across the
            # stack — not that correctness matters here, but denormals and
            # infinities are a needless way to make timings strange.
            rng = np.random.default_rng(i)
            weight = (rng.standard_normal((CHANNELS, CHANNELS, 3, 3)) * 0.04).astype(np.float32)
            x = mb.conv(x=x, weight=weight, pad_type="same")
            x = mb.relu(x=x)
        # Collapse the spatial dimensions on the way out. Without this the
        # model hands back a 3 MB tensor per prediction that nobody reads,
        # which is memory bandwidth spent on nothing at a point where the app
        # is already busy.
        return mb.reduce_mean(x=x, axes=[2, 3])

    model = ct.convert(
        heatnet,
        # fp16 throughout, including the inputs and outputs: it is the ANE's
        # native precision, and it is what keeps the whole graph resident there
        # instead of being split back onto the CPU. Float32 IO would also put a
        # 1.5-million-element cast on either end of every prediction.
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.TensorType(name="x", shape=(1, CHANNELS, SIDE, SIDE), dtype=np.float16)],
        outputs=[ct.TensorType(dtype=np.float16)],
        compute_units=ct.ComputeUnit.CPU_AND_NE,
        minimum_deployment_target=ct.target.iOS17,
    )
    model.short_description = "Load generator for the Neural Engine booster. Computes nothing useful."
    model.save(str(path))
    print(f"wrote {path}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "output",
        nargs="?",
        default=pathlib.Path(__file__).resolve().parent.parent / "HandWarmer" / "HeatNet.mlpackage",
        type=pathlib.Path,
    )
    build(parser.parse_args().output)
