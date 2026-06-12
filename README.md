# Voicely

**Local-first voice toolkit for macOS.** Dictation with cursor injection + call recording with speaker diarization. Fully offline. Open source.

<p align="center">
  <img src="https://img.shields.io/badge/platform-macOS-lightgrey" />
  <img src="https://img.shields.io/badge/swift-6.0-orange" />
  <img src="https://img.shields.io/badge/license-MIT-green" />
  <img src="https://img.shields.io/badge/engine-Apple%20Speech%20%2B%20WhisperKit-blue" />
</p>

## What it does

**Dictation mode** (Option+Space): Press hotkey, speak, press again. Text appears at your cursor - any app, any text field. Floating glass pill shows audio waveform while recording, loading animation while transcribing.

**Call recording mode** (menubar): Records system audio + microphone simultaneously. Transcribes with speaker diarization (who said what). Saves to `~/Transcripts/` as markdown with timestamps.

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

**Prerequisites:**
- macOS 14+ (Apple Silicon recommended)
- Xcode Command Line Tools (`xcode-select --install`)

```bash
# Clone
git clone https://github.com/StulkovLD/Voicely.git
cd Voicely

# Build
swift build -c release

# Run
.build/release/Voicely
```

**Speech recognition:** WhisperKit (on-device, CoreML/ANE). On first use it downloads a Whisper model sized to your RAM — Large V3 Turbo (~3 GB) on 16 GB+, a quantized turbo (~632 MB) on 8 GB, or small/base on less. The first transcription also compiles the model for the Neural Engine, which can take a few minutes; subsequent runs are fast.

**Call recording** captures system audio via **ScreenCaptureKit** (macOS Screen Recording permission) — no BlackHole or virtual audio device needed.

**Speaker diarization** runs fully on-device via **FluidAudio** (pyannote + WeSpeaker models). The models download automatically on first use — no Hugging Face account or token required.

## Usage

| Action | How |
|--------|-----|
| Dictate | **Option+Space** to start/stop. Text pastes at cursor. |
| Record call | Menubar VC -> "Record Call" / "Stop Recording" |
| Open transcripts | Menubar VC -> "Open Transcripts" |

First dictation downloads the Whisper model (~1.5 GB). Subsequent uses are instant.

**macOS permissions required** (the onboarding wizard requests these; grant to **Voicely**):
- **Microphone** — record your voice for dictation and your side of calls
- **Accessibility** — paste the transcript into the focused app
- **Input Monitoring** — the global Option+Space hotkey
- **Screen Recording** — capture the other side of a call (system audio)

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

### 2a. Claude Code (plugin)

A ready-made plugin lives in [`integrations/claude-code/voicely/`](integrations/claude-code/voicely/)
(manifest + `.mcp.json` + skill). Point Claude Code at that directory, enable the
plugin, and approve the `voicely` MCP server when prompted. The bundled skill
teaches the agent when to reach for each tool. See its
[README](integrations/claude-code/voicely/README.md) for details and a no-install
(absolute-path-to-binary) variant.

### 2b. Any stdio-MCP harness (Codex and others)

Register `voicely mcp` as an MCP server. The shape is the same everywhere:

```json
{
  "mcpServers": {
    "voicely": {
      "command": "voicely",
      "args": ["mcp"]
    }
  }
}
```

Or point straight at the built binary with no install:

```json
{
  "mcpServers": {
    "voicely": {
      "command": "/absolute/path/to/.build/release/VoicelyCLI",
      "args": ["mcp"]
    }
  }
}
```

Then ask your agent: "transcribe ~/Downloads/interview.m4a and pull the action
items", "look at my last call and draft a project plan", "what did I dictate
earlier?".

## Architecture

```
Option+Space ──> MicRecorder ──> Whisper large-v3-turbo ──> Clipboard + Cmd+V
                     |                                           |
                     v                                           v
              AudioOverlay                               CursorInjector
           (liquid glass pill)                         (paste at cursor)
                                                             |
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
