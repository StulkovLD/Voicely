import Foundation
import XCTest
@testable import VoicelyCLI

/// The CLI has no version literal of its own: inside Voicely.app it reports the
/// bundle's version, elsewhere (MCPB, bare build) the version compiled in from
/// the same Info.plist, so `voicely --version`, `voicely status` and the MCP
/// `serverInfo.version` cannot drift from the release.
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

    /// The version the source tree ships: the app's Info.plist.
    private func sourceInfoPlistVersion() throws -> String {
        let plist = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Voicely/Resources/Info.plist")
        let data = try Data(contentsOf: plist)
        let dict = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        )
        return try XCTUnwrap(dict["CFBundleShortVersionString"] as? String)
    }

    func testHelperInsideAppReportsTheBundleVersion() throws {
        let cli = try makeApp(named: "Voicely.app", version: "9.8.7")
        XCTAssertEqual(
            VoicelyCLIVersion.resolve(executablePath: cli.path, builtVersion: "1.0.0"),
            "9.8.7"
        )
    }

    /// The MCPB bundle runs the helper as `<bundle>/server/voicely`, outside any
    /// .app: it must still report the release version, not a placeholder.
    func testStandaloneBinaryReportsTheBuiltVersion() throws {
        let standalone = root.appendingPathComponent("server").appendingPathComponent("voicely")
        XCTAssertEqual(
            VoicelyCLIVersion.resolve(executablePath: standalone.path, builtVersion: "9.8.7"),
            "9.8.7"
        )
        XCTAssertEqual(
            VoicelyCLIVersion.resolve(executablePath: standalone.path),
            try sourceInfoPlistVersion()
        )
    }

    func testBuiltVersionIsTheInfoPlistVersion() throws {
        XCTAssertEqual(VoicelyBuildVersion.shortVersion, try sourceInfoPlistVersion())
    }

    func testBundleWithoutVersionKeyFallsBackToTheBuiltVersion() throws {
        let cli = try makeApp(named: "Voicely.app", version: nil)
        XCTAssertEqual(
            VoicelyCLIVersion.resolve(executablePath: cli.path, builtVersion: "9.8.7"),
            "9.8.7"
        )
    }

    func testContentsFolderOutsideAnAppIsNotABundle() throws {
        let cli = try makeApp(named: "NotAnApp", version: "1.2.3")
        XCTAssertNil(VoicelyCLIVersion.bundleVersion(executablePath: cli.path))
        XCTAssertEqual(
            VoicelyCLIVersion.resolve(executablePath: cli.path, builtVersion: "9.8.7"),
            "9.8.7"
        )
    }
}
