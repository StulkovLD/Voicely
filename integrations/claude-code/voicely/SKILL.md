---
name: voicely
description: >-
  Offline voice-to-text and call/file transcripts via Voicely's local MCP server.
  Use when the user references an audio or video file to transcribe, wants speaker
  diarization (who said what), or asks about something they dictated or recorded
  ("my last call", "what I dictated earlier", "the meeting recording"). The user
  speaks to capture context instead of typing it to the agent.
---

# Voicely

Voicely runs speech recognition (WhisperKit) and speaker diarization (FluidAudio)
fully offline on the user's Mac. This plugin connects to the local `voicely mcp`
server, giving you four tools. Everything stays on-device; nothing is uploaded.

The point: the user **talks** to hand you maximum context, instead of typing it.
A 20-minute call or a quick dictation carries far more than a chat message — pull
it in and act on it.

## Tools

- **transcribe_file** — Transcribe an audio/video file at an absolute path.
  Args: `path` (required), `diarize` (bool, label who said what), `language`
  (`auto` | `ru` | `en`, default `auto`). Returns transcript text; speaker-labelled
  when `diarize=true` and speakers are found.
- **list_transcripts** — List saved transcripts, newest first. Optional `kind`
  (`dictations` | `calls` | `files`); omit for all. Returns
  `<kind>\t<id>\t<iso-date>\t<preview>` lines.
- **get_transcript** — Read one saved transcript by `id`, or an alias:
  `last` | `last-call` | `last-file` | `last-dictation`. Optional `kind`.
- **get_last_call** — Read the most recent call transcript. No args.

## When to use which

**"Transcribe this mp3 / m4a / mov / wav …"** (any path to an audio or video file)
→ `transcribe_file` with that `path`. Add `diarize: true` if the user wants to
know who said what (interview, meeting, multi-speaker recording). Then work with
the returned text — summarize, extract action items, answer questions about it.

**"Look at my last call and turn it into a project / spec / tickets / summary"**
→ `get_last_call` to read the transcript, then do the downstream work directly
from it. Use `list_transcripts kind=calls` first only if the user means a specific
earlier call, then `get_transcript` with its `id`.

**"What did I dictate?" / "pull up that note I recorded"**
→ `list_transcripts` (optionally `kind=dictations`) to find it, then
`get_transcript` with the `id` — or `get_transcript id=last-dictation` for the
most recent one.

**"Read transcript X" / "open the last file transcript"**
→ `get_transcript` with the `id` or an alias (`last`, `last-file`).

## Notes

- Paths for `transcribe_file` should be absolute. `~` is expanded; relative paths
  may not resolve to what the user means.
- First `transcribe_file` call may pause while the WhisperKit model loads (and
  downloads once, on first use). Diarization models download once on first
  `diarize=true` call. Progress goes to stderr; just wait for the result.
- In-band failures (file not found, no such transcript) come back as an error
  result with a message — read it and tell the user plainly.
- After pulling a transcript, **do the task** — don't just echo the text back.
  The transcript is context for the real request.
