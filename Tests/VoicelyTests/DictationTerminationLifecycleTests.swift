import AVFoundation
import Darwin
import Foundation
import XCTest
@testable import Voicely

@MainActor
final class DictationTerminationLifecycleTests: XCTestCase {
    private actor SuspensionGate {
        private var started = false
        private var startedWaiter: CheckedContinuation<Void, Never>?
        private var releaseWaiter: CheckedContinuation<Void, Never>?

        func suspend() async {
            started = true
            startedWaiter?.resume()
            startedWaiter = nil
            await withCheckedContinuation { continuation in
                releaseWaiter = continuation
            }
        }

        func waitUntilStarted() async {
            if started { return }
            await withCheckedContinuation { continuation in
                startedWaiter = continuation
            }
        }

        func release() {
            releaseWaiter?.resume()
            releaseWaiter = nil
        }
    }

    func testQuitDuringRecordingCommitsDurableAudioExactlyOnce() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try DictationRecoveryStore(rootURL: fixture.privateRoot)
        let session = try makeSession(store: store)
        _ = session.finishCapture(reason: "capture_stopped")
        let gate = DictationTerminationGate()
        var commits = 0

        XCTAssertTrue(gate.commit {
            commits += 1
            return session.complete(
                transcriptURL: fixture.visibleRoot
                    .appendingPathComponent("dictation.md")
            )
        })
        XCTAssertFalse(gate.commit {
            commits += 1
            return true
        })

