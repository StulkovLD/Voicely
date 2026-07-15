import Foundation

struct GigaAMAssetDescriptor: Sendable, Equatable {
    let relativePath: String
    let expectedByteCount: Int64
    let expectedSHA256: String
}

struct GigaAMAssetCatalog {
    /// Provenance declared by the converter's model card. The upstream commit
    /// identifies the official GigaAM model input; it does not independently
    /// prove that the third-party Core ML conversion is equivalent.
    static let upstreamRepository = "ai-sage/GigaAM-v3"
    static let upstreamRevision = "7655ad717f8122257385bb4b2f373db3697e8680"

    /// Immutable Hugging Face commit published by the Core ML converter.
    /// Never replace this with `main`: every expected hash below belongs to this
    /// exact repository snapshot.
    static let repository = "smkrv/gigaam-v3-e2e-rnnt-coreml"
    static let revision = "846833ef075fde2a8e50521d093ddb9ed7b7fd45"

    /// SHA-256 values for LFS files come from Hugging Face's LFS metadata.
    /// Small Git files were hashed from their bytes at the immutable revision.
    static let assets: [GigaAMAssetDescriptor] = [
        .init(
            relativePath: "GigaAMv3Encoder.mlpackage/Manifest.json",
            expectedByteCount: 617,
            expectedSHA256: "6589ff6d3d3f814561449073ee12160bafb9f467c89159dc6a7240ef68235b04"
        ),
        .init(
            relativePath: "GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            expectedByteCount: 419_364,
            expectedSHA256: "f66bd914e5379bcddbbe7ef9d485c7e712443e5f5a880ce98a0cc0aafe3aeeeb"
        ),
        .init(
            relativePath: "GigaAMv3Encoder.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            expectedByteCount: 441_545_792,
            expectedSHA256: "cacb9c2b41a62b3fcdb3522c0571a3196648dfe39dfb1df9a31969239c8e3877"
        ),
        .init(
            relativePath: "GigaAMv3DecoderStep.mlpackage/Manifest.json",
            expectedByteCount: 617,
            expectedSHA256: "392239871ff24dbc7d1091dbe11982f202d8ce53e3ce9fb2f11cd671881ebbf9"
        ),
        .init(
            relativePath: "GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            expectedByteCount: 7_367,
            expectedSHA256: "71194a592055ad6a24ae4c980edcd52a25ea51c079b79f736033d07e00d6dfa5"
        ),
        .init(
            relativePath: "GigaAMv3DecoderStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            expectedByteCount: 2_297_280,
            expectedSHA256: "5b23897e619a78cea140dbf3677efc92a58ed7935542047df7d452f03cf98edd"
        ),
        .init(
            relativePath: "GigaAMv3JointStep.mlpackage/Manifest.json",
            expectedByteCount: 617,
            expectedSHA256: "378654b204d17a89750d807c95aa3bc4e3893bb808ca4c0e2f22259e3b210c42"
        ),
        .init(
            relativePath: "GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            expectedByteCount: 2_916,
            expectedSHA256: "9fa81aeaf320573eca794c17ad825d4c3ea7219f35414387732994df43a7bec3"
        ),
        .init(
            relativePath: "GigaAMv3JointStep.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            expectedByteCount: 1_356_098,
            expectedSHA256: "bbd11afc9f9954dea7ddf860e13e57a24ae908e061c80ac3e8b0b9693fb4886d"
        ),
        .init(
            relativePath: "tokens.json",
            expectedByteCount: 12_406,
            expectedSHA256: "260c932355adc98a7440d49887f72a2fca42256971ad07a4e91265e93859ff69"
        ),
        .init(
            relativePath: "model_info.json",
            expectedByteCount: 248,
            expectedSHA256: "94c1307cc14f9c4e23068b42ed743154bafc9fab1d2d6979888415adb249b5d7"
        ),
        .init(
            relativePath: "convert_info.json",
            expectedByteCount: 38,
            expectedSHA256: "4441cbcc93838917a7d3b7e2e6b71b50118cb5b34b5b1ecaa427474a68ae70b9"
        ),
    ]

    static let requiredRelativePaths = assets.map(\.relativePath)
    static let totalExpectedByteCount = assets.reduce(Int64(0)) {
        $0 + $1.expectedByteCount
    }

    static func resolveURL(for asset: GigaAMAssetDescriptor) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repository)/resolve/\(revision)/\(asset.relativePath)"
        components.queryItems = [URLQueryItem(name: "download", value: "1")]
        return components.url!
    }

    static func missingRelativePaths(
        in sourceRoot: URL,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        requiredRelativePaths.filter { relativePath in
            !fileExists(sourceRoot.appendingPathComponent(relativePath).path)
        }
    }
}
