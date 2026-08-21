import CryptoKit
import Foundation

/// Installs a WhisperKit model straight from Hugging Face using the same
/// verified, cancellable transport as the GigaAM assets.
///
/// `WhisperKit.download` used to own this step. It could not be cancelled: the
/// download ran to completion in the background while the UI already claimed to
/// have stopped, and integrity was guessed from the directory's byte size.
/// Every asset here is pinned to one immutable revision and checked against its
/// SHA-256 before it is made live.
enum WhisperKitAssetInstaller {
    /// Written next to the assets once every byte has been verified.
    static let markerName = ".validated-source-manifest.json"

    /// Staging and rejected files live under dot-directories inside the model
    /// folder. WhisperKit only reads the `.mlmodelc` packages, so they are
    /// invisible to it — but they must not outlive a successful install.
    private static let quarantineName = ".quarantine"

    struct Marker: Codable, Equatable {
        let schemaVersion: Int
        let sourceManifestSHA256: String
    }

    /// Marker for `assets` at `revision`. Derived from the catalog alone, so it
    /// changes the moment the pin moves and never needs to read the model.
    static func expectedMarker(
        assets: [GigaAMAssetDescriptor],
        revision: String
    ) -> Marker {
        Marker(
            schemaVersion: 1,
            sourceManifestSHA256: GigaAMCompiledCachePolicy.manifestSHA256(
                revision: revision,
                assets: assets
            )
        )
    }

    /// Whether the pinned assets are already installed and intact.
    ///
    /// Deliberately cheap: the marker proves this exact catalog was verified
    /// byte-for-byte at install time, so this only re-checks that every file is
    /// still present at its expected size. Re-hashing on every launch would
    /// cost ~6 s for `medium` and ~13 s for Large V3 Turbo at ~250 MB/s. A file
    /// corrupted in place without changing size still fails later, at
    /// `WhisperKit(config)`, which deletes the model for a clean re-download.
    static func isInstalled(
        sourceRoot: URL,
        assets: [GigaAMAssetDescriptor],
        revision: String,
        fileSystem: any GigaAMAssetFileSystem = FoundationGigaAMAssetFileSystem()
    ) -> Bool {
        let markerURL = sourceRoot.appendingPathComponent(markerName)
        guard let data = try? Data(contentsOf: markerURL),
              let marker = try? JSONDecoder().decode(Marker.self, from: data),
              marker == expectedMarker(assets: assets, revision: revision)
        else { return false }

        return assets.allSatisfy { asset in
            let url = sourceRoot.appendingPathComponent(asset.relativePath)
            guard let size = try? fileSystem.fileSize(at: url) else { return false }
            return size == asset.expectedByteCount
        }
    }

    /// Download whatever is missing or corrupt, then seal the marker.
    ///
    /// Cancellation is honoured throughout: `GigaAMAssetDownloader` checks
    /// between assets and `URLSessionGigaAMAssetTransport` cancels the transfer
    /// in flight. Returns without touching the network when already installed.
    @discardableResult
    static func install(
        variant: String,
        sourceRoot: URL,
        assets: [GigaAMAssetDescriptor],
        revision: String,
        additionalRequiredBytes: Int64 = 0,
        fileSystem: any GigaAMAssetFileSystem = FoundationGigaAMAssetFileSystem(),
        transport: any GigaAMAssetTransport = URLSessionGigaAMAssetTransport(),
        onBytes: @Sendable @escaping (Int64, Int64) -> Void = { _, _ in }
    ) async throws -> GigaAMAssetInstallResult? {
        if isInstalled(
            sourceRoot: sourceRoot,
            assets: assets,
            revision: revision,
            fileSystem: fileSystem
        ) {
            return nil
        }

        // A stale marker must never survive a failed or cancelled install:
        // partial assets with a matching marker would read as intact.
        try? fileSystem.removeItem(at: sourceRoot.appendingPathComponent(markerName))

        let downloader = GigaAMAssetDownloader(
            assets: assets,
            revision: revision,
            transport: transport,
            fileSystem: fileSystem,
            resolveURL: { WhisperKitAssetCatalog.resolveURL(for: $0, variant: variant) }
        )
        let result = try await downloader.ensureAssets(
            in: sourceRoot,
            additionalRequiredBytes: additionalRequiredBytes,
            onBytes: onBytes
        )
        try seal(sourceRoot: sourceRoot, assets: assets, revision: revision, fileSystem: fileSystem)
        return result
    }

    /// Publish the marker. Every asset has been hashed by this point, so the
    /// rejected copies the downloader set aside are dead weight — a 3 GB model
    /// would otherwise keep a 3 GB `.quarantine` beside it forever.
    static func seal(
        sourceRoot: URL,
        assets: [GigaAMAssetDescriptor],
        revision: String,
        fileSystem: any GigaAMAssetFileSystem = FoundationGigaAMAssetFileSystem()
    ) throws {
        try? fileSystem.removeItem(at: sourceRoot.appendingPathComponent(quarantineName))

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try GigaAMSecureStorage.writePrivateFileAtomically(
            encoder.encode(expectedMarker(assets: assets, revision: revision)),
            to: sourceRoot.appendingPathComponent(markerName)
        )
    }
}
