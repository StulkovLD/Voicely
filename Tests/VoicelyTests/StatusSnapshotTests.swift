import Foundation
import XCTest
@testable import VoicelyCLI
@testable import VoicelyCore

final class StatusSnapshotTests: XCTestCase {
    func testStatusSnapshotReportsSavedModelSeparatelyFromRecommendedModel() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }
        defaults.set("gigaam-v3-e2e-rnnt", forKey: "whisperModel")

        let recommended = WhisperModel.all.first(where: { $0.variant == "medium" })!
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

        XCTAssertEqual(snapshot.selectedModel?.variant, "gigaam-v3-e2e-rnnt")
        XCTAssertEqual(snapshot.selectedModelDownloaded, true)
        XCTAssertEqual(snapshot.recommendedModel.variant, "medium")
        XCTAssertEqual(snapshot.recommendedModelDownloaded, false)
        XCTAssertTrue(snapshot.textLines.contains { $0.contains("Selected model:     GigaAM V3 RU") })
        XCTAssertTrue(snapshot.textLines.contains { $0.contains("Selected downloaded: yes") })
        XCTAssertTrue(snapshot.textLines.contains { $0.contains("Recommended model:  Medium") })
        XCTAssertTrue(snapshot.textLines.contains { $0.contains("Recommended downloaded: no") })

        let json = snapshot.jsonObject
        XCTAssertEqual(json["selectedModel"] as? String, "gigaam-v3-e2e-rnnt")
        XCTAssertEqual(json["recommendedModel"] as? String, "medium")
        XCTAssertEqual(json["selectedModelDownloaded"] as? Bool, true)
        XCTAssertEqual(json["recommendedModelDownloaded"] as? Bool, false)
        XCTAssertEqual(json["modelDownloaded"] as? Bool, true)
    }

    func testStatusSnapshotExplainsWhenNoModelIsSavedYet() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        defer {
            defaults.removePersistentDomain(forName: #function)
        }

        let recommended = WhisperModel.all.first(where: { $0.variant == "large-v3-v20240930_turbo_632MB" })!
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
