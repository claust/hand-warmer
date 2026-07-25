import Foundation
import Metal

/// Keeps the GPU saturated with pointless arithmetic, the same idea as the CPU
/// busy loops but on the other big power consumer in the SoC. Best-effort
/// throughout: if Metal is unavailable or anything fails to build, the booster
/// simply produces no heat rather than taking the session down.
final class GPUBurner {

    /// One `MTLDevice` for the process. Creating one is not free, and the chip
    /// availability check runs from the UI on every layout pass.
    private static let systemDevice = MTLCreateSystemDefaultDevice()

    /// Whether this device can run the booster at all. False on some Simulator
    /// configurations, which is also where the booster would be warming the
    /// Mac rather than a phone.
    static var isSupported: Bool { systemDevice != nil }

    private var stopFlag: StopFlag?

    /// Threads per dispatch. A power of two so it divides evenly into any
    /// threadgroup width the pipeline reports, which lets us use
    /// `dispatchThreadgroups` — supported everywhere — instead of the
    /// non-uniform `dispatchThreads`.
    private static let threadCount = 1 << 16

    /// How long one command buffer should take. Long enough that the encode
    /// overhead is noise and the GPU stays busy back to back. Deliberately
    /// ambitious: iOS will say when a dispatch is too greedy (see `ceiling`
    /// below), and settling just under a limit the system states beats
    /// guessing a safe number and leaving heat on the table.
    private static let targetGPUTime: TimeInterval = 0.016

    /// How many aborted buffers in a row before the booster gives up. The
    /// backoff below normally settles long before this.
    private static let failureLimit = 8

    /// How long the loop runs before it reports its throughput once.
    private static let settleReport: TimeInterval = 2

    static let minRounds = 256
    static let maxRounds = 1 << 20

    /// Inner-loop count for the next command buffer, steered towards
    /// `targetGPUTime` from how long the last one actually spent on the GPU.
    /// The right number differs by an order of magnitude between an A-series
    /// GPU and the Mac one the Simulator borrows, so it is measured rather
    /// than guessed.
    ///
    /// It has to be *GPU* time, not the wall clock around the submission. With
    /// six CPU cores in a busy loop next to it, the round trip through the
    /// scheduler runs to several milliseconds on its own; tuning against that
    /// drove the count straight to the floor, where the GPU finished early and
    /// idled through the rest of every frame — the opposite of the point.
    ///
    /// Pure and static so the clamping is testable without a GPU.
    static func nextRounds(current: Int, gpuTime: TimeInterval) -> Int {
        // A buffer that completed too fast to measure says only "much more than
        // this"; step up by the usual ceiling instead of dividing by ~zero.
        guard gpuTime > 0 else { return min(current * 4, maxRounds) }
        // Cap the per-step correction so one scheduling hiccup cannot slam the
        // loop to either end of its range.
        let scale = min(max(targetGPUTime / gpuTime, 0.25), 4)
        let next = Int((Double(current) * scale).rounded())
        return min(max(next, minRounds), maxRounds)
    }

    /// Four-wide fused multiply-add in a loop: the densest arithmetic per
    /// instruction the shader core offers. `fract` keeps the accumulator in a
    /// sane range without a branch, and the write to `out` is what stops the
    /// compiler from deleting the whole loop as dead.
    private static let source = """
        #include <metal_stdlib>
        using namespace metal;

        kernel void burn(device float *out [[buffer(0)]],
                         constant uint &rounds [[buffer(1)]],
                         uint gid [[thread_position_in_grid]]) {
            float4 acc = float4(gid + 1, gid + 2, gid + 3, gid + 4);
            const float4 k = float4(1.0000001, 1.0000002, 1.0000003, 1.0000004);
            for (uint i = 0; i < rounds; i++) {
                acc = fma(acc, k, float4(0.0001));
                acc = fract(acc) + float4(1.0);
            }
            out[gid] = acc.x + acc.y + acc.z + acc.w;
        }
        """

