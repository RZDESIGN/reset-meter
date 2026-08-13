# Security

## Reporting a vulnerability

Please report security issues through a private [GitHub security advisory](https://github.com/RZDESIGN/reset-meter/security/advisories/new). Do not include access tokens, usage-cache files, account identifiers, or unredacted screenshots in a public issue.

## Credential handling

Reset Meter does not accept or persist credentials of its own. To fetch Cursor usage, it reads Cursor's existing local access token at refresh time and sends it only to Cursor's HTTPS usage endpoint. The token is kept in memory for the request and is not logged or written by Reset Meter.

Release signing credentials are supplied externally through the macOS keychain. They must never be committed to this repository.
