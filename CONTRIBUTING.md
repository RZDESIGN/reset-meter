# Contributing

Contributions are welcome.

1. Create a focused branch.
2. Add or update tests for provider parsing and reset calculations.
3. Run `swift test` and `./scripts/build-app.sh`.
4. Open a pull request describing the user-visible behavior and the macOS version tested.

Keep fixtures synthetic. Never commit real provider responses, usage-history files, account identifiers, access tokens, personal paths, or screenshots containing private information.

Provider integrations should remain read-only and narrowly scoped to usage limits. Changes that access prompts, conversations, project contents, or unrelated account data will not be accepted.
