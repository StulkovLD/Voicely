import Foundation
import XCTest
@testable import VoicelyCLI

/// The CLI has no version of its own: it reports the version of the app bundle
/// it ships in, so `voicely --version`, `voicely status` and the MCP
/// `serverInfo.version` can never drift from the release.
final class CLIVersionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CLIVersionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeApp(named name: String, version: String?) throws -> URL {
        let contents = root.appendingPathComponent(name).appendingPathComponent("Contents")
        let helpers = contents.appendingPathComponent("Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleIdentifier": "art.voicely.app"]
        if let version { plist["CFBundleShortVersionString"] = version }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        let cli = helpers.appendingPathComponent("voicely")
        try Data().write(to: cli)
        return cli
    }

    func testHelperInsideAppReportsTheBundleVersion() throws {
        let cli = try makeApp(named: "Voicely.app", version: "9.8.7")
        XCTAssertEqual(VoicelyCLIVersion.resolve(executablePath: cli.path), "9.8.7")
    }

    func testBinaryOutsideAnAppBundleReportsUnbundled() throws {
        let bare = root.appendingPathComponent("debug").appendingPathComponent("VoicelyCLI")
        XCTAssertEqual(
            VoicelyCLIVersion.resolve(executablePath: bare.path),
            VoicelyCLIVersion.unbundledVersion
        )
    }

    func testBundleWithoutVersionKeyReportsUnbundled() throws {
        let cli = try makeApp(named: "Voicely.app", version: nil)
        XCTAssertEqual(
            VoicelyCLIVersion.resolve(executablePath: cli.path),
            VoicelyCLIVersion.unbundledVersion
        )
    }

    func testContentsFolderOutsideAnAppIsNotABundle() throws {
        let cli = try makeApp(named: "NotAnApp", version: "9.8.7")
        XCTAssertEqual(
            VoicelyCLIVersion.resolve(executablePath: cli.path),
            VoicelyCLIVersion.unbundledVersion
        )
    }
}
