import XCTest
@testable import VoicelyCore

final class GigaAMModelTests: XCTestCase {

    func testAllModelsIncludesGigaAMV3Option() {
        XCTAssertTrue(
            WhisperModel.all.contains(where: { $0.variant == "gigaam-v3-e2e-rnnt" }),
            "WhisperModel.all must expose GigaAM v3 as a selectable model option"
        )
    }

    func testGigaAMModelUsesDedicatedHuggingFaceCacheDirectory() {
        guard let model = WhisperModel.all.first(where: { $0.variant == "gigaam-v3-e2e-rnnt" }) else {
            XCTFail("expected GigaAM v3 model in WhisperModel.all")
            return
        }
        XCTAssertTrue(
            model.modelDirectoryPath.contains(".local/models/gigaam/v3-e2e-rnnt")
                || model.modelDirectoryPath.contains("Documents/huggingface/models/smkrv/gigaam-v3-e2e-rnnt-coreml"),
            "GigaAM model must not reuse WhisperKit's openai_whisper-* cache path; got: \(model.modelDirectoryPath)"
        )
    }

    func testGigaAMModelPrefersRepoLocalUntrackedDirectoryWhenRepoRootDetected() throws {
        guard let model = WhisperModel.all.first(where: { $0.variant == "gigaam-v3-e2e-rnnt" }) else {
            XCTFail("expected GigaAM v3 model in WhisperModel.all")
            return
        }
        let repoRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repoRoot) }
        FileManager.default.createFile(atPath: repoRoot.appendingPathComponent("Package.swift").path, contents: Data("// marker".utf8))
        try FileManager.default.createDirectory(at: repoRoot.appendingPathComponent("Sources"), withIntermediateDirectories: true)

        let resolved = model.resolvedModelDirectory(currentDirectoryPath: repoRoot.path)
        XCTAssertEqual(
            resolved.path,
            repoRoot.appendingPathComponent(".local/models/gigaam/v3-e2e-rnnt").path
        )
    }

    func testGigaAMModelFallsBackToDocumentsCacheOutsideRepo() {
        guard let model = WhisperModel.all.first(where: { $0.variant == "gigaam-v3-e2e-rnnt" }) else {
            XCTFail("expected GigaAM v3 model in WhisperModel.all")
            return
        }
        let resolved = model.resolvedModelDirectory(currentDirectoryPath: "/tmp/not-a-repo")
        XCTAssertTrue(
            resolved.path.contains("Documents/huggingface/models/smkrv/gigaam-v3-e2e-rnnt-coreml"),
            "outside repo root, GigaAM must fall back to Documents cache; got: \(resolved.path)"
        )
    }

    func testGigaAMTokenDecoderTurnsSentencePieceBoundariesIntoReadableText() {
        let text = GigaAMTokenDecoder.decode(
            tokenIDs: [0, 1, 2, 3],
            pieces: ["▁Привет", ",", "▁мир", "!"]
        )
        XCTAssertEqual(text, "Привет, мир!")
    }
}
