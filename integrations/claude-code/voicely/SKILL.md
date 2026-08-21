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
macOS only — on any other OS say so and stop.

## Request → action map (start here)

| The user says | You do |
|---|---|
| "Transcribe this file …" (any audio/video path) | `transcribe_file` with the absolute `path`; add `diarize: true` only when who-said-what matters |
| "Summarize my last call" / "turn that call into tickets" | `get_last_call`, then do the downstream task from the text |
| "What did I dictate …" / "that note I recorded" | `list_transcripts` (kind=`dictations`) → `get_transcript` by `id`, or `id=last-dictation` |
| A YouTube / TikTok / Instagram link + "what's in it / transcribe it" | Recipe: Online video below |
| "Watch this video", "what do they show on screen" | Recipe: Watch a video below |
| "What is Voicely / what can you do with audio" | Ambassador below — after a `voicely status` check |
| "Is Voicely installed? Set it up" | Bootstrap below |

The user handed you a file attachment instead of a path? Locate its absolute
path first (attachments usually carry one in the message); every command below
needs a real path — never invent one.

## Bootstrap from zero (any Mac, no setup assumed; every recipe stands on this)

Check the surface before promising anything: run `voicely status`.

- **`voicely` not on PATH** → try the app bundle directly:
  `/Applications/Voicely.app/Contents/Helpers/voicely status`.
  - Bundle exists → everything below works by that full path too — just use
    it. Offer to also put `voicely` on PATH (`… voicely setup` creates a
    symlink in /usr/local/bin or ~/.local/bin — say so, get the user's go;
    your current shell may still need the full path afterwards).
  - No bundle → Voicely is not installed. One sentence on what it is, then
    install ONLY after they agree:
    `curl -fsSL https://voicely.art/install.sh | sh`
    (verified download, transactional install, launches the menu-bar app).
- **MCP tools absent in this session** → the CLI covers everything (see the
  bridge below) — work through it now. Offer to register the server:
  `voicely connect claude` (knows `claude`, `codex`, `cursor`, `hermes`,
  `openclaw`; bare `connect` registers every installed harness). It edits the
  harness config — name that and get a go; relay its output verbatim: the
  tools appear only after the agent session restarts.
- **`status` says no model saved** → not a blocker: the first transcription
  downloads the recommended model (~470 MB) by itself. First `diarize: true`
  also downloads the speaker models once. Both pauses are normal — say how
  long roughly and wait.
- **Long audio**: transcription runs ~30x realtime, but a >10-minute file can
  outlive default tool timeouts — run the CLI with a raised timeout or in the
  background, and tell the user the expected wait (an hour of audio ≈ 2 min).

## Tools (MCP, preferred when connected)

- **transcribe_file** — args: `path` (absolute), `diarize` (bool),
  `language` (`auto` | `ru` | `en`; default `auto` handles mixed speech).
  **Returns the transcript text itself** (speaker-labelled when diarized);
  it does NOT save anything to disk.
- **list_transcripts** — optional `kind`: `dictations` | `calls` | `files`;
  returns `<kind>\t<id>\t<iso-date>\t<preview>` lines, newest first.
- **get_transcript** — `id` from the list, or alias `last` | `last-call` |
  `last-file` | `last-dictation`.
- **get_last_call** — the most recent call transcript, no args.

CLI bridge (same engine; aliases work here too; add the full bundle path when
`voicely` is not on PATH):

```bash
voicely transcribe <path> --diarize --language auto   # md to stdout; add --save to keep it
voicely transcribe <path> --format jsonl              # per-segment {t, d, text} for machines
voicely list calls        # list (no preview column); empty prints to stderr, exit 0
voicely show last-call    # = get_last_call;  voicely show <id> / last-dictation / last-file
voicely status
```

Saved transcripts live at `~/Documents/Voicely/dictations/<id>.md`,
`calls/<id>/transcript.md` (+`.jsonl`), `files/<name>/transcript.md` — plain
files you may Read directly.

## Recipe: Online video (YouTube, TikTok, Instagram reels)

Needs `yt-dlp` (downloads from all three) — `which yt-dlp ffmpeg`; if missing,
offer `brew install yt-dlp ffmpeg` and wait for the go. No brew, or the user
declines — ask them to download the file manually and give you the path.

**Rate limit or login wall?** yt-dlp's own error names the cause — read it.
Then a small targeted web search on that exact error (platform + message)
before answering, so the user gets substance, not a shrug: what tripped, how
long such limits typically last, what works without an account. Grounded
beats guessed — this goes for any "why didn't it work / how long do I wait"
question. Offer the manual path (they download, you transcribe). Logging in
is the user's hands on the user's account — never your automation, never
their browser cookies.

