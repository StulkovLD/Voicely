import Foundation

/// Which label scheme a punctuation model uses, so the restorer knows how to
/// turn per-token label ids into cased, punctuated words.
enum PunctuationLabelScheme: Sendable {
    /// RUPunct: "UPPER_/LOWER_/UPPER_TOTAL_" prefix + a named suffix.
    case ruPunct
    /// rpunct (felflare): two-char code `<punct><case>`, case O=lower / U=upper.
    case rpunct
}

/// Descriptor for one downloadable punctuation model (Core ML mlpackage +
/// vocab/labels/meta), hosted on Hugging Face.
struct PunctuationModelSource: Sendable {
    let language: String
    let repository: String
    let revision: String
    let packageName: String
    let compiledName: String
    let scheme: PunctuationLabelScheme
    let assets: [GigaAMAssetDescriptor]
    let directoryName: String

    var totalExpectedByteCount: Int64 { assets.reduce(0) { $0 + $1.expectedByteCount } }

    func resolveURL(for asset: GigaAMAssetDescriptor) -> URL {
        var c = URLComponents()
        c.scheme = "https"
        c.host = "huggingface.co"
        c.path = "/\(repository)/resolve/\(revision)/\(asset.relativePath)"
        c.queryItems = [URLQueryItem(name: "download", value: "1")]
        return c.url!
    }
}

/// GigaAM Multilingual emits lowercase, unpunctuated text (charwise CTC). These
/// small BERT token-classification models (both MIT / Apache-friendly) restore
/// punctuation and capitalization for Russian and English. Other languages get
/// a rule-based floor.
enum PunctuationCatalog {
    static let ru = PunctuationModelSource(
        language: "ru",
        repository: "StulkovLD/punctuation-ru-coreml",
        revision: "2554983e8a96c0f5234c6f107bc8cd264cb65962",
        packageName: "RUPunctSmall.mlpackage",
        compiledName: "RUPunctSmall.mlmodelc",
        scheme: .ruPunct,
        assets: [
            .init(relativePath: "RUPunctSmall.mlpackage/Manifest.json", expectedByteCount: 617, expectedSHA256: "d466a30c6656eaecf90ad2b7824ab0b79193855b32d80b2998036fa0ae5cb9d4"),
            .init(relativePath: "RUPunctSmall.mlpackage/Data/com.apple.CoreML/model.mlmodel", expectedByteCount: 35957, expectedSHA256: "0277ad69085e24dc93acc5e094ccef18a71a2bb32944dc5f24c3e5d29cc93574"),
            .init(relativePath: "RUPunctSmall.mlpackage/Data/com.apple.CoreML/weights/weight.bin", expectedByteCount: 57098818, expectedSHA256: "d4684faa0e14d99cdc42c1339fea96d6b969349fdbbe6a7418313f9912d2c7aa"),
            .init(relativePath: "vocab.txt", expectedByteCount: 1080666, expectedSHA256: "b99581da1a76076e7b13e40b2d83f7cf323ce2ea4150dd637902433f62c29aa2"),
            .init(relativePath: "labels.json", expectedByteCount: 633, expectedSHA256: "63d28bbaeb2e4b67007e6b201f98b583e10e0fabf62aba148c7dcffe72a9038e"),
            .init(relativePath: "tokenizer_meta.json", expectedByteCount: 132, expectedSHA256: "71cb22cccec0160afdfad0deb1b7422a2eb04a9ad0d176dd96fb6124c0ec3b69"),
        ],
        directoryName: "punctuation-ru-coreml"
    )

    static let en = PunctuationModelSource(
        language: "en",
        repository: "StulkovLD/punctuation-en-coreml",
        revision: "20c01ccc39f9e2cf4d139e6263971f2058f41da9",
        packageName: "ENPunctBert.mlpackage",
        compiledName: "ENPunctBert.mlmodelc",
        scheme: .rpunct,
        assets: [
            .init(relativePath: "ENPunctBert.mlpackage/Manifest.json", expectedByteCount: 617, expectedSHA256: "08bc62e43da8b4191bf18c3a3295825ec64e15e6813d251ed4b81d13791342d6"),
            .init(relativePath: "ENPunctBert.mlpackage/Data/com.apple.CoreML/model.mlmodel", expectedByteCount: 121731, expectedSHA256: "603a34cefd8fc4da0b0301f9d5db681c40087336479412e139886d340b129a8a"),
            .init(relativePath: "ENPunctBert.mlpackage/Data/com.apple.CoreML/weights/weight.bin", expectedByteCount: 217425950, expectedSHA256: "c71aaace218739af00adf004cd96590ada58efa428634feb966f049712e8228c"),
            .init(relativePath: "vocab.txt", expectedByteCount: 231507, expectedSHA256: "0f052197aac305fe42f378b5c61554b7bacb34b8be4af83fec2cfdcdffbc9973"),
            .init(relativePath: "labels.json", expectedByteCount: 90, expectedSHA256: "9ac4e1ffc5ff96e1bf481033e54775746ac07af26221b9b68ea998681cdec743"),
            .init(relativePath: "tokenizer_meta.json", expectedByteCount: 138, expectedSHA256: "fe736893c3e60e199c280489f92ed61943c130fd7057808b56124641196c5d55"),
        ],
        directoryName: "punctuation-en-coreml"
    )

    static func source(for language: String?) -> PunctuationModelSource? {
        switch language {
        case "ru": return ru
        case "en": return en
        default: return nil
        }
    }
}
