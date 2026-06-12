# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems.

Report privately via GitHub's
[**Report a vulnerability**](https://github.com/StulkovLD/Voicely/security/advisories/new)
button (Security tab → Advisories), or email **support@voicely.art**.

You can expect an initial response within a few days. Once a fix is available it
will ship in a new release and the advisory will be published with credit (unless
you prefer to stay anonymous).

## Scope

Voicely runs **fully on-device** — audio, transcripts, and models never leave the
machine. The most relevant areas are: local file handling in the CLI / MCP server,
the text injection path, and the unsigned-build install/update flow.

## Supported versions

Only the latest release is supported. Please update before reporting.
