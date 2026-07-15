import Foundation
import XCTest
@testable import VoicelyCLI

final class SetupLinkOwnershipTests: XCTestCase {
    private let fileManager = FileManager.default

    func testPureOwnershipCheckAcceptsExactAndRelativeKnownTargetsOnly() {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let linkPath = root.appendingPathComponent("bin/voicely").path
        let executablePath = root.appendingPathComponent("app/voicely").path
        let knownPaths: Set<String> = [executablePath]

        XCTAssertTrue(VoicelyLinkOwnership.isOwned(
            destination: executablePath,
            linkPath: linkPath,
            knownExecutablePaths: knownPaths
        ))
        XCTAssertTrue(VoicelyLinkOwnership.isOwned(
            destination: "../app/voicely",
            linkPath: linkPath,
            knownExecutablePaths: knownPaths
        ))
        XCTAssertFalse(VoicelyLinkOwnership.isOwned(
            destination: root.appendingPathComponent("foreign/voicely").path,
            linkPath: linkPath,
            knownExecutablePaths: knownPaths
        ))
    }

    func testQuarantinePathIsAdjacentAndDeterministicForTests() {
        let linkPath = "/tmp/voicebox-bin/voicely"

        XCTAssertEqual(
            VoicelyLinkOwnership.quarantinePath(for: linkPath, token: "race-1"),
            "/tmp/voicebox-bin/.voicely.voicely-quarantine-race-1"
        )
    }

    func testNonAdjacentQuarantineIsRejectedWithoutMovingOwnedLink() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        try fileManager.createSymbolicLink(
            atPath: fixture.link.path,
            withDestinationPath: fixture.executable.path
        )
        let nonAdjacent = fixture.root.appendingPathComponent("other/quarantine")

