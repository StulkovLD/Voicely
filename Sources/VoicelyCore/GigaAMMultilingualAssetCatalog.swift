import Foundation

/// GigaAM Multilingual CTC (220M conformer encoder + charwise CTC head).
/// Converted from ai-sage/GigaAM-Multilingual (revision `ctc`, MIT) to a
/// single fp16 Core ML mlprogram, published on Hugging Face like the other
/// model backends. Never replace the revision with `main`: every expected
/// hash below belongs to this exact repository snapshot.
struct GigaAMMultilingualAssetCatalog {
    static let upstreamRepository = "ai-sage/GigaAM-Multilingual"
    /// MD5 of the source checkpoint multilingual_ctc.ckpt from the official
    /// Sber CDN, as pinned by the gigaam package (_MODEL_HASHES).
    static let upstreamCheckpointMD5 = "5379d887c53ccd9cb95981e2a1832720"

    static let repository = "StulkovLD/gigaam-multilingual-ctc-coreml"
    static let revision = "ab9175850971b212640fd4b2404feacb658219f5"

    static let assets: [GigaAMAssetDescriptor] = [
        .init(
            relativePath: "GigaAMMultilingualCTC.mlpackage/Manifest.json",
            expectedByteCount: 617,
            expectedSHA256: "6079c8fa692dbcabe1479e5d238912193d6504741cf6183859100068b253c124"
        ),
        .init(
            relativePath: "GigaAMMultilingualCTC.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            expectedByteCount: 405_836,
            expectedSHA256: "f3142f19fe06a68a5789070b2a0cd07aeea7ea7dfc903afa388b5e6a29db680a"
        ),
        .init(
            relativePath: "GigaAMMultilingualCTC.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            expectedByteCount: 441_673_294,
            expectedSHA256: "5e39766e9fa5283c5f9346df0e13bab3d2b998e3d7ac678842ef8558d4a19e99"
        ),
        .init(
            relativePath: "tokens.json",
            expectedByteCount: 392,
            expectedSHA256: "b4bb373f5d37285d5993071d351aaa5d2f77b4988991484a589c88e30b756de2"
        ),
        .init(
            relativePath: "model_info.json",
            expectedByteCount: 324,
            expectedSHA256: "57da3294302a5ebbd0a5c2f35f72b74ed4a6c89d13e036bc46cdef4cf66663c1"
        ),
        .init(
            relativePath: "convert_info.json",
            expectedByteCount: 57,
            expectedSHA256: "34008780d569fa1aa391ea0903c561ab441400a44ac3e357dee39221045b0b23"
        ),
    ]

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
}
