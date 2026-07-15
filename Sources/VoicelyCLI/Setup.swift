import ArgumentParser
import Darwin
import Foundation

enum VoicelyLinkState: Equatable {
    case missing
    case ownedSymlink(destination: String)
    case foreignSymlink(destination: String)
    case foreignItem
}

enum VoicelyLinkOwnershipError: LocalizedError {
    case foreignSymlink(path: String, destination: String)
    case foreignItem(path: String)
    case targetChanged(path: String)
    case nonAdjacentQuarantine(path: String, quarantinePath: String)
    case quarantineChanged(path: String, quarantinePath: String)
    case restoreFailed(path: String, quarantinePath: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .foreignSymlink(path, destination):
            return "Refusing to modify \(path): it points to \(destination), not a known Voicely binary."
        case let .foreignItem(path):
            return "Refusing to modify \(path): it is not a symlink owned by Voicely."
        case let .targetChanged(path):
            return "Refusing to continue: \(path) changed while Voicely was updating it. The new item was preserved."
        case let .nonAdjacentQuarantine(path, quarantinePath):
            return "Refusing to move \(path): quarantine must be adjacent, not \(quarantinePath)."
        case let .quarantineChanged(path, quarantinePath):
            return "Refusing to continue: \(path) changed after quarantine. Inspect the quarantine location at \(quarantinePath)."
        case let .restoreFailed(path, quarantinePath, reason):
            return "Could not restore the unowned item to \(path). It remains preserved at \(quarantinePath): \(reason)"
        }
    }
}

/// Stateless ownership checks keep setup safe and independently testable.
enum VoicelyLinkOwnership {
    static let installedExecutablePath = "/Applications/Voicely.app/Contents/Helpers/voicely"

    private struct ItemIdentity: Equatable {
        let device: dev_t
        let inode: ino_t
        let mode: mode_t
    }

    static func knownExecutablePaths(currentExecutablePath: String) -> Set<String> {
        [currentExecutablePath, installedExecutablePath].reduce(into: Set<String>()) { paths, path in
            paths.insert(normalizeAbsolutePath(path))
        }
    }

    /// Resolves a relative symlink destination against the link's directory, then
    /// compares exact normalized paths. Basenames alone never establish ownership.
    static func isOwned(
        destination: String,
        linkPath: String,
        knownExecutablePaths: Set<String>
    ) -> Bool {
        let destinationPath: String
        if (destination as NSString).isAbsolutePath {
            destinationPath = normalizeAbsolutePath(destination)
        } else {
            let linkDirectory = (linkPath as NSString).deletingLastPathComponent
            destinationPath = normalizeAbsolutePath(
                (linkDirectory as NSString).appendingPathComponent(destination)
            )
        }

        let normalizedKnownPaths = Set(knownExecutablePaths.map(normalizeAbsolutePath))
        return normalizedKnownPaths.contains(destinationPath)
    }

    static func state(
        atPath itemPath: String,
        ownershipLinkPath: String? = nil,
        knownExecutablePaths: Set<String>,
        fileManager: FileManager = .default
    ) -> VoicelyLinkState {
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: itemPath) {
            if isOwned(
                destination: destination,
                linkPath: ownershipLinkPath ?? itemPath,
                knownExecutablePaths: knownExecutablePaths
            ) {
                return .ownedSymlink(destination: destination)
            }
            return .foreignSymlink(destination: destination)
        }

