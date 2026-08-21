import CryptoKit
import Foundation
import XCTest
@testable import VoicelyCore

/// Serves one payload per relative path, and records what was asked for.
/// `.hang` reproduces the state that mattered: a transfer in flight when the
/// user hits Cancel.
private final class StubTransport: @unchecked Sendable, GigaAMAssetTransport {
    enum Behavior {
        case serve
        case hang
    }

    private let lock = NSLock()
    private let payloads: [String: Data]
    private let behavior: Behavior
    private var requested: [URL] = []
    private let started = XCTestExpectation(description: "transport started")

    init(payloads: [String: Data], behavior: Behavior = .serve) {
        self.payloads = payloads
        self.behavior = behavior
    }

    func download(
        from url: URL,
        to stagingURL: URL,
        onBytes: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        lock.withLock { requested.append(url) }
        started.fulfill()

        switch behavior {
        case .hang:
            // Outlives any reasonable test: the point is that cancellation, not
            // the clock, is what ends this.
            try await Task.sleep(for: .seconds(600))
        case .serve:
            let name = url.lastPathComponent
            guard let data = payloads[name] else {
                throw URLError(.fileDoesNotExist)
            }
            try data.write(to: stagingURL)
            onBytes(Int64(data.count), Int64(data.count))
        }
    }

    func callCount() -> Int { lock.withLock { requested.count } }
    func waitUntilStarted(_ test: XCTestCase, timeout: TimeInterval = 5) {
        test.wait(for: [started], timeout: timeout)
    }
}

final class WhisperKitAssetInstallerTests: XCTestCase {
    private var root: URL!