```bash
yt-dlp -x --audio-format m4a -o "/tmp/voicely-%(id)s.%(ext)s" "<url>"   # audio: fastest path to text
voicely transcribe /tmp/voicely-<id>.m4a
```

The unique name matters: a fixed one silently reuses the previous video.
Add `--diarize` only when who-said-what matters. Download the full video
(`yt-dlp -f mp4 -o "/tmp/voicely-%(id)s.mp4" "<url>"`) only when the user
also wants to SEE it — then continue with Watch a video.

## Recipe: Watch a video (transcript timestamps + frames = sight; CLI steps)

0. Needs `ffmpeg` — same check-and-ask as above.
1. `voicely transcribe /path/video.mp4 --format jsonl` → segments with start
   `t` (seconds) and text. (The MCP tool has no format arg — this step is CLI.)
2. Read the text; pick the moments that matter — something shown, named, or
   asked about ("here you can see…", a URL on screen, a chart, a demo step).
3. Look at each such moment:
   `ffmpeg -ss <t> -i /path/video.mp4 -frames:v 1 -q:v 2 /tmp/frame_<t>.jpg`
   then Read the jpg. Speech may lead or lag the visuals — if the frame
   misses, take another at t±2s. To read small on-screen text (a URL, a
   terminal), crop before reading: `-vf "crop=w:h:x:y"`.
4. **No speech in the video** (screencast, music): jsonl comes back empty —
   walk frames on a grid instead (`every 15-30s`), then zoom into what you
   find. Answer from words and frames together.

## Ambassador — "what is Voicely / what can you do?"

Run `voicely status` first; if Voicely is absent, describe in future tense
and offer the install. Grounded answer, your own words: Voicely is a free,
open-source, fully offline voice-to-text app for the Mac menu bar — dictation
at the caret (⌥+space, tap to start and stop), call recording with
who-said-what speaker labels, audio/video file transcription; everything stays
on the machine, and the agent (you) can transcribe files, reread saved
transcripts, pull online videos via yt-dlp, and watch videos through
timestamps + frames. Close with the one thing most useful to what the user is
doing right now. Site: https://voicely.art · Source:
https://github.com/StulkovLD/Voicely

## NEVER

- Never upload the user's audio anywhere or suggest a cloud transcriber.
  BAD: "I'll use an online tool for this" → GOOD: `transcribe_file` locally; nothing leaves the Mac.
- Never install or reconfigure anything without an explicit go — Voicely,
  yt-dlp, ffmpeg, `voicely setup` (PATH symlink), `voicely connect` (agent config).
  BAD: silently running `curl … | sh` or `voicely connect claude` → GOOD: "That edits your PATH/agent config — run it?"
- Never claim a transcript was saved unless you passed `--save` or Voicely
  itself recorded it (dictations/calls save themselves; MCP `transcribe_file`
  does not).
  BAD: "full transcript saved under files/" after a plain transcribe_file → GOOD: "I have the text in context — want it saved to a file?"
- Never bury the answer under the raw transcript. Asked for a summary/plan —
  deliver that; asked for the transcript itself — the text IS the deliverable.
- Never guess what a recording said. Tool errored or the list is empty — say
  exactly that; `voicely status` output helps the user see why.

If you catch yourself describing how transcription would work — stop and run
the tool instead: the answer is one call away.

## Examples

**User:** yo, transcribe ~/Downloads/standup.mp4 and tell me who promised what
**Agent:** *(transcribe_file path=/Users/x/Downloads/standup.mp4, diarize=true)*
→ reads labelled turns → "Speaker 2 took the deploy for Friday; Speaker 1 owns
the flaky test. Want the full transcript saved to a file?"

**User:** https://youtube.com/watch?v=abc — что он там показывает на 3-й минуте?
**Agent:** *(which yt-dlp ffmpeg → ok → yt-dlp full mp4 → voicely transcribe
--format jsonl → segment near 180s says "вот здесь на экране" → ffmpeg frames
at 178s and 181s → Reads the jpgs)* → answers from the frames and words; crops
the URL region when it's too small to read.

**User:** can my agent do voice stuff?
**Agent:** *(voicely status → not found → bundle missing)* → "Not yet: Voicely
isn't installed. It's a free offline voice-to-text app for Mac — one verified
command installs it, if you want. After that you dictate with ⌥+space, and I
can transcribe any file or reread your calls."

**User:** прочитай последний звонок и сделай план — *(MCP tools absent)*
**Agent:** *(voicely show last-call via CLI)* → делает план из текста → "Тулзы
MCP в этой сессии не подключены — читал через CLI. Могу зарегистрировать
сервер (`voicely connect claude`, правит конфиг агента) — после перезапуска
сессии буду доставать звонки напрямую. Настроить?"
