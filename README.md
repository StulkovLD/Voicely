# Voicely

**Local-first voice toolkit for macOS.** Dictation with cursor injection + call recording with speaker diarization. Fully offline. Open source.

<p align="center">
  <a href="https://github.com/StulkovLD/Voicely/actions/workflows/ci.yml"><img src="https://github.com/StulkovLD/Voicely/actions/workflows/ci.yml/badge.svg" /></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey" />
  <img src="https://img.shields.io/badge/swift-6.0-orange" />
  <img src="https://img.shields.io/badge/license-MIT-green" />
  <img src="https://img.shields.io/badge/engine-WhisperKit%20%2B%20FluidAudio-blue" />
</p>

## What it does

**Dictation mode** (Option+Space): Press hotkey, speak, press again. Voicely inserts text only into the same non-secure Accessibility target that was focused when recording began. If focus changes or direct insertion is unavailable, it copies the transcript for manual paste; secure targets remain save-only. A floating glass pill shows the audio waveform while recording and a loading animation while transcribing.

**Call recording mode** (menu bar): Records system audio + microphone simultaneously. Transcribes with speaker diarization (who said what). Saves to `~/Documents/Voicely/calls/<id>/` as markdown + JSONL + WAV artifacts.

## Why Voicely

| | Voicely | Wispr Flow | Superwhisper | BetterDictation |
|---|---|---|---|---|
| Price | Free | $12/mo | $8.5/mo | $39 |
| Open source | Yes | No | No | No |
| 100% offline | Yes | No | Partial | Yes |
| Call recording | Yes | No | No | No |
| Speaker diarization | Yes | No | No | No |
| Liquid glass UI | Yes | Yes | No | No |

## Install

To download and verify the current community DMG:

```bash
curl -fsSL https://voicely.art/install.sh | sh
```

The current public build is ad-hoc signed and is not notarized by Apple. The
helper verifies the DMG SHA-256 and the app's ad-hoc code integrity in a private
staging directory, applies and verifies macOS quarantine, saves the versioned
DMG in `~/Downloads`, and opens the exact verified read-only volume in Finder.
It does not bypass Gatekeeper, copy the app, launch it, or run setup.

Drag `Voicely.app` to **Applications** yourself. If macOS blocks the first open,
go to **System Settings → Privacy & Security**, review the warning, and choose
**Open Anyway** only if you trust this community build. A future Developer ID +
notarized release can use the automatic transactional install path.

Ad-hoc code identity can change between releases, so macOS may ask you to grant
Microphone, Accessibility, or Screen Recording again after an update.

**What happens on first launch**
1. Look for the Voicely menu-bar icon.
2. Approve **Microphone** and **Accessibility** when macOS asks.
3. Choose a local voice model.
4. Wait for the first model download + prepare step.
5. **Screen Recording** is only requested later, when you first use **Record Call**.

Current first-model lineup:
- **GigaAM V3 RU** — ~426 MB, needs 8 GB RAM, best Russian experience
- **Large V3 Turbo Q** — ~632 MB, needs 8 GB RAM
- **Medium** — ~1.5 GB, needs 16 GB RAM
- **Large V3 Turbo** — ~3 GB, needs 24+ GB RAM

Clean installs ask you to choose explicitly; Voicely does not silently auto-pick a model anymore. The first prepare step can take a minute; later launches are fast.

**Call recording** captures system audio via **ScreenCaptureKit** (macOS Screen Recording permission) — no BlackHole or virtual audio device needed.

**Speaker diarization** runs fully on-device via **FluidAudio** (pyannote + WeSpeaker models). The diarization models download automatically on first use — no Hugging Face account or token required.

**Build from source**

Prerequisites:
- macOS 14+ on Apple Silicon for the prebuilt app
- Xcode Command Line Tools (`xcode-select --install`)

```bash
git clone https://github.com/StulkovLD/Voicely.git
cd Voicely

swift build -c release --product Voicely
swift build -c release --product VoicelyCLI

.build/release/Voicely
```

## Usage

| Action | How |
|--------|-----|
| Dictate | **Option+Space** to start/stop. Text pastes at cursor. |
| Record call | Menu bar → "Record Call" / "Stop Recording" |
| Open transcripts | Menu bar → "Open Transcripts" |

On a clean install, Voicely asks you to choose a voice model. The first local-model download can be ~426 MB to ~3 GB depending on what you pick, and the first prepare step can take a minute.

**macOS permissions required** (the onboarding wizard requests these; grant to **Voicely**):
- **Microphone** — record your voice for dictation and your side of calls
- **Accessibility** — paste the transcript into the focused app
- **Screen Recording** — capture the other side of a call (system audio); requested only when you first use Record Call

## Use Voicely from your agent

Speak to hand your agent maximum context instead of typing it. Voicely ships a
headless `voicely mcp` server (stdio, JSON-RPC 2.0, fully offline) that exposes
four tools to any MCP-capable harness:

| Tool | What it does |
|------|--------------|
| `transcribe_file` | Transcribe an audio/video file (optional speaker diarization) |
| `list_transcripts` | List saved transcripts (dictations / calls / files), newest first |
| `get_transcript` | Read a transcript by id or alias (`last`, `last-call`, …) |
| `get_last_call` | Read the most recent call transcript |

### 1. Build and install the `voicely` binary