        XCTAssertThrowsError(try VoicelyLinkOwnership.prepareForInstall(
            atPath: fixture.link.path,
            knownExecutablePaths: [fixture.executable.path],
            fileManager: fileManager,
            quarantinePath: nonAdjacent.path
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("quarantine must be adjacent"))
        }

        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: fixture.link.path),
            fixture.executable.path
        )
    }

    func testPrepareForInstallRemovesOwnedSymlink() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }

        try fileManager.createSymbolicLink(
            atPath: fixture.link.path,
            withDestinationPath: fixture.executable.path
        )

        try VoicelyLinkOwnership.prepareForInstall(
            atPath: fixture.link.path,
            knownExecutablePaths: [fixture.executable.path],
            fileManager: fileManager
        )

        XCTAssertEqual(
            VoicelyLinkOwnership.state(
                atPath: fixture.link.path,
                knownExecutablePaths: [fixture.executable.path],
                fileManager: fileManager
            ),
            .missing
        )
    }

    func testPrepareForInstallPreservesForeignFileAndReturnsClearError() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        try Data("keep me".utf8).write(to: fixture.link)

        XCTAssertThrowsError(try VoicelyLinkOwnership.prepareForInstall(
            atPath: fixture.link.path,
            knownExecutablePaths: [fixture.executable.path],
            fileManager: fileManager
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a symlink owned by Voicely"))
        }
        XCTAssertEqual(try String(contentsOf: fixture.link, encoding: .utf8), "keep me")
    }

    func testPrepareForInstallPreservesForeignSymlinkAndReturnsClearError() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let foreignDestination = fixture.root.appendingPathComponent("foreign-tool").path
        try fileManager.createSymbolicLink(
            atPath: fixture.link.path,
            withDestinationPath: foreignDestination
        )

        XCTAssertThrowsError(try VoicelyLinkOwnership.prepareForInstall(
            atPath: fixture.link.path,
            knownExecutablePaths: [fixture.executable.path],
            fileManager: fileManager
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a known Voicely binary"))
        }
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: fixture.link.path),
            foreignDestination
        )
    }

    func testPrepareForInstallRestoresForeignDirectoryWithoutRecursiveDeletion() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        try fileManager.createDirectory(at: fixture.link, withIntermediateDirectories: false)
        let sentinel = fixture.link.appendingPathComponent("keep.txt")
        try Data("keep directory".utf8).write(to: sentinel)

        XCTAssertThrowsError(try VoicelyLinkOwnership.prepareForInstall(
            atPath: fixture.link.path,
            knownExecutablePaths: [fixture.executable.path],
            fileManager: fileManager,
            quarantinePath: fixture.root.appendingPathComponent("bin/.fixed-quarantine").path
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("not a symlink owned by Voicely"))
        }

        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "keep directory")
        XCTAssertFalse(fileManager.fileExists(
            atPath: fixture.root.appendingPathComponent("bin/.fixed-quarantine").path
        ))
    }

    func testRaceReplacingOwnedLinkWithDirectoryPreservesReplacement() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        try fileManager.createSymbolicLink(
            atPath: fixture.link.path,
            withDestinationPath: fixture.executable.path
        )
        let quarantine = fixture.root.appendingPathComponent("bin/.race-quarantine")
        let sentinel = fixture.link.appendingPathComponent("new-owner.txt")

        XCTAssertThrowsError(try VoicelyLinkOwnership.prepareForInstall(
            atPath: fixture.link.path,
            knownExecutablePaths: [fixture.executable.path],
            fileManager: fileManager,
            quarantinePath: quarantine.path,
            afterQuarantine: { _ in
                try self.fileManager.createDirectory(
                    at: fixture.link,
                    withIntermediateDirectories: false
                )
                try Data("new object".utf8).write(to: sentinel)
            }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("changed while Voicely was updating"))
        }

        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "new object")
        XCTAssertFalse(fileManager.fileExists(atPath: quarantine.path))
    }

    func testForeignRestoreRacePreservesBothObjectsWithoutClobbering() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        try fileManager.createDirectory(at: fixture.link, withIntermediateDirectories: false)
        let originalSentinel = fixture.link.appendingPathComponent("original.txt")
        try Data("original".utf8).write(to: originalSentinel)
        let quarantine = fixture.root.appendingPathComponent("bin/.restore-race")

        XCTAssertThrowsError(try VoicelyLinkOwnership.prepareForInstall(
            atPath: fixture.link.path,
            knownExecutablePaths: [fixture.executable.path],
            fileManager: fileManager,
            quarantinePath: quarantine.path,
            afterQuarantine: { _ in
                try Data("replacement".utf8).write(to: fixture.link)
            }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("remains preserved"))
        }

        XCTAssertEqual(
            try String(contentsOf: fixture.link, encoding: .utf8),
            "replacement"
        )
        XCTAssertEqual(
            try String(contentsOf: quarantine.appendingPathComponent("original.txt"), encoding: .utf8),
            "original"
        )
    }

    func testQuarantineReplacementIsNeverRecursivelyDeleted() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        try fileManager.createSymbolicLink(
            atPath: fixture.link.path,
            withDestinationPath: fixture.executable.path
        )
        let quarantine = fixture.root.appendingPathComponent("bin/.swapped-quarantine")
        let sentinel = quarantine.appendingPathComponent("keep.txt")

        XCTAssertThrowsError(try VoicelyLinkOwnership.prepareForInstall(
            atPath: fixture.link.path,
            knownExecutablePaths: [fixture.executable.path],
            fileManager: fileManager,
            quarantinePath: quarantine.path,
            afterQuarantine: { quarantinedPath in
                try self.fileManager.removeItem(atPath: quarantinedPath)
                try self.fileManager.createDirectory(
                    at: quarantine,
                    withIntermediateDirectories: false
                )
                try Data("do not delete".utf8).write(to: sentinel)
            }
        )) { error in
            XCTAssertTrue(error.localizedDescription.contains("quarantine location"))
        }

        XCTAssertEqual(try String(contentsOf: sentinel, encoding: .utf8), "do not delete")
    }

    func testUninstallRemovesOwnedSymlinkButPreservesForeignSymlink() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        try fileManager.createSymbolicLink(
            atPath: fixture.link.path,
            withDestinationPath: fixture.executable.path
        )

        XCTAssertTrue(try VoicelyLinkOwnership.uninstall(
            atPath: fixture.link.path,
            knownExecutablePaths: [fixture.executable.path],
            fileManager: fileManager
        ))

        let foreignDestination = fixture.root.appendingPathComponent("foreign-tool").path
        try fileManager.createSymbolicLink(
            atPath: fixture.link.path,
            withDestinationPath: foreignDestination
        )
        XCTAssertThrowsError(try VoicelyLinkOwnership.uninstall(
            atPath: fixture.link.path,
            knownExecutablePaths: [fixture.executable.path],
            fileManager: fileManager
        ))
        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: fixture.link.path),
            foreignDestination
        )
    }

    func testTransactionalInstallCreationFailureKeepsWorkingLink() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let replacementExecutable = fixture.root.appendingPathComponent("app/voicely-v2")
        try Data("v2".utf8).write(to: replacementExecutable)
        try fileManager.createSymbolicLink(
            atPath: fixture.link.path,
            withDestinationPath: fixture.executable.path
        )

        XCTAssertThrowsError(try VoicelyLinkOwnership.installOwnedSymlinkTransactionally(
            atPath: fixture.link.path,
            destination: replacementExecutable.path,
            knownExecutablePaths: [fixture.executable.path, replacementExecutable.path],
            fileManager: fileManager,
            token: "create-failure",
            createReplacement: { _, _ in
                throw CocoaError(.fileWriteUnknown)
            }
        ))

        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: fixture.link.path),
            fixture.executable.path
        )
    }

    func testTransactionalInstallAtomicallyReplacesOwnedLink() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.root) }
        let replacementExecutable = fixture.root.appendingPathComponent("app/voicely-v2")
        try Data("v2".utf8).write(to: replacementExecutable)
        try fileManager.createSymbolicLink(
            atPath: fixture.link.path,
            withDestinationPath: fixture.executable.path
        )

        try VoicelyLinkOwnership.installOwnedSymlinkTransactionally(
            atPath: fixture.link.path,
            destination: replacementExecutable.path,
            knownExecutablePaths: [fixture.executable.path, replacementExecutable.path],
            fileManager: fileManager,
            token: "success"
        )

        XCTAssertEqual(
            try fileManager.destinationOfSymbolicLink(atPath: fixture.link.path),
            replacementExecutable.path
        )
        XCTAssertFalse(fileManager.fileExists(
            atPath: fixture.root.appendingPathComponent(
                "bin/.voicely.voicely-replacement-success"
            ).path
        ))
    }

    func testSetupDoesNotConnectAgentsUnlessExplicitlyRequested() throws {
        let defaultSetup = try Setup.parse([])
        let optedInSetup = try Setup.parse(["--connect-agents"])

        XCTAssertFalse(defaultSetup.connectAgents)
        XCTAssertTrue(optedInSetup.connectAgents)
    }

    func testAgentConnectionPolicyAlwaysRejectsRoot() {
        XCTAssertFalse(AgentConnectionPolicy.isAllowed(effectiveUserID: 0))
        XCTAssertTrue(AgentConnectionPolicy.isAllowed(effectiveUserID: 501))
        XCTAssertThrowsError(try AgentConnectionPolicy.requireAllowed(effectiveUserID: 0))
    }

    private func makeFixture() throws -> (root: URL, link: URL, executable: URL) {
        let root = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bin = root.appendingPathComponent("bin")
        let app = root.appendingPathComponent("app")
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: app, withIntermediateDirectories: true)
        let executable = app.appendingPathComponent("voicely")
        try Data().write(to: executable)
        return (root, bin.appendingPathComponent("voicely"), executable)
    }
}
