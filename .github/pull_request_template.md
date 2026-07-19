## Summary

-

## Privacy Boundary

- [ ] No real HealthKit values, exports, screenshots with sensitive data, receiver DBs, or logs are included.
- [ ] No bearer tokens, token hashes, pairing URLs, setup-page contents, deep links, sync cursor values, or local outbox payloads are included.
- [ ] HealthKit access remains read-only by default.
- [ ] No telemetry, analytics, advertising hooks, hidden cloud upload, or third-party AI calls were added.

## Tests

- [ ] `uv run ruff format --check .`
- [ ] `uv run ruff check .`
- [ ] `uv run basedpyright`
- [ ] `uv run pytest`
- [ ] Swift package tests / Xcode build run if iOS code changed.
- [ ] `uv run python scripts/public-release-audit.py --strict` if public docs, templates, assets, privacy copy, or release surfaces changed.

## Notes

Mention any App Store/privacy-copy implications or intentionally deferred follow-up work.
