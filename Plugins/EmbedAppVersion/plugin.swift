import Foundation
import PackagePlugin

/// Compiles the product version into the target that uses this plugin.
///
/// The single version source is the app's `Info.plist`
/// (`CFBundleShortVersionString`). This plugin reads that file at build time
/// and generates `VoicelyBuildVersion.shortVersion`, so a binary that runs
/// outside `Voicely.app` (the MCPB bundle, a bare `swift build`) still reports
/// the release version. `Info.plist` is a declared input: bumping the version
/// regenerates the file on the next build.
@main
struct EmbedAppVersion: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let plist = context.package.directoryURL
            .appending(path: "Sources/Voicely/Resources/Info.plist")
        let output = context.pluginWorkDirectoryURL
            .appending(path: "VoicelyBuildVersion.swift")
        let script = #"""
            set -eu
            v=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1")
            case "$v" in
              ''|*[!0-9A-Za-z.+-]*) echo "error: bad CFBundleShortVersionString '$v' in $1" >&2; exit 1 ;;
            esac
            printf '// Generated from %s by the EmbedAppVersion plugin. Do not edit.\nenum VoicelyBuildVersion {\n    static let shortVersion = "%s"\n}\n' \
              "Info.plist" "$v" > "$2"
            """#
        return [
            .buildCommand(
                displayName: "Embed app version from Info.plist",
                executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", script, "embed-app-version", plist.path, output.path],
                inputFiles: [plist],
                outputFiles: [output]
            ),
        ]
    }
}
