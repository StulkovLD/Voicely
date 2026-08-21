# Voicely

**Your AI, in the loop.**

Voicely turns your voice, calls and files into text — ready for Claude Code, Codex, Cursor or any AI agent on your Mac. Everything runs on-device: no account, no cloud, nothing leaves your machine. Free, forever. Open source.

<p align="center">
  <a href="https://github.com/StulkovLD/Voicely/actions/workflows/ci.yml"><img src="https://github.com/StulkovLD/Voicely/actions/workflows/ci.yml/badge.svg" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B%20%C2%B7%20Apple%20Silicon-lightgrey" />
  <img src="https://img.shields.io/badge/swift-6.0-orange" />
  <img src="https://img.shields.io/badge/license-MIT-green" />
  <img src="https://img.shields.io/badge/engine-Parakeet%20V3%20%2B%20FluidAudio-blue" />
</p>

## Free, forever

Tools that do this usually ask for a monthly subscription or a one-time payment. Voicely is free, forever: MIT-licensed, and every line of it is in this repository. It is made by one person, in one room, who uses it every day. If it saves you time, a ⭐ helps others find it.

## Install

One command. There is no DMG to download and nothing to drag into Applications:

```bash
curl -fsSL https://voicely.art/install.sh | sh
```

The script downloads the current build, verifies its SHA-256 and code integrity in a private staging directory, installs it transactionally — the previous version stays as a backup until the new one passes every gate, and any failure rolls back cleanly — then launches the app. Re-running it updates in place and keeps your transcripts, model and settings.

The public build is ad-hoc signed and not notarized by Apple. Because the code identity changes between releases, the installer resets Voicely's own permission grants, so macOS asks for Microphone and Accessibility again after an update.

**First launch**

1. Find the Voicely icon in the menu bar.
2. Approve **Microphone** and **Accessibility** when macOS asks.
3. Confirm the speech model download (Parakeet V3, about 470 MB). The first prepare step takes about a minute; later launches are fast.
4. **Screen Recording** is requested only when you first use **Record Call**.

Requirements: macOS 14 or newer on Apple Silicon.

## Transport, not translation

Voicely moves what you said to where you work. It never rewrites, summarizes or "improves" what you meant — word-level truth is kept next to every transcript.

### Direct transport — dictation, `Option+Space`

Press the hotkey, speak, press it again. A floating glass pill shows the live waveform while you talk. The text lands wherever your caret is: native fields through Accessibility, terminals and AX-silent apps (VS Code included) through synthetic typing. No caret in sight — the text goes to the clipboard and the pill says so. The **Output** menu can pin dictation to the clipboard permanently; secure fields are save-only, always. Dictations are saved to `~/Documents/Voicely/dictations/`.

### Careful packaging — calls and files

**Calls** (menu bar → Record Call). Voicely records system audio (through ScreenCaptureKit — no virtual audio device needed) and your microphone, mixes them into one track, transcribes the mix and diarizes it globally. An echo can't duplicate a sentence, and several people on one mic separate into distinct voices. "You" is identified by matching diarized voices against your microphone's own activity. The transcript reads as speaker turns and is saved to `~/Documents/Voicely/calls/<id>/` as markdown, word-level JSONL and WAV.

**Files.** Any audio or video file becomes a transcript, with optional speaker diarization: `voicely transcribe <file>` from the terminal, or the `transcribe_file` tool from an agent. Results land in `~/Documents/Voicely/files/`.

Either way the result is text in one tap. Hand it to your agent yourself — paste it into Claude Code, save it as a note — or let the agent read it through MCP, below.

## Your AI knows what you know

The `voicely` CLI and a local MCP server make every capability agent-native. After installing the app, expose the CLI on your PATH and register the server with the agents you use:

```bash
/Applications/Voicely.app/Contents/Helpers/voicely setup   # symlinks `voicely` into /usr/local/bin or ~/.local/bin, no sudo
voicely connect                                            # registers the MCP server with every installed harness
voicely connect claude                                     # or one by name: claude, codex, cursor, hermes, openclaw
```

Teach the agent the whole playbook with the skill:

```bash
mkdir -p ~/.claude/skills/voicely && \
  curl -fsSL https://voicely.art/skill/SKILL.md -o ~/.claude/skills/voicely/SKILL.md
```

`voicely mcp` speaks standard stdio MCP (JSON-RPC 2.0, fully offline) and exposes four tools:

| Tool | What it does |
|------|--------------|
| `transcribe_file` | Transcribe an audio/video file (optional speaker diarization) |
| `list_transcripts` | List saved transcripts (dictations / calls / files), newest first |
| `get_transcript` | Read a transcript by id or alias (`last`, `last-call`, …) |
| `get_last_call` | Read the most recent call transcript |

