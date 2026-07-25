import CoreML
import Foundation

/// Keeps the Apple Neural Engine busy by running a bundled model in a loop.
///
/// There is no public API for putting arbitrary work on the ANE — it runs
/// compiled network graphs and nothing else — so the app ships `HeatNet`, a
/// stack of fp16 convolutions that computes nothing and exists only to be
/// expensive. See `scripts/make_heatnet.py`.
///
/// Worth knowing before expecting much from this booster: the ANE is built for
/// inference *per watt*. Saturated, it draws on the order of a watt, against
/// the several the CPU cluster and the GPU pull. It is the smallest of the
/// three heat sources by some way.
final class NeuralBurner {

    /// The compiled model Xcode produces from `HeatNet.mlpackage` at build
    /// time. Looked up once: this is read from the UI on every layout pass.
    private static let modelURL = Bundle.main.url(forResource: "HeatNet", withExtension: "mlmodelc")

    static var isSupported: Bool { modelURL != nil }

    private var stopFlag: StopFlag?

    func start() {
        guard stopFlag == nil, let url = Self.modelURL else { return }

        let flag = StopFlag()
        stopFlag = flag

        // Loading a model is slow — it is compiled for the ANE and handed to
        // the inference daemon — so none of this happens on the main thread.
        let thread = Thread { Self.burn(url: url, flag: flag) }
        thread.name = "heat.worker.ane"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func stop() {
        stopFlag?.set(true)
        stopFlag = nil
    }

    deinit {
        // The worker holds the flag, not this object, so without this it would
        // keep predicting for the lifetime of the process.
        stopFlag?.set(true)
    }

    private static func burn(url: URL, flag: StopFlag) {
        let config = MLModelConfiguration()
        // Deliberately not `.all`: the GPU is its own booster with its own
        // chip, and letting Core ML quietly borrow it would make that chip lie
        // about what is running. Ops the ANE cannot take still fall back to the
        // CPU, which is no loss here — it makes heat too.
        config.computeUnits = .cpuAndNeuralEngine

        guard let model = try? MLModel(contentsOf: url, configuration: config),
            let input = makeInput(for: model)
        else {
            heatLog.error("Neural booster: could not load HeatNet")
            return
        }
        heatLog.notice("Neural booster: HeatNet loaded")

        var predictions = 0
        let loopStarted = Date()
        var reported = false

        while !flag.isSet {
            // The result is discarded on purpose; the point is the work, not
            // the answer. A failing prediction would fail every time, so it
            // ends the loop rather than spinning on the error path.
            do {
                _ = try model.prediction(from: input)
            } catch {
                heatLog.error("Neural booster: prediction failed: \(error.localizedDescription)")
                return
            }

            // One line, once, a couple of seconds in — the same one-shot
            // throughput report the GPU booster emits, and for the same
            // reason: a booster that silently does nothing looks identical to
            // one that works.
            predictions += 1
            if !reported, Date().timeIntervalSince(loopStarted) > 2 {
                reported = true
                heatLog.notice("Neural booster: \(predictions) predictions in the first 2s")
            }
        }
    }

    /// One input tensor, reused for every prediction. Shape and name come from
    /// the model rather than being hard-coded, so retuning the network in
    /// `make_heatnet.py` cannot silently break the loader.
    private static func makeInput(for model: MLModel) -> MLDictionaryFeatureProvider? {
        guard let (name, description) = model.modelDescription.inputDescriptionsByName.first,
            let constraint = description.multiArrayConstraint,
            let array = try? MLMultiArray(shape: constraint.shape, dataType: constraint.dataType)
        else { return nil }

        // A freshly allocated MLMultiArray is not documented to be zeroed, and
        // NaNs or denormals left over from whatever held the page before would
        // be a strange thing to time the loop against.
        array.withUnsafeMutableBytes { pointer, _ in
            guard let base = pointer.baseAddress else { return }
            memset(base, 0, pointer.count)
        }

        return try? MLDictionaryFeatureProvider(dictionary: [name: MLFeatureValue(multiArray: array)])
    }
}