    private let variant = "medium"
    private let revision = "0000000000000000000000000000000000000000"

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisperkit-installer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
        try super.tearDownWithError()
    }

    // MARK: - Fixtures

    private func descriptor(path: String, data: Data) -> GigaAMAssetDescriptor {
        GigaAMAssetDescriptor(
            relativePath: path,
            expectedByteCount: Int64(data.count),
            expectedSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        )
    }

    /// Two assets, one of them nested, mirroring the real `.mlmodelc` shape.
    private func fixture() -> (assets: [GigaAMAssetDescriptor], payloads: [String: Data]) {
        let weights = Data(repeating: 0xAB, count: 4_096)
        let config = Data("{\"model\":\"medium\"}".utf8)
        let assets = [
            descriptor(path: "AudioEncoder.mlmodelc/weights/weight.bin", data: weights),
            descriptor(path: "config.json", data: config),
        ]
        return (assets, ["weight.bin": weights, "config.json": config])
    }

    private func install(
        assets: [GigaAMAssetDescriptor],
        transport: StubTransport
    ) async throws -> GigaAMAssetInstallResult? {
        try await Self.install(
            variant: variant,
            sourceRoot: root,
            assets: assets,
            revision: revision,
            transport: transport
        )
    }

    /// Static so a detached install can be started without capturing the
    /// non-Sendable test case.
    private static func install(
        variant: String,
        sourceRoot: URL,
        assets: [GigaAMAssetDescriptor],
        revision: String,
        transport: StubTransport
    ) async throws -> GigaAMAssetInstallResult? {
        try await WhisperKitAssetInstaller.install(
            variant: variant,
            sourceRoot: sourceRoot,
            assets: assets,
            revision: revision,
            transport: transport
        )
    }

    // MARK: - Cancellation

    /// The regression this whole path exists for. `WhisperKit.download` ran to
    /// completion no matter what the user pressed; the installer must stop.
    func testCancellationStopsInstallInFlight() async throws {
        let (assets, _) = fixture()
        let transport = StubTransport(payloads: [:], behavior: .hang)
        let capturedRoot = root!
        let capturedVariant = variant
        let capturedRevision = revision

        let task = Task {
            try await WhisperKitAssetInstaller.install(
                variant: capturedVariant,
                sourceRoot: capturedRoot,
                assets: assets,
                revision: capturedRevision,
                transport: transport
            )
        }
        transport.waitUntilStarted(self)
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled install must not report success")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    /// A cancelled install must not leave a marker behind: the next launch would
    /// read the half-written model as intact and hand it to CoreML.
    func testCancelledInstallLeavesNoMarker() async throws {
        let (assets, _) = fixture()
        let transport = StubTransport(payloads: [:], behavior: .hang)
        let capturedRoot = root!
        let capturedVariant = variant
        let capturedRevision = revision

        let task = Task {
            try await WhisperKitAssetInstaller.install(
                variant: capturedVariant,
                sourceRoot: capturedRoot,
                assets: assets,
                revision: capturedRevision,
                transport: transport
            )
        }
        transport.waitUntilStarted(self)
        task.cancel()
        _ = try? await task.value

        XCTAssertFalse(
            WhisperKitAssetInstaller.isInstalled(
                sourceRoot: root,
                assets: assets,
                revision: revision
            ),
            "a cancelled install must not read as installed"
        )
    }

    // MARK: - Install

    func testInstallFetchesAssetsAndSeals() async throws {
        let (assets, payloads) = fixture()
        let transport = StubTransport(payloads: payloads)

        let result = try await install(assets: assets, transport: transport)

        XCTAssertEqual(result?.downloadedAssetCount, 2)
        XCTAssertEqual(transport.callCount(), 2)
        XCTAssertTrue(
            WhisperKitAssetInstaller.isInstalled(
                sourceRoot: root,
                assets: assets,
                revision: revision
            )
        )
        for asset in assets {
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: root.appendingPathComponent(asset.relativePath).path
                ),
                "\(asset.relativePath) must be live after install"
            )
        }
    }

    /// Fix 1.2 (offline start): an installed model must never touch the network.
    func testInstalledModelSkipsNetworkEntirely() async throws {
        let (assets, payloads) = fixture()
        _ = try await install(assets: assets, transport: StubTransport(payloads: payloads))

        let offline = StubTransport(payloads: [:], behavior: .hang)
        let result = try await install(assets: assets, transport: offline)

        XCTAssertNil(result, "an installed model reports nothing to do")
        XCTAssertEqual(offline.callCount(), 0, "an installed model must not hit the network")
    }

    /// The marker is keyed to the pinned revision, so moving the pin forces a
    /// re-verify rather than silently serving the previous snapshot.
    func testMarkerFromAnotherRevisionIsRejected() async throws {
        let (assets, payloads) = fixture()
        _ = try await install(assets: assets, transport: StubTransport(payloads: payloads))

        XCTAssertFalse(
            WhisperKitAssetInstaller.isInstalled(
                sourceRoot: root,
                assets: assets,
                revision: String(repeating: "f", count: 40)
            ),
            "a marker from another revision must not be trusted"
        )
    }

    /// A truncated asset must be caught even with the marker in place — that is
    /// the check the old `directorySize >= 50% of expected` heuristic missed.
    func testTruncatedAssetIsNotReportedInstalled() async throws {
        let (assets, payloads) = fixture()
        _ = try await install(assets: assets, transport: StubTransport(payloads: payloads))

        let victim = root.appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin")
        try Data(repeating: 0xAB, count: 16).write(to: victim)

        XCTAssertFalse(
            WhisperKitAssetInstaller.isInstalled(
                sourceRoot: root,
                assets: assets,
                revision: revision
            )
        )
    }

    /// Rejected copies are dead weight once every byte is verified; a 3 GB model
    /// would otherwise keep a 3 GB `.quarantine` beside it forever.
    func testSealClearsQuarantine() async throws {
        let (assets, payloads) = fixture()
        let quarantine = root.appendingPathComponent(".quarantine/stale", isDirectory: true)
        try FileManager.default.createDirectory(
            at: quarantine,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Data(repeating: 0, count: 128).write(to: quarantine.appendingPathComponent("junk.bin"))

        _ = try await install(assets: assets, transport: StubTransport(payloads: payloads))

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent(".quarantine").path
            ),
            "install must not leave rejected copies behind"
        )
    }

    // MARK: - Catalog

    /// Every `.whisperKit` model must resolve to pinned assets, or its download
    /// path fails at runtime with "No pinned assets". The shipped catalog
    /// carries no `.whisperKit` model since 2026-08-19 (owner's call), so this
    /// holds vacuously until one returns — then it bites again.
    func testEveryWhisperKitModelIsPinned() {
        let whisperModels = WhisperModel.all.filter { $0.backend == .whisperKit }

        for model in whisperModels {
            XCTAssertNotNil(
                WhisperKitAssetCatalog.assets(forVariant: model.variant),
                "\(model.variant) has no pinned assets"
            )
        }
    }

    /// `sizeBytes` drives the disk precheck and the user-facing size label, so it
    /// must stay within 10% of what the catalog actually fetches.
    func testCatalogTotalsAgreeWithDeclaredModelSizes() throws {
        for model in WhisperModel.all where model.backend == .whisperKit {
            let assets = try XCTUnwrap(WhisperKitAssetCatalog.assets(forVariant: model.variant))
            let actual = assets.reduce(Int64(0)) { $0 + $1.expectedByteCount }
            let declared = Int64(model.sizeBytes)
            let drift = abs(Double(actual - declared)) / Double(declared)
            XCTAssertLessThan(
                drift, 0.1,
                "\(model.variant): catalog is \(actual) bytes, sizeBytes claims \(declared)"
            )
        }
    }

    func testCatalogURLsPinTheRevision() throws {
        let assets = try XCTUnwrap(WhisperKitAssetCatalog.assets(forVariant: "medium"))
        let asset = try XCTUnwrap(assets.first)
        let url = WhisperKitAssetCatalog.resolveURL(for: asset, variant: "medium")

        XCTAssertEqual(url.host, "huggingface.co")
        XCTAssertTrue(
            url.path.hasPrefix(
                "/\(WhisperKitAssetCatalog.repository)/resolve/\(WhisperKitAssetCatalog.revision)/openai_whisper-medium/"
            ),
            "URL must pin the catalog revision, got \(url.path)"
        )
        XCTAssertFalse(url.path.contains("/main/"), "never resolve against a moving ref")
    }
}
