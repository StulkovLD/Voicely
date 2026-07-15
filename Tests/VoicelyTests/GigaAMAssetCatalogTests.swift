import Foundation
import XCTest
@testable import VoicelyCore

final class GigaAMAssetCatalogTests: XCTestCase {
    func testCatalogPinsImmutableRevisionAndCompleteIntegrityManifest() {
        XCTAssertEqual(GigaAMAssetCatalog.assets.count, 12)
        XCTAssertEqual(GigaAMAssetCatalog.totalExpectedByteCount, 445_643_360)
        XCTAssertEqual(GigaAMAssetCatalog.revision.count, 40)
        XCTAssertEqual(GigaAMAssetCatalog.upstreamRevision.count, 40)
        XCTAssertEqual(
            Set(GigaAMAssetCatalog.requiredRelativePaths).count,
            GigaAMAssetCatalog.assets.count
        )

        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        for asset in GigaAMAssetCatalog.assets {
            XCTAssertGreaterThan(asset.expectedByteCount, 0, asset.relativePath)
            XCTAssertEqual(asset.expectedSHA256.count, 64, asset.relativePath)
            XCTAssertNil(
                asset.expectedSHA256.rangeOfCharacter(from: hex.inverted),
                asset.relativePath
            )

            let url = GigaAMAssetCatalog.resolveURL(for: asset)
            XCTAssertTrue(url.path.contains("/resolve/\(GigaAMAssetCatalog.revision)/"))
            XCTAssertFalse(url.path.contains("/resolve/main/"))
        }
    }

    func testMissingRelativePathsIsEmptyWhenAllAssetsExist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for relativePath in GigaAMAssetCatalog.requiredRelativePaths {
            let path = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path.path, contents: Data())
        }

        XCTAssertEqual(GigaAMAssetCatalog.missingRelativePaths(in: root), [])
    }

    func testMissingRelativePathsReturnsOnlyMissingAssets() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for relativePath in GigaAMAssetCatalog.requiredRelativePaths.dropLast() {
            let path = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path.path, contents: Data())
        }

        XCTAssertEqual(GigaAMAssetCatalog.missingRelativePaths(in: root), [GigaAMAssetCatalog.requiredRelativePaths.last!])
    }
}
