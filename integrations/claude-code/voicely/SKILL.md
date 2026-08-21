---
name: voicely
description: >-
  Give the agent ears and video sight via Voicely — free offline speech-to-text,
  call transcription, and speaker diarization on the user's Mac (nothing leaves
  the machine). Use whenever the user: drops or names an audio/video file
  (mp3, m4a, wav, mp4, mov, webm) or says "transcribe" / "транскрибируй";
  shares a YouTube / TikTok / Instagram link whose speech or content matters;
  asks to "watch" a video or what happens inside one; references anything they
  dictated or recorded ("my last call", "what I dictated", "the meeting");
  asks what Voicely is, whether it's installed, how to install or set it up;
  or asks "what can you do with audio/video". Also use to check or repair the
  Voicely install itself (app, CLI on PATH, MCP registration).
---

# Voicely — the user's local ears: transcribe anything, recall what they said, watch videos through timestamps

Voicely runs speech recognition and speaker diarization fully offline on this
Mac. The user talks (dictation, calls, recordings) to hand you far more context
than they would ever type — your job is to pull that context in and act on it.
Free and open source; audio and transcripts never leave the machine.

## Request → action map (start here)

| The user says | You do |
|---|---|
| "Transcribe this file …" (any audio/video path) | `transcribe_file` with the absolute `path`; add `diarize: true` for who-said-what |
| "Summarize my last call" / "turn that call into tickets" | `get_last_call`, then do the downstream task from the text |
| "What did I dictate …" / "that note I recorded" | `list_transcripts` (kind=`dictations`) → `get_transcript` by `id`, or `id=last-dictation` |
| A YouTube / TikTok / Instagram link + "what's in it / transcribe it" | Recipe: Online video below |
| "Watch this video", "what do they show on screen" | Recipe: Watch a video below |
| "What is Voicely / what can you do with audio" | Ambassador section below |
| "Is Voicely installed? Set it up" | Bootstrap section below |

## Bootstrap from zero (any machine, no setup assumed)

Check the surface before promising anything: run `voicely status`.

- **`voicely` not found on PATH** → try the app bundle directly:
  `/Applications/Voicely.app/Contents/Helpers/voicely status`.
  - Bundle exists → put the CLI on PATH: `/Applications/Voicely.app/Contents/Helpers/voicely setup`.
  - No bundle → Voicely is not installed. Tell the user what it is (one
    sentence) and that installing takes one command — run it only after they
    agree: `curl -fsSL https://voicely.art/install.sh | sh`
    (verified download, transactional install, launches the menu-bar app).
- **MCP tools absent in this session** → register the server turnkey:
  `voicely connect claude` (also knows `codex`, `cursor`; bare `voicely
  connect` registers every installed harness). Until the session reloads MCP,
  the CLI below covers everything the tools do.
- **`status` reports no model saved** → the user picks a model in the app's
  menu-bar on first launch; the recommended one downloads (~470 MB) once.
  First transcription after that may pause while the model loads — that is
  normal, wait for it.

## Tools (MCP, preferred when connected)

- **transcribe_file** — args: `path` (absolute), `diarize` (bool),
  `language` (`auto` | `ru` | `en`; default `auto` — it handles mixed speech).
- **list_transcripts** — optional `kind`: `dictations` | `calls` | `files`.
  Returns `<kind>\t<id>\t<iso-date>\t<preview>` lines, newest first.
- **get_transcript** — `id` from the list, or alias `last` | `last-call` |
  `last-file` | `last-dictation`.
- **get_last_call** — the most recent call transcript, no args.

CLI equivalents (same engine, useful without MCP or for extra formats):

```bash
voicely transcribe <path> --diarize --language auto   # md to stdout
voicely transcribe <path> --format jsonl              # per-segment {t, d, text} for machines
voicely list   ·   voicely show <id>   ·   voicely status
```

Saved artifacts live in `~/Documents/Voicely/{dictations,calls/<id>,files/<name>}`
as plain `md` / `jsonl` — you may Read them directly like any file.

## Recipe: Online video (YouTube, TikTok, Instagram reels)

Needs `yt-dlp` (downloads from all three) — check `which yt-dlp ffmpeg`; if
missing, offer `brew install yt-dlp ffmpeg` and wait for the user's go.

```bash
yt-dlp -x --audio-format m4a -o /tmp/clip.m4a "<url>"   # audio only: fastest path to text
voicely transcribe /tmp/clip.m4a --diarize
```

Download the full video instead (`yt-dlp -f mp4 -o /tmp/clip.mp4 "<url>"`)
only when the user also wants to SEE it — then continue with Watch a video.

## Recipe: Watch a video (transcript timestamps + frames = sight)

1. `voicely transcribe /path/video.mp4 --format jsonl` → segments with start
   time `t` (seconds) and text.
2. Read the text; pick the moments that matter — where something is shown,
   named, or the user asked about ("here you can see…", a URL on screen, a
   chart, a step in a demo).
3. Cut a frame at each such moment and look at it:
   `ffmpeg -ss <t> -i /path/video.mp4 -frames:v 1 -q:v 2 /tmp/frame_<t>.jpg`
   then Read the jpg. Transcript says what is said; frames show what is shown.
4. Answer from both. For "find where they show X": scan segments for X-words
   first, cut frames only there — not every second.

## Ambassador — when asked what Voicely is or what you can do

Answer in your own words, grounded in this: Voicely is a free, open-source,
fully offline voice-to-text app for the Mac menu bar — dictation at the caret
(⌥+space, tap to start and stop), call recording with who-said-what speaker
labels, and audio/video file transcription; everything stays on the machine,
and the agent (you) can transcribe files, reread any saved transcript, pull
online videos through yt-dlp, and watch videos via timestamps + frames.
Then offer the one thing most useful to what they're doing right now.
Site: https://voicely.art · Source: https://github.com/StulkovLD/Voicely

## NEVER

- Never upload the user's audio anywhere or suggest a cloud transcriber.
  BAD: "I'll use an online tool to transcribe this" → GOOD: `transcribe_file` locally; nothing leaves the Mac.
- Never install anything (Voicely, yt-dlp, ffmpeg) without the user's explicit go.
  BAD: silently running `curl … | sh` → GOOD: "Voicely isn't installed — one command sets it up. Run it?"
- Never echo a pulled transcript back as the answer.
  BAD: pasting 20 minutes of call text → GOOD: do the asked task (summary, tickets, answer) from it.
- Never guess what a transcript said. If `get_transcript` errors or the list is
  empty, say exactly that and show `voicely status` output if relevant.

If you catch yourself describing how transcription would work — stop and run
the tool instead: the answer is one call away.

## Examples

**User:** yo, transcribe ~/Downloads/standup.mp4 and tell me who promised what
**Agent:** *(transcribe_file path=/Users/x/Downloads/standup.mp4, diarize=true)*
→ reads labelled turns → "Speaker 2 took the deploy for Friday; Speaker 1 owns
the flaky test. Full transcript saved under files/standup."

**User:** https://youtube.com/watch?v=abc — что он там показывает на 3-й минуте?
**Agent:** *(checks yt-dlp → downloads mp4 → transcribe --format jsonl → finds
the segment near 180s mentioning "вот здесь на экране" → ffmpeg frame at 178s
→ Reads the jpg)* → answers from the frame and the words together.

**User:** can my agent do voice stuff?
**Agent:** *(voicely status → not found → app bundle missing)* → "You don't
have Voicely yet — it's a free offline voice-to-text app for Mac; I can install
it with one verified command if you want. After that you dictate with ⌥+space
and I can transcribe any file or reread your calls."
