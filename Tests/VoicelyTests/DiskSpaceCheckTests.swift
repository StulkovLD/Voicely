import XCTest
@testable import VoicelyCore

final class DiskSpaceCheckTests: XCTestCase {

    func testErrorFormattingInGigabytes() {
        // 8 GB needed, 3 GB available
        let err = TranscriberError.insufficientDiskSpace(
            needed: 8_000_000_000,
            available: 3_000_000_000
        )
        guard let desc = err.errorDescription else {
            XCTFail("errorDescription must be non-nil")
            return
        }
        XCTAssertTrue(desc.contains("8.0 GB"),
            "should show 8.0 GB for 8_000_000_000 bytes, got: \(desc)")
        XCTAssertTrue(desc.contains("3.0 GB"),
            "should show 3.0 GB for 3_000_000_000 bytes, got: \(desc)")
        // No more MB artifacts from old formatter
        XCTAssertFalse(desc.contains("MB"),
            "must not fall back to MB formatting, got: \(desc)")
    }

    func testErrorFormattingRoundsToOneDecimal() {
        // 4.5 GB needed, 1.2 GB available — check rounding
        let err = TranscriberError.insufficientDiskSpace(
            needed: 4_500_000_000,
            available: 1_200_000_000
        )
        let desc = err.errorDescription ?? ""
        XCTAssertTrue(desc.contains("4.5 GB"), "got: \(desc)")
        XCTAssertTrue(desc.contains("1.2 GB"), "got: \(desc)")
    }

    func testAvailableDiskSpaceReturnsPositive() async throws {
        // Smoke test: asking for the real volume's capacity must yield > 0.
        let tmp = FileManager.default.temporaryDirectory
        let capacity = try WhisperKitEngine.testAvailableDiskSpace(at: tmp)
        XCTAssertGreaterThan(capacity, 0,
            "temp volume must report a positive available-capacity")
    }
}
