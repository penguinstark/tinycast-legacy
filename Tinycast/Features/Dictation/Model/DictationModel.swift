import Foundation

enum DictationModel: String, CaseIterable, Identifiable, Codable, Sendable {
    struct ParakeetConfiguration: Sendable {
        let joint: String
        let blankToken: Int
        let encoderUsesGPU: Bool
    }
    case redux
    case ultra

    var id: Self { self }
    var title: String { "Parakeet · \(variantTitle)" }
    var variantTitle: String {
        switch self {
        case .ultra: "Ultra"
        case .redux: "Redux"
        }
    }

    var summary: String {
        switch self {
        case .redux: String(localized: "Lightweight and efficient.")
        case .ultra: String(localized: "Higher accuracy, larger download.")
        }
    }

    var parakeetConfiguration: ParakeetConfiguration {
        .init(joint: "JointDecisionv3", blankToken: 8192, encoderUsesGPU: self == .redux)
    }
    var coverage: String { String(localized: "25 languages") }
    var folderName: String { "parakeet-\(rawValue)" }
    var approximateInstalledMegabytes: Int {
        switch self {
        case .ultra: 632
        case .redux: 220
        }
    }

    var components: Set<String> {
        [
            "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc",
            parakeetConfiguration.joint + ".mlmodelc", "parakeet_vocab.json",
        ]
    }

    var requiredFiles: Set<String> { components }

    var repository: String { "FluidInference/\(folderName)-coreml" }

    var revision: String {
        switch self {
        case .ultra: "95eaa59a39d4394f047a4dc5cce480388a60d1b6"
        case .redux: "8c5ef97a29cd120dc76b354b3f22b7fec3b486f9"
        }
    }
}
