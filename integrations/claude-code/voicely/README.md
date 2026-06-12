# Voicely — Claude Code plugin

Gives Claude Code four offline voice tools via a local stdio MCP server
(`voicely mcp`): `transcribe_file`, `list_transcripts`, `get_transcript`,
`get_last_call`. All transcription (WhisperKit) and diarization (FluidAudio)
runs on-device.

## What's in here

```
voicely/
├── .claude-plugin/
│   └── plugin.json      # plugin manifest (name, version, author, …)
├── .mcp.json            # registers the `voicely mcp` stdio server
├── SKILL.md             # teaches the agent when/how to call the tools
└── README.md            # this file
```

## Prerequisite: build and install the `voicely` binary

The plugin's `.mcp.json` launches the command `voicely`. Build it from the repo
and put it on your `PATH`:

```bash
# From the Voicely repo root:
swift build -c release --product VoicelyCLI
# -> binary at .build/release/VoicelyCLI

# Install as the user-facing `voicely` command (separate dir, no collision with
# the menu-bar app binary `Voicely` on case-insensitive APFS):
sudo ln -sf "$(pwd)/.build/release/VoicelyCLI" /usr/local/bin/voicely
#   or copy: sudo cp .build/release/VoicelyCLI /usr/local/bin/voicely

voicely mcp   # sanity check: prints "Voicely MCP server ready …" on stderr, then waits on stdin (Ctrl-C to exit)
```

> Note: in SPM the CLI product is **VoicelyCLI**, not `voicely` — on a
> case-insensitive filesystem a `voicely` SPM product would collide with the app
> binary `Voicely`. The user-facing `voicely` command is created by the install
> step above, in a directory where no such collision exists.

## No-install variant (point straight at the built binary)

If you'd rather not install to `/usr/local/bin`, edit `.mcp.json` to use the
absolute path to the built binary instead:

```json
{
  "mcpServers": {
    "voicely": {
      "command": "/absolute/path/to/Voicely/.build/release/VoicelyCLI",
      "args": ["mcp"]
    }
  }
}
```

No `env` or extra args are needed. The server loads the WhisperKit model itself
on the first `transcribe_file` call (models download once, on first use;
progress goes to stderr, which the harness captures/ignores).

## Install the plugin into Claude Code

Point Claude Code at this directory (a local plugin), then enable it. Once
enabled, Claude auto-discovers the MCP server and the skill; approve the
`voicely` MCP server when prompted (same per-server approval as a project
`.mcp.json`).

After enabling, ask Claude things like:

- "Transcribe ~/Downloads/interview.m4a and pull out the action items."
  (add: "label who's speaking" → diarization)
- "Look at my last call and draft a project plan from it."
- "What did I dictate earlier? Summarize it."
