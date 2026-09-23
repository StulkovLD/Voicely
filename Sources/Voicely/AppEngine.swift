import AppKit

/// Which text engine an app is built on, read from the bundle's structure,
/// never from a list of app names.
///
/// Chromium and everything built on it (Chrome and its forks, Electron apps
/// such as VS Code, Claude, Slack, Discord; CEF apps) run web content in a
/// separate renderer process and ship a helper named "… (Renderer).app".
/// Their Accessibility bridge reports the caret writable, answers success to a
/// write and drops the text (measured 6/6 in Chrome); whether it answers at
/// all depends on whether some assistive tool switched it on. So text never
/// goes into them through Accessibility.
enum AppEngine: String, Equatable, Sendable {
    case chromium
    case native

    private static let chromiumFrameworks: Set<String> = [
        "Electron Framework.framework",
        "Chromium Embedded Framework.framework",
    ]

    /// Structural test, cheap enough to run on every commit: two directory
    /// listings for most apps, one more per framework for Chrome-style ones.
    static func detect(bundleURL: URL?, fileManager: FileManager = .default) -> AppEngine {
        guard let bundleURL else { return .native }
        let frameworks = bundleURL.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        guard let names = try? fileManager.contentsOfDirectory(atPath: frameworks.path) else { return .native }
        if names.contains(where: { chromiumFrameworks.contains($0) || isRendererHelper($0) }) {
            return .chromium
        }
        for name in names where name.hasSuffix(".framework") {
            let helpers = frameworks.appendingPathComponent(name).appendingPathComponent("Helpers")
            if let inner = try? fileManager.contentsOfDirectory(atPath: helpers.path),
               inner.contains(where: isRendererHelper) {
                return .chromium
            }
        }
        return .native
    }

    private static func isRendererHelper(_ name: String) -> Bool {
        name.hasSuffix("(Renderer).app")
    }

    @MainActor private static var cache: [String: AppEngine] = [:]

    @MainActor
    static func cached(bundleURL: URL?) -> AppEngine {
        guard let bundleURL else { return .native }
        if let known = cache[bundleURL.path] { return known }
        let engine = detect(bundleURL: bundleURL)
        cache[bundleURL.path] = engine
        return engine
    }
}
