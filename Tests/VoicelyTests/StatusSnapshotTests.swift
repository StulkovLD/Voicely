import Foundation
import XCTest
@testable import VoicelyCLI
@testable import VoicelyCore

final class StatusSnapshotTests: XCTestCase {
    /// The catalog shrank to Parakeet only (owner's call, 2026-08-19). A user
    /// upgrading from an older release still has a retired variant persisted;
    /// it must read as "no selection" so the app falls back to the
    /// recommendation instead of resurrecting a model the catalog no longer
    /// carries.
    func testStaleSavedVariantReadsAsNoSelection() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }
        defaults.set("gigaam-v3-e2e-rnnt", forKey: "whisperModel")

        let recommended = WhisperModel.all[0]
        let snapshot = StatusSnapshot.gather(
            version: "test",
            defaults: defaults,
            recommendedModel: recommended,
            systemRAMGB: 16,
            operatingSystemVersion: OperatingSystemVersion(
                majorVersion: 15,
                minorVersion: 0,
                patchVersion: 0
            ),
            fileExists: { path in
                path.contains("v3-e2e-rnnt")
            }
        )

        XCTAssertNil(snapshot.selectedModel)
        XCTAssertEqual(snapshot.recommendedModel.variant, "parakeet-tdt-0.6b-v3")
        XCTAssertTrue(snapshot.jsonObject["selectedModel"] is NSNull)
    }

    func testStatusSnapshotExplainsWhenNoModelIsSavedYet() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let recommended = WhisperModel.all[0]
        let snapshot = StatusSnapshot.gather(
            version: "test",
            defaults: defaults,
            recommendedModel: recommended,
            systemRAMGB: 8,
            fileExists: { _ in false }
        )

        XCTAssertNil(snapshot.selectedModel)
        XCTAssertTrue(snapshot.textLines.contains { $0.contains("none saved yet") })
        XCTAssertTrue(snapshot.jsonObject["selectedModel"] is NSNull)
        XCTAssertTrue(snapshot.jsonObject["selectedModelDownloaded"] is NSNull)
        XCTAssertEqual(snapshot.jsonObject["modelDownloaded"] as? Bool, false)
    }
}
