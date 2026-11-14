import CoreML
import Foundation

enum NativeGazeModelStore {
    enum Failure: LocalizedError {
        case invalidPair
        var errorDescription: String? {
            "Choose a folder containing compatible FLX-L.mlmodelc and FLX-R.mlmodelc models. The existing models were kept."
        }
    }

    /// Installs only a validated pair, with one directory replacement as the commit point.
    /// Called off the main actor. Camera processing must be stopped before replacement.
    static func install(from source: URL, at destination: URL = NativeGazeProcessor.modelsDirectoryURL) throws {
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let files = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try files.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".gaze-install-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        for side in ["L", "R"] {
            let name = "FLX-\(side).mlmodelc"
            try files.copyItem(at: source.appendingPathComponent(name), to: staging.appendingPathComponent(name))
        }
        // Validate the copied pair, so validation covers exactly what will be installed.
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        for side in ["L", "R"] {
            let url = staging.appendingPathComponent("FLX-\(side).mlmodelc")
            guard let model = try? MLModel(contentsOf: url, configuration: configuration) else { throw Failure.invalidPair }
            for (name, shape) in [("inputs_input_img", [1, 48, 64, 3]), ("inputs_input_fp", [1, 48, 64, 12]), ("inputs_input_ang", [1, 2])] {
                guard let constraint = model.modelDescription.inputDescriptionsByName[name]?.multiArrayConstraint,
                      constraint.shape.map(\.intValue) == shape, constraint.dataType == .float32 else { throw Failure.invalidPair }
            }
            for name in ["flow", "light"] {
                guard let constraint = model.modelDescription.outputDescriptionsByName[name]?.multiArrayConstraint,
                      constraint.shape.map(\.intValue) == [1, 48, 64, 2], constraint.dataType == .float32 else { throw Failure.invalidPair }
            }
        }
        if files.fileExists(atPath: destination.path) {
            _ = try files.replaceItemAt(destination, withItemAt: staging)
        } else {
            try files.moveItem(at: staging, to: destination)
        }
    }
}