        if fileManager.fileExists(atPath: itemPath) {
            return .foreignItem
        }
        return .missing
    }

    /// Produces an adjacent path, so quarantine uses one filesystem and rename
    /// stays atomic. The token parameter makes race behavior deterministic in tests.
    static func quarantinePath(for linkPath: String, token: String) -> String {
        let parent = (linkPath as NSString).deletingLastPathComponent
        let name = (linkPath as NSString).lastPathComponent
        return (parent as NSString).appendingPathComponent(
            ".\(name).voicely-quarantine-\(token)"
        )
    }

    /// Removes an existing target only after exact symlink ownership is proven.
    static func prepareForInstall(
        atPath linkPath: String,
        knownExecutablePaths: Set<String>,
        fileManager: FileManager = .default,
        quarantinePath explicitQuarantinePath: String? = nil,
        afterQuarantine: ((String) throws -> Void)? = nil
    ) throws {
        _ = try removeOwnedSymlinkAtomically(
            atPath: linkPath,
            knownExecutablePaths: knownExecutablePaths,
            fileManager: fileManager,
            quarantinePath: explicitQuarantinePath,
            afterQuarantine: afterQuarantine
        )
    }

    /// Creates the replacement beside the installed link before touching the
    /// old one, then atomically swaps the two symlinks. A creation failure
    /// leaves the working link intact. Identity checks on both sides detect a
    /// concurrent replacement; rollback preserves the object that won the race.
    static func installOwnedSymlinkTransactionally(
        atPath linkPath: String,
        destination: String,
        knownExecutablePaths: Set<String>,
        fileManager: FileManager = .default,
        token: String = UUID().uuidString,
        createReplacement: ((_ path: String, _ destination: String) throws -> Void)? = nil
    ) throws {
        let parent = (linkPath as NSString).deletingLastPathComponent
        let name = (linkPath as NSString).lastPathComponent
        let replacementPath = (parent as NSString).appendingPathComponent(
            ".\(name).voicely-replacement-\(token)"
        )
        let creator = createReplacement ?? { path, destination in
            try fileManager.createSymbolicLink(
                atPath: path,
                withDestinationPath: destination
            )
        }

        // This is the only fallible creation step. It happens before any rename
        // of the installed link, which makes failure non-destructive.
        try creator(replacementPath, destination)
        let replacementIdentity = try itemIdentity(atPath: replacementPath)
        var committed = false
        defer {
            if !committed,
               let current = try? itemIdentity(atPath: replacementPath),
               current == replacementIdentity {
                try? unlinkNonDirectory(atPath: replacementPath)
            }
        }

        guard state(
            atPath: replacementPath,
            ownershipLinkPath: linkPath,
            knownExecutablePaths: knownExecutablePaths,
            fileManager: fileManager
        ) == .ownedSymlink(destination: destination) else {
            throw VoicelyLinkOwnershipError.targetChanged(path: replacementPath)
        }

        switch state(
            atPath: linkPath,
            knownExecutablePaths: knownExecutablePaths,
            fileManager: fileManager
        ) {
        case .missing:
            try atomicRenameExclusive(from: replacementPath, to: linkPath)
            guard let installedIdentity = try? itemIdentity(atPath: linkPath),
                  installedIdentity == replacementIdentity else {
                throw VoicelyLinkOwnershipError.targetChanged(path: linkPath)
            }
            committed = true

        case .ownedSymlink:
            let previousIdentity = try itemIdentity(atPath: linkPath)
            guard case .ownedSymlink = state(
                atPath: linkPath,
                knownExecutablePaths: knownExecutablePaths,
                fileManager: fileManager
            ),
            (try? itemIdentity(atPath: linkPath)) == previousIdentity else {
                throw VoicelyLinkOwnershipError.targetChanged(path: linkPath)
            }
            try atomicRenameSwap(replacementPath, linkPath)

            let installedIdentity = try? itemIdentity(atPath: linkPath)
            let displacedIdentity = try? itemIdentity(atPath: replacementPath)
            guard installedIdentity == replacementIdentity,
                  displacedIdentity == previousIdentity else {
                throw VoicelyLinkOwnershipError.targetChanged(path: linkPath)
            }

            do {
                try unlinkNonDirectory(atPath: replacementPath)
                committed = true
            } catch {
                do {
                    try atomicRenameSwap(replacementPath, linkPath)
                } catch let rollbackError {
                    throw VoicelyLinkOwnershipError.restoreFailed(
                        path: linkPath,
                        quarantinePath: replacementPath,
                        reason: "replacement cleanup failed: \(error.localizedDescription); rollback failed: \(rollbackError.localizedDescription)"
                    )
                }
                throw error
            }

        case .foreignSymlink(let foreignDestination):
            throw VoicelyLinkOwnershipError.foreignSymlink(
                path: linkPath,
                destination: foreignDestination
            )

        case .foreignItem:
            throw VoicelyLinkOwnershipError.foreignItem(path: linkPath)
        }
    }

    /// Returns true when an owned link was removed and false when nothing existed.
    static func uninstall(
        atPath linkPath: String,
        knownExecutablePaths: Set<String>,
        fileManager: FileManager = .default,
        quarantinePath explicitQuarantinePath: String? = nil,
        afterQuarantine: ((String) throws -> Void)? = nil
    ) throws -> Bool {
        try removeOwnedSymlinkAtomically(
            atPath: linkPath,
            knownExecutablePaths: knownExecutablePaths,
            fileManager: fileManager,
            quarantinePath: explicitQuarantinePath,
            afterQuarantine: afterQuarantine
        )
    }

    private static func removeOwnedSymlinkAtomically(
        atPath linkPath: String,
        knownExecutablePaths: Set<String>,
        fileManager: FileManager,
        quarantinePath explicitQuarantinePath: String?,
        afterQuarantine: ((String) throws -> Void)?
    ) throws -> Bool {
        let quarantinePath = explicitQuarantinePath ?? Self.quarantinePath(
            for: linkPath,
            token: UUID().uuidString
        )
        let linkParent = normalizeAbsolutePath((linkPath as NSString).deletingLastPathComponent)
        let quarantineParent = normalizeAbsolutePath(
            (quarantinePath as NSString).deletingLastPathComponent
        )
        guard linkParent == quarantineParent else {
            throw VoicelyLinkOwnershipError.nonAdjacentQuarantine(
                path: linkPath,
                quarantinePath: quarantinePath
            )
        }

        do {
            try atomicRenameExclusive(from: linkPath, to: quarantinePath)
        } catch let error as NSError
            where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return false
        }

        let quarantinedIdentity: ItemIdentity
        do {
            quarantinedIdentity = try itemIdentity(atPath: quarantinePath)
        } catch {
            throw VoicelyLinkOwnershipError.quarantineChanged(
                path: linkPath,
                quarantinePath: quarantinePath
            )
        }

        do {
            try afterQuarantine?(quarantinePath)
        } catch {
            try ensureIdentity(
                quarantinedIdentity,
                atPath: quarantinePath,
                originalPath: linkPath
            )
            try restoreQuarantinedItem(
                from: quarantinePath,
                to: linkPath,
                originalPath: linkPath,
                reason: error.localizedDescription
            )
            throw error
        }

        let quarantinedState = state(
            atPath: quarantinePath,
            ownershipLinkPath: linkPath,
            knownExecutablePaths: knownExecutablePaths,
            fileManager: fileManager
        )

        switch quarantinedState {
        case .ownedSymlink:
            try ensureIdentity(
                quarantinedIdentity,
                atPath: quarantinePath,
                originalPath: linkPath
            )
            try unlinkNonDirectory(atPath: quarantinePath)
            guard state(
                atPath: linkPath,
                knownExecutablePaths: knownExecutablePaths,
                fileManager: fileManager
            ) == .missing else {
                throw VoicelyLinkOwnershipError.targetChanged(path: linkPath)
            }
            return true

        case let .foreignSymlink(destination):
            try ensureIdentity(
                quarantinedIdentity,
                atPath: quarantinePath,
                originalPath: linkPath
            )
            try restoreQuarantinedItem(
                from: quarantinePath,
                to: linkPath,
                originalPath: linkPath,
                reason: "ownership check rejected the symlink"
            )
            throw VoicelyLinkOwnershipError.foreignSymlink(
                path: linkPath,
                destination: destination
            )

        case .foreignItem:
            try ensureIdentity(
                quarantinedIdentity,
                atPath: quarantinePath,
                originalPath: linkPath
            )
            try restoreQuarantinedItem(
                from: quarantinePath,
                to: linkPath,
                originalPath: linkPath,
                reason: "ownership check rejected the item"
            )
            throw VoicelyLinkOwnershipError.foreignItem(path: linkPath)

        case .missing:
            throw VoicelyLinkOwnershipError.quarantineChanged(
                path: linkPath,
                quarantinePath: quarantinePath
            )
        }
    }

    private static func restoreQuarantinedItem(
        from quarantinePath: String,
        to linkPath: String,
        originalPath: String,
        reason: String
    ) throws {
        do {
            try atomicRenameExclusive(from: quarantinePath, to: linkPath)
        } catch {
            throw VoicelyLinkOwnershipError.restoreFailed(
                path: originalPath,
                quarantinePath: quarantinePath,
                reason: "\(reason); \(error.localizedDescription)"
            )
        }
    }

    private static func ensureIdentity(
        _ expected: ItemIdentity,
        atPath path: String,
        originalPath: String
    ) throws {
        guard let current = try? itemIdentity(atPath: path), current == expected else {
            throw VoicelyLinkOwnershipError.quarantineChanged(
                path: originalPath,
                quarantinePath: path
            )
        }
    }

    private static func atomicRenameExclusive(from source: String, to destination: String) throws {
        let result = source.withCString { sourcePointer in
            destination.withCString { destinationPointer in
                renameatx_np(
                    AT_FDCWD,
                    sourcePointer,
                    AT_FDCWD,
                    destinationPointer,
                    UInt32(RENAME_EXCL)
                )
            }
        }
        guard result == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSFilePathErrorKey: source]
            )
        }
    }

    private static func atomicRenameSwap(_ first: String, _ second: String) throws {
        let result = first.withCString { firstPointer in
            second.withCString { secondPointer in
                renameatx_np(
                    AT_FDCWD,
                    firstPointer,
                    AT_FDCWD,
                    secondPointer,
                    UInt32(RENAME_SWAP)
                )
            }
        }
        guard result == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSFilePathErrorKey: first]
            )
        }
    }

    private static func unlinkNonDirectory(atPath path: String) throws {
        let result = path.withCString { unlink($0) }
        guard result == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSFilePathErrorKey: path]
            )
        }
    }

    private static func itemIdentity(atPath path: String) throws -> ItemIdentity {
        var info = stat()
        let result = path.withCString { lstat($0, &info) }
        guard result == 0 else {
            let code = errno
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(code),
                userInfo: [NSFilePathErrorKey: path]
            )
        }
        return ItemIdentity(device: info.st_dev, inode: info.st_ino, mode: info.st_mode)
    }

    private static func normalizeAbsolutePath(_ path: String) -> String {
        ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    }
}