    func start() {
        guard stopFlag == nil, let device = Self.systemDevice else { return }

        let flag = StopFlag()
        stopFlag = flag

        // Everything from here — library compile included — happens off the
        // main thread: building the pipeline takes tens of milliseconds, which
        // is a visible hitch if it lands on the frame that lights the flame.
        let thread = Thread { Self.burn(device: device, flag: flag) }
        thread.name = "heat.worker.gpu"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        stopFlag?.set(true)
        stopFlag = nil
    }

    deinit {
        // The worker holds the flag, not this object, so without this it would
        // keep the GPU busy for the lifetime of the process.
        stopFlag?.set(true)
    }

    private static func burn(device: MTLDevice, flag: StopFlag) {
        guard let queue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: source, options: nil),
            let function = library.makeFunction(name: "burn"),
            let pipeline = try? device.makeComputePipelineState(function: function),
            let output = device.makeBuffer(
                length: threadCount * MemoryLayout<Float>.stride, options: .storageModeShared)
        else {
            heatLog.error("GPU booster: could not build the compute pipeline")
            return
        }
        heatLog.notice("GPU booster: burning on \(device.name, privacy: .public)")

        // Widths come back as powers of two, so this divides exactly and every
        // dispatched thread has real work.
        let groupWidth = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
        let threadsPerGroup = MTLSize(width: groupWidth, height: 1, depth: 1)
        let groups = MTLSize(width: threadCount / groupWidth, height: 1, depth: 1)

        var rounds = 4096
        var buffers = 0
        var failures = 0

        // iOS aborts a compute buffer that keeps the GPU from the UI, with
        // `kIOGPUCommandBufferCallbackErrorImpactingInteractivity`. That is not
        // a fault to stop over, it is the system stating a limit: back off,
        // remember the size that provoked it, and keep working under it. Left
        // uncapped the loop would grow straight back into the same abort every
        // few seconds.
        var ceiling = maxRounds
        let loopStarted = Date()
        var reported = false

        // One buffer executing while the next one is already queued behind it.
        // Without the overlap the GPU goes idle for the whole submit-and-return
        // round trip after every dispatch, which on a phone whose CPU cores are
        // all in a busy loop is longer than the work itself. Two is enough to
        // cover that gap and still bounds how much committed work has to drain
        // when the stop flag goes up.
        var inFlight: MTLCommandBuffer?
        defer { inFlight?.waitUntilCompleted() }

        while !flag.isSet {
            guard let buffer = queue.makeCommandBuffer(),
                let encoder = buffer.makeComputeCommandEncoder()
            else { return }

            var roundsArg = UInt32(rounds)
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(output, offset: 0, index: 0)
            encoder.setBytes(&roundsArg, length: MemoryLayout<UInt32>.size, index: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
            encoder.endEncoding()
            buffer.commit()

            guard let previous = inFlight else {
                inFlight = buffer
                continue
            }
            inFlight = buffer
            previous.waitUntilCompleted()

            if let error = previous.error {
                failures += 1
                ceiling = max(minRounds, rounds / 2)
                rounds = ceiling
                // Only the first one: a booster that floods the log while
                // backing off is worse than the problem it is reporting.
                if failures == 1 {
                    let reason = error.localizedDescription
                    heatLog.error("GPU booster: backing off to \(ceiling) rounds after \(reason, privacy: .public)")
                }
                if failures >= failureLimit {
                    heatLog.error("GPU booster: giving up after \(failureLimit) aborted buffers")
                    return
                }
                continue
            }

            failures = 0
            rounds = min(
                nextRounds(current: rounds, gpuTime: previous.gpuEndTime - previous.gpuStartTime),
                ceiling)

            // One line, once, a couple of seconds in: by then the round count
            // has settled, and "is the GPU actually doing anything" has an
            // answer with a number in it.
            buffers += 1
            if !reported, Date().timeIntervalSince(loopStarted) > settleReport {
                reported = true
                heatLog.notice("GPU booster: \(buffers) dispatches, settled at \(rounds) rounds")
            }
        }
    }
}
