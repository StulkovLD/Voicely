# Voicely as an MCP Bundle

`manifest.json` here is the source of `voicely-<version>.mcpb` attached to each GitHub release. The bundle holds only the `voicely` CLI from the released app (`Voicely.app/Contents/Helpers/voicely`) and runs `voicely mcp` over stdio.

Rebuild for a release:

```bash
mkdir -p build/server && cp /Applications/Voicely.app/Contents/Helpers/voicely build/server/
cp manifest.json build/ && sips -s format png -Z 512 /Applications/Voicely.app/Contents/Resources/AppIcon.icns --out build/icon.png
npx -y @anthropic-ai/mcpb pack build voicely-<version>.mcpb
```

Then bump `version`, `identifier` and `fileSha256` in `/server.json` and publish it to the official MCP Registry with `mcp-publisher publish` (namespace `io.github.StulkovLD`).