// MARK: - `voicely setup`
//
// Exposes the CLI on the user's PATH as `voicely` so an MCP harness (the
// Claude Code plugin's .mcp.json uses `command: "voicely"`) can launch it.
//
// Why a symlink and not just naming the SPM product `voicely`: on a
// case-insensitive APFS volume the lowercase `voicely` and the app binary
// `Voicely` collapse to one file, so the SPM product must stay `VoicelyCLI`.
// We bridge the gap by symlinking the real binary to `<bindir>/voicely`,
// where it lives in a directory that has no `Voicely` to collide with.

struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Install `voicely` on your PATH so agents/MCP can launch it."
    )

    @Flag(name: .long, help: "Remove the installed `voicely` symlink instead of creating it.")
    var uninstall = false

    @Option(name: .long, help: "Target directory for the symlink (default: first writable of /usr/local/bin, ~/.local/bin).")
    var dir: String?

    @Flag(
        name: .long,
        help: "After installing the symlink, explicitly connect detected agent harnesses (never allowed as root)."
    )
    var connectAgents = false

    func run() throws {
        if connectAgents, !AgentConnectionPolicy.isAllowed(effectiveUserID: geteuid()) {
            logErr(AgentConnectionPolicy.rootRefusalMessage)
            throw ExitCode.failure
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = dir.map { [$0] } ?? ["/usr/local/bin", "\(home)/.local/bin"]
        let fm = FileManager.default

        // Pick the first directory that exists-and-is-writable, or that we can create.
        var binDir: String?
        for c in candidates {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: c, isDirectory: &isDir), isDir.boolValue {
                if fm.isWritableFile(atPath: c) { binDir = c; break }
            } else if (try? fm.createDirectory(atPath: c, withIntermediateDirectories: true)) != nil {
                binDir = c; break
            }
        }
        guard let binDir else {
            logErr("No writable bin directory among: \(candidates.joined(separator: ", "))")
            logErr("Re-run with --dir <path> pointing at a directory on your PATH.")
            throw ExitCode.failure
        }

        let linkPath = "\(binDir)/voicely"
        let exe = Self.currentExecutablePath()
        let knownExecutablePaths = VoicelyLinkOwnership.knownExecutablePaths(
            currentExecutablePath: exe
        )

        if uninstall {
            do {
                if try VoicelyLinkOwnership.uninstall(
                    atPath: linkPath,
                    knownExecutablePaths: knownExecutablePaths,
                    fileManager: fm
                ) {
                    emitLine("Removed \(linkPath)")
                } else {
                    emitLine("Nothing to remove at \(linkPath)")
                }
            } catch let error as VoicelyLinkOwnershipError {
                logErr(error.localizedDescription)
                throw ExitCode.failure
            } catch {
                logErr("Failed to remove \(linkPath): \(error.localizedDescription)")
                throw ExitCode.failure
            }
            return
        }

        do {
            try VoicelyLinkOwnership.installOwnedSymlinkTransactionally(
                atPath: linkPath,
                destination: exe,
                knownExecutablePaths: knownExecutablePaths,
                fileManager: fm
            )
        } catch let error as VoicelyLinkOwnershipError {
            logErr(error.localizedDescription)
            throw ExitCode.failure
        } catch {
            logErr("Failed to link \(linkPath) -> \(exe): \(error.localizedDescription)")
            throw ExitCode.failure
        }

        emitLine("Installed: \(linkPath) -> \(exe)")
        // Warn if the chosen dir is unlikely to be on PATH.
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        if !path.split(separator: ":").contains(Substring(binDir)) {
            logErr("Note: \(binDir) is not on your PATH. Add it, e.g.:")
            logErr("  echo 'export PATH=\"\(binDir):$PATH\"' >> ~/.zshrc && source ~/.zshrc")
        }
        if connectAgents {
            emitLine("\nConnecting installed agent harnesses…")
            let out = try HarnessRegistry.connect(
                [],
                voicelyPath: Self.currentExecutablePath()
            )
            if out.connected.isEmpty && out.failed.isEmpty {
                emitLine("No agent harness detected. Install one, then run `voicely connect`.")
            } else {
                emitLine("Restart your agent(s) to pick up the 'voicely' tools.")
            }
        } else {
            emitLine("Agent harnesses were not modified. Run `voicely connect` explicitly to register MCP tools.")
        }
    }

    /// Absolute path to the running binary, resolving symlinks.
    static func currentExecutablePath() -> String {
        if let p = Bundle.main.executablePath {
            return (p as NSString).resolvingSymlinksInPath
        }
        let arg0 = CommandLine.arguments.first ?? "voicely"
        if arg0.hasPrefix("/") { return arg0 }
        let cwd = FileManager.default.currentDirectoryPath
        return ((cwd as NSString).appendingPathComponent(arg0) as NSString).resolvingSymlinksInPath
    }
}
