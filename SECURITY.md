# Security

## Reporting a vulnerability

Please report security issues through a private [GitHub security advisory](https://github.com/RZDESIGN/reset-meter/security/advisories/new). Do not include access tokens, usage-cache files, account identifiers, or unredacted screenshots in a public issue.

## Credential handling

Reset Meter reads your installed Codex, Claude, Antigravity, and Cursor clients in read-only mode without modifying their databases or rotating their tokens. For Cursor 3.29+ installations that encrypt `state.vscdb` at rest (`cursor-safe-storage:v1:`), Reset Meter offers an optional isolated PKCE connection that never touches `Cursor.app`'s own Keychain entry.

- **Codex**: Invokes the locally installed `codex` CLI (`app-server`, or the CLI bundled inside `ChatGPT.app`) pointed at the selected `CODEX_HOME` directory. Ambient `OPENAI_API_KEY`, `CODEX_API_KEY`, and `CODEX_ACCESS_TOKEN` environment variables are stripped before spawning the subprocess, and CLI stderr output is sanitized before display.
- **Claude**: Reads existing local state per profile without ever calling refresh-token endpoints (avoiding single-use refresh-token races that would sign Claude Desktop or Claude Code out). Live OAuth tokens from active local Claude Code subprocesses or profile-scoped Keychain / `.credentials.json` entries are held only in memory and sent exclusively over HTTPS to `api.anthropic.com` with redirects and cookies disabled.
- **Antigravity**: Reads the active local Antigravity `language_server` process CSRF token and loopback listening ports, connecting exclusively to `127.0.0.1` (`GetUserStatus`). Loopback TLS validation accepts self-signed certificates strictly when the target host is `127.0.0.1` or `localhost`.
- **Cursor**: Reads `cursorAuth/stripeMembershipType` and unencrypted `cursorAuth/accessToken` from `state.vscdb` via `/usr/bin/sqlite3 -readonly`, or reads local `cursor-agent` CLI credentials without modifying them. When Cursor 3.29+ encrypts `state.vscdb` with `cursor-safe-storage:v1:`, **Connect Cursor…** uses Cursor's PKCE exchange (`loginDeepControl`) and stores Reset Meter's own session in macOS Keychain (`app.resetmeter.macos.cursor`) via `/usr/bin/security -i` stdin so tokens never appear in process arguments. All requests go exclusively to `api2.cursor.sh` with redirects and cookies disabled.

Local snapshot caches stored under `~/Library/Application Support/Reset Meter/Usage Cache/` contain only usage percentages, reset timestamps, and subscription plan names — never tokens, organization UUIDs, email addresses, or personal paths. Account identifiers and custom profile paths are validated against path traversal before use.

Release signing credentials are supplied externally through the macOS Keychain. They must never be committed to this repository.