If you installed the **Voicely.app**, the CLI ships inside it at
`/Applications/Voicely.app/Contents/Helpers/voicely`. Expose it on your PATH with
its own setup command (no sudo; symlinks into `/usr/local/bin` or `~/.local/bin`):

```bash
/Applications/Voicely.app/Contents/Helpers/voicely setup
```

Building from source instead:

```bash
# From the repo root:
swift build -c release --product VoicelyCLI
# -> binary at .build/release/VoicelyCLI

# Install as the user-facing `voicely` command:
.build/release/VoicelyCLI setup
#   or manually: sudo ln -sf "$(pwd)/.build/release/VoicelyCLI" /usr/local/bin/voicely
```

> In SPM the CLI product is **VoicelyCLI**, not `voicely` — on case-insensitive
> APFS a `voicely` product would collide with the app binary `Voicely`. The
> `voicely` command is created by the install step above, in a directory with no
> such collision. No daemon: the server loads the WhisperKit model itself on the
> first `transcribe_file` call (models download once, on first use).

### 2. Connect your agents — one command

`voicely mcp` speaks standard stdio MCP, so it works with **any** MCP-capable
harness. After you drag the app to Applications, approve the first open, and
finish onboarding, run the setup command from step 1 yourself. It exposes the
CLI and detects the agents you have. Use `voicely connect` to register all of
them or one by name:

```bash
voicely connect            # every installed harness
voicely connect codex      # just one
```

It uses each harness's own `mcp add` command, so it never hand-edits a config
file it doesn't own. Currently wires up **Claude Code, Codex, Cursor, Hermes, and
OpenClaw**. Restart the agent afterward and ask it: *"transcribe
~/Downloads/interview.m4a and pull the action items"*, *"look at my last call and
draft a project plan"*, *"what did I dictate earlier?"*.

### 3. Manual config (if you'd rather)

Register `voicely mcp` as a stdio MCP server. The exact file differs per harness;
the shape is always `command: voicely`, `args: ["mcp"]`.

| Harness | Where | How |
|---|---|---|
| Claude Code | plugin or `claude mcp add` | `claude mcp add voicely -- voicely mcp` (or the [bundled plugin](integrations/claude-code/voicely/)) |
| Codex | `~/.codex/config.toml` | `[mcp_servers.voicely]`<br>`command = "voicely"`<br>`args = ["mcp"]` |
| Cursor | user settings | `cursor --add-mcp '{"name":"voicely","command":"voicely","args":["mcp"]}'` |
| Hermes | `~/.hermes/config.yaml` | `hermes mcp add voicely --command voicely --args mcp` |
| OpenClaw | `openclaw.json` | `openclaw mcp set voicely --command voicely --args mcp` |
| Anything else | its MCP config | `{"mcpServers":{"voicely":{"command":"voicely","args":["mcp"]}}}` |

No daemon: the server loads the WhisperKit model itself on the first
`transcribe_file` call (the model downloads once, on first use).

## Architecture

```
Option+Space ──> MicRecorder ──> Selected local model ──> CursorInjector
                     |                                  (target-bound AX insert)
                     v                                           |
              AudioOverlay                                      +──> Clipboard fallback
           (liquid glass pill)                                  |    (manual paste only)
                                                                v
                                                         TranscriptStore
                                                 (~/Documents/Voicely/*.md)
```

**Call recording flow:**
```
Record Call ──> CallRecorder ──────> WhisperKit ──> FluidAudio diarization ──> Markdown
            (mic + ScreenCaptureKit)              (who said what, on-device)   with speakers
```

**Agent access:** the same engine ships as a headless CLI (`voicely`) with an
embedded stdio MCP server (`voicely mcp`), so an agent (Claude Code, Codex, any
MCP harness) can transcribe files and read your transcripts. See
[Use Voicely from your agent](#use-voicely-from-your-agent).

**Stack:** Swift 6 + AppKit + WhisperKit (CoreML/ANE) + FluidAudio (diarization) + ScreenCaptureKit (system audio).

All processing happens locally. No data leaves your machine.

## Transcripts format

**Dictation** (`~/Documents/Voicely/dictations/`):
```markdown
---
type: dictation
date: 2026-03-19T22:30:00+00:00
source_app: Telegram
---

Your transcribed text here.
```

**Call** (`~/Documents/Voicely/calls/<id>/transcript.md`). When diarization runs,
a legend is prepended and remote speakers are split into `Speaker 1/2/...`; your
own mic is always `You`:
```
Speakers detected: 2
- You: you (microphone)
- Speaker 1: remote participant
- Speaker 2: remote participant

[00:00:00] You       (en): Hey, how's the project going?
[00:00:03] Speaker 1 (en): Almost done, pushing to prod tonight.
[00:00:07] Speaker 2 (en): I'll review the PR after lunch.
```

## Autostart on login

System Settings → General → **Login Items** → **+** → add **Voicely.app**.

## Support the project

If Voicely saves you time, a ⭐ on GitHub helps others find it.

## Acknowledgements

Voicely stands on excellent open-source work:

- **WhisperKit** (MIT) — on-device speech recognition, plus OpenAI Whisper models.
- **FluidAudio** (Apache-2.0) — on-device speaker diarization SDK.
- **Diarization models** — pyannote segmentation and WeSpeaker embeddings,
  licensed CC-BY-4.0.

## License

MIT