        XCTAssertEqual(commits, 1)
        XCTAssertEqual(gate.current, .committed)
        let relaunched = try DictationRecoveryStore(rootURL: fixture.privateRoot)
        let report = relaunched.exportPendingArtifacts(to: fixture.visibleRoot)
        XCTAssertTrue(report.exported.isEmpty)
        XCTAssertEqual(report.retainedFailureCount, 0)
        XCTAssertTrue(try directoryNames(at: fixture.privateRoot).isEmpty)
    }

    func testQuitWaitsForInFlightASRBeforeSingleCommit() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try DictationRecoveryStore(rootURL: fixture.privateRoot)
        let session = try makeSession(store: store)
        _ = session.finishCapture(reason: "capture_stopped")
        let suspension = SuspensionGate()
        let gate = DictationTerminationGate()
        var commits = 0

        let finalize = Task { @MainActor in
            await suspension.suspend()
            return gate.commit {
                commits += 1
                return session.complete(
                    transcriptURL: fixture.visibleRoot
                        .appendingPathComponent("tail.md")
                )
            }
        }

        await suspension.waitUntilStarted()
        XCTAssertEqual(gate.current, .pending)
        XCTAssertEqual(commits, 0)
        await suspension.release()
        let finalized = await finalize.value
        XCTAssertTrue(finalized)
        XCTAssertEqual(gate.current, .committed)
        XCTAssertEqual(commits, 1)
    }

    func testTimeoutRecoveryWinsOverLateTranscriptionCommit() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try DictationRecoveryStore(rootURL: fixture.privateRoot)
        let session = try makeSession(store: store)
        _ = session.finishCapture(reason: "capture_stopped")
        let gate = DictationTerminationGate()

        XCTAssertTrue(gate.recover(reason: "termination_grace_timeout") {
            session.preserve(reason: "termination_grace_timeout")
        })
        var lateCommitRuns = 0
        XCTAssertFalse(gate.commit {
            lateCommitRuns += 1
            return session.complete(
                transcriptURL: fixture.visibleRoot
                    .appendingPathComponent("late.md")
            )
        })
        XCTAssertEqual(lateCommitRuns, 0)
        XCTAssertEqual(
            gate.current,
            .recovered("termination_grace_timeout")
        )

        let relaunched = try DictationRecoveryStore(rootURL: fixture.privateRoot)
        let report = relaunched.exportPendingArtifacts(to: fixture.visibleRoot)
        let artifact = try XCTUnwrap(report.exported.first)
        XCTAssertEqual(report.exported.count, 1)
        XCTAssertEqual(report.retainedFailureCount, 0)
        XCTAssertEqual(artifact.reason, "termination_grace_timeout")
        let file = try AVAudioFile(forReading: artifact.audioURL)
        XCTAssertEqual(file.length, 1_600)
        let manifest = try manifestObject(at: artifact.manifestURL)
        XCTAssertEqual(manifest["id"] as? String, artifact.id.uuidString.lowercased())
        XCTAssertEqual(manifest["reason"] as? String, "termination_grace_timeout")
        XCTAssertEqual(manifest["state"] as? String, "pending")
        XCTAssertEqual(manifest["sampleCount"] as? Int, 1_600)
    }

    func testNextLaunchResumesClaimAndExportIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstLaunch = try DictationRecoveryStore(rootURL: fixture.privateRoot)
        let session = try makeSession(store: firstLaunch)
        XCTAssertTrue(session.preserve(reason: "forced_termination"))

        let pendingName = try XCTUnwrap(
            try directoryNames(at: fixture.privateRoot).first
        )
        XCTAssertTrue(pendingName.hasSuffix(".pending"))
        let recoveringName = pendingName.replacingOccurrences(
            of: ".pending",
            with: ".recovering"
        )
        try FileManager.default.moveItem(
            at: fixture.privateRoot.appendingPathComponent(pendingName),
            to: fixture.privateRoot.appendingPathComponent(recoveringName)
        )

        let nextLaunch = try DictationRecoveryStore(rootURL: fixture.privateRoot)
        let firstReport = nextLaunch.exportPendingArtifacts(
            to: fixture.visibleRoot
        )
        XCTAssertEqual(firstReport.exported.count, 1)
        XCTAssertEqual(firstReport.retainedFailureCount, 0)
        XCTAssertTrue(try directoryNames(at: fixture.privateRoot).isEmpty)

        let secondReport = nextLaunch.exportPendingArtifacts(
            to: fixture.visibleRoot
        )
        XCTAssertTrue(secondReport.exported.isEmpty)
        XCTAssertEqual(secondReport.retainedFailureCount, 0)
        let visibleNames = try directoryNames(
            at: fixture.visibleRoot.appendingPathComponent(
                DictationRecoveryStore.visibleDirectoryName
            )
        )
        XCTAssertEqual(visibleNames.filter { !$0.hasPrefix(".") }.count, 1)
    }

    func testExactPublishedReplayCleansPrivateSourceWithoutDuplicate() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let firstLaunch = try DictationRecoveryStore(rootURL: fixture.privateRoot)
        let privateDirectory = try stageSession(
            store: firstLaunch,
            reason: "termination_grace_timeout"
        )
        let visibleDirectory = try copyPrivateRecoveryToVisible(
            privateDirectory,
            fixture: fixture
        )

        let nextLaunch = try DictationRecoveryStore(rootURL: fixture.privateRoot)
        let report = nextLaunch.exportPendingArtifacts(to: fixture.visibleRoot)

        XCTAssertEqual(report.exported.count, 1)
        XCTAssertEqual(report.exported.first?.directoryURL, visibleDirectory)
        XCTAssertEqual(report.retainedFailureCount, 0)
        XCTAssertTrue(try directoryNames(at: fixture.privateRoot).isEmpty)
        XCTAssertEqual(
            try directoryNames(at: visibleDirectory.deletingLastPathComponent()).count,
            1
        )
    }

    func testLiveRecordingLeaseBlocksCrossStoreRecoveryUntilRelease() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let writerStore = try DictationRecoveryStore(
            rootURL: fixture.privateRoot
        )
        let recoveryWorker = try DictationRecoveryStore(
            rootURL: fixture.privateRoot
        )
        let session = try makeSession(store: writerStore)

        let busyReport = recoveryWorker.exportPendingArtifacts(
            to: fixture.visibleRoot
        )
        XCTAssertTrue(busyReport.exported.isEmpty)
        XCTAssertEqual(busyReport.retainedFailureCount, 0)
        let liveNames = try directoryNames(at: fixture.privateRoot)
        XCTAssertEqual(liveNames.count, 1)
        XCTAssertTrue(liveNames[0].hasSuffix(".recording"))

        XCTAssertTrue(session.preserve(reason: "forced_termination"))
        let retryReport = recoveryWorker.exportPendingArtifacts(
            to: fixture.visibleRoot
        )
        XCTAssertEqual(retryReport.exported.count, 1)
        XCTAssertEqual(retryReport.retainedFailureCount, 0)
        XCTAssertEqual(retryReport.exported.first?.reason, "forced_termination")
        XCTAssertTrue(try directoryNames(at: fixture.privateRoot).isEmpty)
    }

    func testForgedSameUUIDVisibleArtifactsRetainPrivateSources() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try DictationRecoveryStore(rootURL: fixture.privateRoot)

        let manifestPrivateDirectory = try stageSession(
            store: store,
            reason: "manifest_authoritative"
        )
        let forgedManifestDirectory = try copyPrivateRecoveryToVisible(
            manifestPrivateDirectory,
            fixture: fixture
        )
        let forgedManifestURL = forgedManifestDirectory.appendingPathComponent(
            DictationRecoveryStore.manifestFileName
        )
        var forgedManifest = try manifestObject(at: forgedManifestURL)
        forgedManifest["reason"] = "forged_visible_reason"
        try writeManifestObject(forgedManifest, to: forgedManifestURL)

        let audioPrivateDirectory = try stageSession(
            store: store,
            reason: "audio_authoritative"
        )
        let forgedAudioDirectory = try copyPrivateRecoveryToVisible(
            audioPrivateDirectory,
            fixture: fixture
        )
        let forgedAudioURL = forgedAudioDirectory.appendingPathComponent(
            DictationRecoveryStore.audioFileName
        )
        try FileManager.default.removeItem(at: forgedAudioURL)
        let forgedWriter = try CallCaptureWAVWriter(
            url: forgedAudioURL,
            sampleRate: 16_000
        )
        _ = forgedWriter.enqueue([Float](repeating: -0.35, count: 1_600))
        XCTAssertEqual(forgedWriter.finish().sampleCount, 1_600)

        let report = store.exportPendingArtifacts(to: fixture.visibleRoot)

        XCTAssertTrue(report.exported.isEmpty)
        XCTAssertEqual(report.retainedFailureCount, 2)
        let retained = try directoryNames(at: fixture.privateRoot)
        XCTAssertEqual(retained.count, 2)
        XCTAssertTrue(retained.allSatisfy { $0.hasSuffix(".recovering") })
        for name in retained {
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: fixture.privateRoot
                    .appendingPathComponent(name)
                    .appendingPathComponent(
                        DictationRecoveryStore.audioFileName
                    ).path
            ))
        }
    }

    func testStoreRejectsSymlinkRoot() throws {
        let fixture = try makeFixture(createPrivateRoot: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let target = fixture.root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: fixture.privateRoot,
            withDestinationURL: target
        )

        XCTAssertThrowsError(
            try DictationRecoveryStore(rootURL: fixture.privateRoot)
        ) { error in
            guard case DictationRecoveryError.unsafeRoot = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    func testUnsafeManifestAndAudioEntriesAreRetained() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let store = try DictationRecoveryStore(rootURL: fixture.privateRoot)

        let modeDirectory = try stageSession(store: store, reason: "mode")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: modeDirectory
                .appendingPathComponent(DictationRecoveryStore.manifestFileName).path
        )

        let hardLinkDirectory = try stageSession(store: store, reason: "hardlink")
        try FileManager.default.linkItem(
            at: hardLinkDirectory.appendingPathComponent(
                DictationRecoveryStore.audioFileName
            ),
            to: fixture.root.appendingPathComponent("linked-audio.wav")
        )

        let symlinkDirectory = try stageSession(store: store, reason: "symlink")
        let symlinkManifest = symlinkDirectory.appendingPathComponent(
            DictationRecoveryStore.manifestFileName
        )
        let externalManifest = fixture.root.appendingPathComponent("external.json")
        try Data("{}".utf8).write(to: externalManifest)
        try FileManager.default.removeItem(at: symlinkManifest)
        try FileManager.default.createSymbolicLink(
            at: symlinkManifest,
            withDestinationURL: externalManifest
        )

        let oversizedDirectory = try stageSession(store: store, reason: "oversized")
        let oversizedManifest = oversizedDirectory.appendingPathComponent(
            DictationRecoveryStore.manifestFileName
        )
        try Data(repeating: 0x20, count: 64 * 1_024 + 1).write(
            to: oversizedManifest
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: oversizedManifest.path
        )

        let identityDirectory = try stageSession(store: store, reason: "identity")
        let identityManifest = identityDirectory.appendingPathComponent(
            DictationRecoveryStore.manifestFileName
        )
        var identityObject = try manifestObject(at: identityManifest)
        identityObject["id"] = UUID().uuidString.lowercased()
        try writeManifestObject(identityObject, to: identityManifest)

        let wavDirectory = try stageSession(store: store, reason: "wav")
        let wavURL = wavDirectory.appendingPathComponent(
            DictationRecoveryStore.audioFileName
        )
        let handle = try FileHandle(forWritingTo: wavURL)
        try handle.seek(toOffset: 40)
        var impossibleLength = UInt32.max.littleEndian
        try withUnsafeBytes(of: &impossibleLength) {
            try handle.write(contentsOf: Data($0))
        }
        try handle.close()

        let report = store.exportPendingArtifacts(to: fixture.visibleRoot)
        XCTAssertTrue(report.exported.isEmpty)
        XCTAssertEqual(report.retainedFailureCount, 6)
        XCTAssertEqual(try directoryNames(at: fixture.privateRoot).count, 6)
    }

    private func makeSession(
        store: DictationRecoveryStore
    ) throws -> DictationRecoverySession {
        let session = try store.begin(
            startTime: Date(),
            sourceApp: "Lifecycle Test",
            sampleRate: 16_000
        )
        session.append([Float](repeating: 0.2, count: 1_600))
        return session
    }

    private func stageSession(
        store: DictationRecoveryStore,
        reason: String
    ) throws -> URL {
        let session = try makeSession(store: store)
        guard session.preserve(reason: reason) else {
            throw NSError(
                domain: "DictationTerminationLifecycleTests",
                code: 1
            )
        }
        let prefix = session.id.uuidString.lowercased()
        let name = try XCTUnwrap(
            try directoryNames(at: store.rootURL).first {
                $0.hasPrefix(prefix)
            }
        )
        return store.rootURL.appendingPathComponent(name, isDirectory: true)
    }

    private func manifestObject(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func writeManifestObject(
        _ object: [String: Any],
        to url: URL
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func copyPrivateRecoveryToVisible(
        _ privateDirectory: URL,
        fixture: Fixture
    ) throws -> URL {
        let idText = try XCTUnwrap(
            privateDirectory.lastPathComponent.split(separator: ".").first
        )
        _ = try XCTUnwrap(UUID(uuidString: String(idText)))
        let visibleRoot = fixture.visibleRoot.appendingPathComponent(
            DictationRecoveryStore.visibleDirectoryName,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: visibleRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: visibleRoot.path
        )
        let visibleDirectory = visibleRoot.appendingPathComponent(
            String(idText),
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: visibleDirectory,
            withIntermediateDirectories: false
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: visibleDirectory.path
        )
        for name in [
            DictationRecoveryStore.audioFileName,
            DictationRecoveryStore.manifestFileName,
        ] {
            let destination = visibleDirectory.appendingPathComponent(name)
            try FileManager.default.copyItem(
                at: privateDirectory.appendingPathComponent(name),
                to: destination
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        }
        return visibleDirectory
    }

    private func directoryNames(at url: URL) throws -> [String] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: url.path)
            .sorted()
    }

    private struct Fixture {
        let root: URL
        let privateRoot: URL
        let visibleRoot: URL
    }

    private func makeFixture(createPrivateRoot: Bool = true) throws -> Fixture {
        let rawRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: rawRoot,
            withIntermediateDirectories: false
        )
        let canonicalRoot = try canonicalURL(rawRoot)
        let privateRoot = canonicalRoot.appendingPathComponent(
            "PendingDictations",
            isDirectory: true
        )
        if createPrivateRoot {
            try FileManager.default.createDirectory(
                at: privateRoot,
                withIntermediateDirectories: false
            )
        }
        return Fixture(
            root: canonicalRoot,
            privateRoot: privateRoot,
            visibleRoot: canonicalRoot.appendingPathComponent(
                "Documents/Voicely",
                isDirectory: true
            )
        )
    }

    private func canonicalURL(_ url: URL) throws -> URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(url.path, &buffer) != nil else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let terminator = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let path = String(
            decoding: buffer[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        return URL(
            fileURLWithPath: path,
            isDirectory: true
        )
    }
}
