# Security

## Reporting a vulnerability

Please report security issues through a private [GitHub security advisory](https://github.com/RZDESIGN/reset-meter/security/advisories/new). Do not include access tokens, usage-cache files, account identifiers, or unredacted screenshots in a public issue.

## Credential handling

Each connection explicitly selects Local or Login. Local uses the installed provider’s existing account. Login uses an isolated Reset Meter account and never silently falls back to Local. Mode switches clear previous readings, preserve the saved Login credentials, and do not sign the installed app out.

Codex and Claude Login connections use separate private configuration directories, including when Login is selected on a default card. Browser sign-in and renewal use the provider’s own command. Claude Desktop’s native bundled command is discovered automatically; its Linux VM executable is excluded. Claude credentials stay in their directory-scoped Keychain entry or Claude Code’s protected fallback file. Reset Meter reads and deletes those entries with `/usr/bin/security`, the tool Claude Code itself uses for them, and never copies them elsewhere. Access tokens are sent only to `api.anthropic.com` for usage/profile requests. Claude renewal runs under a per-account lock and is never interrupted. Local Claude is read-only: it never renews or rewrites the installed login, and may fall back to the Claude app’s usage-history cache; Login never does.

Cursor Local reads its existing access token from the app’s database without changing it. Cursor Login uses the provider’s browser exchange with a cryptographically random PKCE verifier, polls only `api2.cursor.sh`, and stores the resulting tokens in a per-account entry in this Mac’s login Keychain, protected by its normal application access controls. Renewal goes only to Cursor’s token endpoint. Login URLs contain the PKCE challenge, not the verifier or tokens. Polling failures are sanitized so verifier URLs cannot appear in the UI.

Claude and Cursor requests disable redirects and cookie handling. No credentials are saved in preferences or logs. Removing an added account deletes its private Reset Meter login and scoped Keychain item, even if the account was switched to Local before removal. Local app credentials are never deleted.

Release signing credentials are supplied externally through the macOS keychain. They must never be committed to this repository.
