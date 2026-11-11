# Security

## Reporting a vulnerability

Please report security issues through a private [GitHub security advisory](https://github.com/RZDESIGN/reset-meter/security/advisories/new). Do not include access tokens, usage-cache files, account identifiers, or unredacted screenshots in a public issue.

## Read-only local credential handling

Reset Meter operates strictly in read-only local mode. It does not run browser sign-in flows, does not write or delete macOS Keychain items, and never rewrites or rotates credentials belonging to your installed apps.

- **Codex**: Invokes the locally installed `codex` CLI (`app-server`, or the CLI bundled inside `ChatGPT.app`) pointed at the selected `CODEX_HOME` directory. Ambient `OPENAI_API_KEY`, `CODEX_API_KEY`, and `CODEX_ACCESS_TOKEN` environment variables are stripped before spawning the subprocess, and CLI stderr output is sanitized before display.
- **Claude**: Reads existing local state per profile without ever calling refresh-token endpoints (avoiding single-use refresh-token races that would sign Claude Desktop or Claude Code out). Live OAuth tokens from active local Claude Code subprocesses or profile-scoped Keychain / `.credentials.json` entries are held only in memory and sent exclusively over HTTPS to `api.anthropic.com` with redirects and cookies disabled.
- **Antigravity**: Reads the active local Antigravity `language_server` process CSRF token and loopback listening ports, connecting exclusively to `127.0.0.1` (`GetUserStatus`). Loopback TLS validation accepts self-signed certificates strictly when the target host is `127.0.0.1` or `localhost`.
- **Cursor**: Reads `cursorAuth/accessToken` from the local `state.vscdb` SQLite database using `/usr/bin/sqlite3 -readonly` without modifying the database, holds the token only in memory, and sends it exclusively to `api2.cursor.sh` with redirects and cookies disabled.

Local snapshot caches stored under `~/Library/Application Support/Reset Meter/Usage Cache/` contain only usage percentages, reset timestamps, and subscription plan names — never tokens, organization UUIDs, email addresses, or personal paths. Account identifiers and custom profile paths are validated against path traversal before use.

Release signing credentials are supplied externally through the macOS Keychain. They must never be committed to this repository.
