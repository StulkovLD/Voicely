import XCTest
@testable import VoicelyCore

final class GigaAMMultilingualModelTests: XCTestCase {
    func testCatalogPinsExactAssetManifest() {
        XCTAssertEqual(GigaAMMultilingualAssetCatalog.assets.count, 6)
        XCTAssertEqual(GigaAMMultilingualAssetCatalog.totalExpectedByteCount, 442_080_520)
        for asset in GigaAMMultilingualAssetCatalog.assets {
            XCTAssertEqual(asset.expectedSHA256.count, 64)
            XCTAssertTrue(asset.expectedSHA256.allSatisfy(\.isHexDigit))
            XCTAssertGreaterThan(asset.expectedByteCount, 0)
        }
    }

    func testAssetsResolveToImmutableHuggingFaceRevision() {
        XCTAssertEqual(GigaAMMultilingualAssetCatalog.revision.count, 40)
        for asset in GigaAMMultilingualAssetCatalog.assets {
            let url = GigaAMMultilingualAssetCatalog.resolveURL(for: asset)
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "huggingface.co")
            XCTAssertTrue(url.path.contains(
                "/resolve/\(GigaAMMultilingualAssetCatalog.revision)/"
            ))
            XCTAssertFalse(url.path.contains("/resolve/main/"))
        }
    }

    func testModelDirectoryIsUserLocalAndVariantScoped() throws {
        let model = try XCTUnwrap(
            WhisperModel.all.first { $0.variant == "gigaam-multilingual-ctc" }
        )
        let path = model.modelDirectory.path
        XCTAssertTrue(path.contains("Documents/voicely/models/gigaam-multilingual-ctc"))
    }

    func testCompiledCachePoliciesDiffer() {
        XCTAssertEqual(
            GigaAMCompiledCachePolicy.multilingualCTC.expectedPackageNames,
            ["GigaAMMultilingualCTC.mlmodelc"]
        )
        XCTAssertNotEqual(
            GigaAMCompiledCachePolicy.multilingualCTC.sourceManifestSHA256,
            GigaAMCompiledCachePolicy.v3.sourceManifestSHA256
        )
        // The static v3 accessors keep their historical values for existing
        // call sites and fixtures.
        XCTAssertEqual(
            GigaAMCompiledCache.expectedPackageNames,
            GigaAMCompiledCachePolicy.v3.expectedPackageNames
        )
        XCTAssertEqual(
            GigaAMCompiledCache.sourceManifestSHA256,
            GigaAMCompiledCachePolicy.v3.sourceManifestSHA256
        )
    }

    func testCTCGreedyDecodeCollapsesRepeatsAndDropsBlanks() {
        // vocab: [" ", "п", "р", "и", "в", "е", "т"], blank = 7
        let vocab = [" ", "п", "р", "и", "в", "е", "т"]
        let blank = 7
        // "привет" with repeats and blanks, then a space and "т"
        let labels = [1, 1, 7, 2, 3, 3, 7, 4, 5, 6, 7, 0, 6, 6]
        XCTAssertEqual(
            GigaAMCTCDecoder.decode(frameLabels: labels, vocab: vocab, blankID: blank),
            "привет т"
        )
        // A repeated character separated by blank is kept twice.
        XCTAssertEqual(
            GigaAMCTCDecoder.decode(frameLabels: [1, 7, 1], vocab: vocab, blankID: blank),
            "пп"
        )
        // Pure blanks and out-of-range ids produce an empty string.
        XCTAssertEqual(
            GigaAMCTCDecoder.decode(frameLabels: [7, 7, -1, 99], vocab: vocab, blankID: blank),
            ""
        )
        // Leading and trailing spaces are trimmed.
        XCTAssertEqual(
            GigaAMCTCDecoder.decode(frameLabels: [0, 1, 0], vocab: vocab, blankID: blank),
            "п"
        )
    }

    func testScriptLanguageAttribution() {
        XCTAssertEqual(GigaAMCTCEngine.dominantScriptLanguage("привет мир"), "ru")
        XCTAssertEqual(GigaAMCTCEngine.dominantScriptLanguage("hello world"), "en")
        // Mixed-script words lean toward the dominant script.
        XCTAssertEqual(GigaAMCTCEngine.dominantScriptLanguage("deплoyment machine learning"), "en")
        // Central-Asian Cyrillic extensions are ambiguous across kk/ky/uz.
        XCTAssertNil(GigaAMCTCEngine.dominantScriptLanguage("сәлем қалайсың"))
        XCTAssertNil(GigaAMCTCEngine.dominantScriptLanguage(""))
    }
}
