import XCTest
@testable import Voicely

/// Chromium is recognised by the shape of the bundle, not by app names.
final class AppEngineTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func bundle(_ name: String, paths: [String]) throws -> URL {
        let app = root.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        for path in paths {
            try FileManager.default.createDirectory(at: app.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        return app
    }

    func testElectronAppWithRendererHelperIsChromium() throws {
        let app = try bundle("Code", paths: [
            "Contents/Frameworks/Electron Framework.framework",
            "Contents/Frameworks/Code Helper (Renderer).app",
        ])
        XCTAssertEqual(AppEngine.detect(bundleURL: app), .chromium)
    }

    func testRendererHelperAloneIsEnough() throws {
        let app = try bundle("Some Electron", paths: ["Contents/Frameworks/Some Helper (Renderer).app"])
        XCTAssertEqual(AppEngine.detect(bundleURL: app), .chromium)
    }

    /// Chrome, Yandex, Codex: the helpers live inside the versioned framework,
    /// reachable through its `Helpers` link.
    func testChromeStyleFrameworkHelpersAreChromium() throws {
        let app = try bundle("Browser", paths: [
            "Contents/Frameworks/Browser Framework.framework/Versions/150.0/Helpers/Browser Helper (Renderer).app",
        ])
        let framework = app.appendingPathComponent("Contents/Frameworks/Browser Framework.framework")
        try FileManager.default.createSymbolicLink(
            atPath: framework.appendingPathComponent("Helpers").path,
            withDestinationPath: "Versions/150.0/Helpers"
        )
        XCTAssertEqual(AppEngine.detect(bundleURL: app), .chromium)
    }

    func testCEFFrameworkIsChromium() throws {
        let app = try bundle("Cef", paths: ["Contents/Frameworks/Chromium Embedded Framework.framework"])
        XCTAssertEqual(AppEngine.detect(bundleURL: app), .chromium)
    }

    func testNativeAppsAreNative() throws {
        let plain = try bundle("TextEdit", paths: [])
        XCTAssertEqual(AppEngine.detect(bundleURL: plain), .native)
        let withFrameworks = try bundle("Telegram", paths: [
            "Contents/Frameworks/TelegramCore.framework/Versions/A/Resources",
            "Contents/Frameworks/Some Helper.app",
        ])
        XCTAssertEqual(AppEngine.detect(bundleURL: withFrameworks), .native)
        XCTAssertEqual(AppEngine.detect(bundleURL: nil), .native)
    }

    /// The machine's own apps, where present: Safari is WebKit, not Chromium.
    func testSafariIsNative() throws {
        let safari = URL(fileURLWithPath: "/Applications/Safari.app")
        guard FileManager.default.fileExists(atPath: safari.path) else { throw XCTSkip("no Safari here") }
        XCTAssertEqual(AppEngine.detect(bundleURL: safari), .native)
    }
}
