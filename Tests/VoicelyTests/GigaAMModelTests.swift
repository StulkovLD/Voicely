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
            model.resolvedModelDirectory(environment: [:]).path
                .contains("Documents/huggingface/models/smkrv/gigaam-v3-e2e-rnnt-coreml"),
            "GigaAM production storage must be stable and independent of cwd"
        )
    }

    func testGigaAMModelUsesRepoLocalDirectoryOnlyForExplicitVerifiedDebugOverride() throws {
        guard let model = WhisperModel.all.first(where: { $0.variant == "gigaam-v3-e2e-rnnt" }) else {
            XCTFail("expected GigaAM v3 model in WhisperModel.all")
            return
        }
        let repoRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try makeRepositoryFixture(at: repoRoot)
        defer { try? FileManager.default.removeItem(at: repoRoot) }

        let resolved = model.resolvedModelDirectory(environment: [
            "VOICELY_GIGAAM_DEV_REPO_ROOT": repoRoot.path,
        ])
        XCTAssertEqual(
            resolved.path,
            repoRoot.appendingPathComponent(".local/models/gigaam/v3-e2e-rnnt").path
        )
    }

    func testGigaAMModelRejectsGenericPackageAsDevelopmentOverride() throws {
        guard let model = WhisperModel.all.first(where: { $0.variant == "gigaam-v3-e2e-rnnt" }) else {
            XCTFail("expected GigaAM v3 model in WhisperModel.all")
            return
        }
        let fakeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: fakeRoot.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: fakeRoot.appendingPathComponent("Package.swift").path,
            contents: Data("let package = Package(name: \"AnotherProduct\")".utf8)
        )
        defer { try? FileManager.default.removeItem(at: fakeRoot) }

        let resolved = model.resolvedModelDirectory(environment: [
            "VOICELY_GIGAAM_DEV_REPO_ROOT": fakeRoot.path,
        ])
        XCTAssertTrue(
            resolved.path.contains("Documents/huggingface/models/smkrv/gigaam-v3-e2e-rnnt-coreml"),
            "a generic Swift package must not redirect model storage"
        )
    }

    func testGigaAMModelRejectsSymlinkedDevelopmentRoot() throws {
        guard let model = WhisperModel.all.first(where: { $0.variant == "gigaam-v3-e2e-rnnt" }) else {
            XCTFail("expected GigaAM v3 model in WhisperModel.all")
            return
        }
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let repoRoot = parent.appendingPathComponent("repo")
        let link = parent.appendingPathComponent("repo-link")
        try makeRepositoryFixture(at: repoRoot)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repoRoot)
        defer { try? FileManager.default.removeItem(at: parent) }

        let resolved = model.resolvedModelDirectory(environment: [
            "VOICELY_GIGAAM_DEV_REPO_ROOT": link.path,
        ])
        XCTAssertTrue(resolved.path.contains("Documents/huggingface/models/smkrv/gigaam-v3-e2e-rnnt-coreml"))
    }

    func testGigaAMTokenDecoderTurnsSentencePieceBoundariesIntoReadableText() {
        let text = GigaAMTokenDecoder.decode(
            tokenIDs: [0, 1, 2, 3],
            pieces: ["▁Привет", ",", "▁мир", "!"]
        )
        XCTAssertEqual(text, "Привет, мир!")
    }

    func testCancellationInvalidatesCurrentRequestButNotTheNextOne() throws {
        let cancellation = GigaAMRequestCancellation()
        let first = cancellation.begin()
        cancellation.cancelCurrentRequests()
        let second = cancellation.begin()

        XCTAssertThrowsError(try cancellation.check(first)) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertNoThrow(try cancellation.check(second))
    }

    private func makeRepositoryFixture(at root: URL) throws {
        let core = root.appendingPathComponent("Sources/VoicelyCore")
        let cli = root.appendingPathComponent("Sources/VoicelyCLI")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: core, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cli, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: root.appendingPathComponent("Package.swift").path,
            contents: Data("let package = Package(name: \"Voicely\", targets: [.target(name: \"VoicelyCore\")])".utf8)
        )
        FileManager.default.createFile(
            atPath: core.appendingPathComponent("GigaAMEngine.swift").path,
            contents: Data("// identity".utf8)
        )
        FileManager.default.createFile(
            atPath: cli.appendingPathComponent("Voicely.swift").path,
            contents: Data("// identity".utf8)
        )
    }
}