`voicely connect` uses each harness's own `mcp add` command and never hand-edits a config file it doesn't own. Restart the agent afterward and ask it: *"transcribe ~/Downloads/interview.m4a and pull the action items"*, *"look at my last call and draft a project plan"*, *"what did I dictate earlier?"*. The skill covers bootstrap from zero, online video via yt-dlp (YouTube / TikTok / Instagram) and "watching" a video by pairing word-level timestamps with extracted frames. Everything stays on the machine.

**Manual config** — register `voicely mcp` as a stdio server. The exact file differs per harness; the shape is always `command: voicely`, `args: ["mcp"]`:

| Harness | Where | How |
|---|---|---|
| Claude Code | plugin or `claude mcp add` | `claude mcp add voicely -- voicely mcp` (or the [bundled plugin](integrations/claude-code/voicely/)) |
| Codex | `~/.codex/config.toml` | `[mcp_servers.voicely]`<br>`command = "voicely"`<br>`args = ["mcp"]` |
| Cursor | user settings | `cursor --add-mcp '{"name":"voicely","command":"voicely","args":["mcp"]}'` |
| Hermes | `~/.hermes/config.yaml` | `hermes mcp add voicely --command voicely --args mcp` |
| OpenClaw | `openclaw.json` | `openclaw mcp set voicely --command voicely --args mcp` |
| Anything else | its MCP config | `{"mcpServers":{"voicely":{"command":"voicely","args":["mcp"]}}}` |

There is no daemon: the server loads the speech model itself on the first `transcribe_file` call.

## Build from source

macOS 14+ on Apple Silicon and the Xcode Command Line Tools (`xcode-select --install`):

```bash
git clone https://github.com/StulkovLD/Voicely.git
cd Voicely

swift build -c release --product Voicely
swift build -c release --product VoicelyCLI

.build/release/Voicely              # the menu-bar app
.build/release/VoicelyCLI setup     # exposes the `voicely` command
```

> In SPM the CLI product is **VoicelyCLI**, not `voicely`: on case-insensitive APFS a `voicely` product would collide with the app binary `Voicely`. The `voicely` command is created by `setup`, in a directory with no such collision.

## Speech model

**Parakeet TDT 0.6B v3** (NVIDIA, CC-BY-4.0), running on-device through FluidAudio's CoreML port: about 470 MB on disk, 25 European languages including English and Russian — switching languages mid-sentence works — natively punctuated, roughly 30× realtime on Apple Silicon. Speaker diarization uses FluidAudio's pyannote community-1 segmentation and WeSpeaker embeddings, also on-device. Models download on first use; no Hugging Face account or token is required.

## Transcripts

Everything is plain files under `~/Documents/Voicely/` — readable by you, your agent and any other tool.

**Dictation** (`dictations/`):

```markdown
---
type: dictation
date: 2026-03-19T22:30:00+00:00
source_app: Telegram
---

Your transcribed text here.
```

**Call** (`calls/<id>/transcript.md`): one block per speaker turn; your own microphone is always `You`. Word-level timing lives in `transcript.jsonl` next to it; the audio is kept as `mix.wav` (what was transcribed) plus the raw `mic.wav` and `system.wav`.

```markdown
---
type: call
date: 2026-08-19T18:02:11+03:00
source_app: zoom.us
duration: 12:40
speakers: You + 2
---

[00:08] You
Hey, how's the project going?

[00:11] Speaker 1
Almost done, pushing to prod tonight.

[00:17] Speaker 2
I'll review the PR after lunch.
```

## Architecture

```
Option+Space ──> MicRecorder ──> Parakeet V3 (CoreML, on-device) ──> CursorInjector
                     │                                                AX insert → typed text → clipboard
                     v                                                          │
               AudioOverlay                                                     v
            (liquid glass pill)                                          TranscriptStore
                                                                   (~/Documents/Voicely/…)
```

```
Record Call ──> mic + ScreenCaptureKit ──> mixdown ──> Parakeet V3 ──> FluidAudio diarization ──> speaker-turn markdown
                                          (one track)                 ("You" by mic activity)     + word-level JSONL + WAV
```

**Stack:** Swift 6 + AppKit + FluidAudio (Parakeet TDT v3 CoreML + diarization) + ScreenCaptureKit (system audio). All processing happens locally. No data leaves your machine.

## Autostart on login

System Settings → General → **Login Items** → **+** → add **Voicely.app**.

## Acknowledgements

- **Parakeet TDT 0.6B v3** by NVIDIA (CC-BY-4.0) — the speech model.
- **FluidAudio** (Apache-2.0) — CoreML ports of Parakeet and the on-device diarization pipeline.
- **Diarization models** — pyannote segmentation and WeSpeaker embeddings (CC-BY-4.0).
- **WhisperKit** (MIT) — the on-device inference library this project grew up on.

## License

MIT
