# Contributing to Voicely

Thanks for taking the time to help. Voicely is a Swift 6 / SwiftPM project for
macOS 14+.

## Build & test

```bash
git clone https://github.com/StulkovLD/Voicely.git
cd Voicely
swift build        # builds the app, the CLI, and the core library
swift test         # runs the unit suite (no model download, uses mocks)
```

The same `swift build` + `swift test` runs in CI on every push and pull request,
so a green local run usually means a green CI run.

## Project layout

- `Sources/VoicelyCore` — UI-free engine (transcription, diarization, I/O). Shared
  by the app and the CLI; this is where most logic lives.
- `Sources/Voicely` — the AppKit menu-bar app.
- `Sources/VoicelyCLI` — the headless `voicely` CLI and its stdio MCP server.
- `Tests/VoicelyTests` — unit tests. Add a test with any behavior change.
- `integrations/` — agent-harness integration (Claude Code plugin).

## Pull requests

1. Branch from `main`.
2. Keep changes focused; match the surrounding style (the code is the style guide).
3. Add or update a test for any behavior change — `swift test` must pass.
4. Describe what and why in the PR. Link an issue if there is one.

## Reporting bugs / ideas

Open an issue using the templates. For anything security-related, see
[SECURITY.md](SECURITY.md) instead of a public issue.
