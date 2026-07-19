## Summary

-

## Related issue

- Closes #
- Leave blank only for small maintenance or documentation changes that do not need an issue.

## Privacy Boundary

- [ ] No real HealthKit values, exports, screenshots with sensitive data, receiver DBs, or logs are included.
- [ ] No tokens, token hashes, pairing URLs, setup-page contents, deep links, sync cursor values, or local outbox payloads are included.
- [ ] HealthKit access remains read-only by default.
- [ ] No telemetry, analytics, advertising hooks, hidden cloud upload, or third-party AI calls were added.
- [ ] Any permission, authentication, pairing, deletion, queue/cursor, network, privacy-copy, or App Review impact was discussed in the linked issue.

## Tests

- [ ] `uv run ruff format --check .`
- [ ] `uv run ruff check .`
- [ ] `uv run basedpyright`
- [ ] `uv run bandit -r src -q`
- [ ] `uv run pip-audit --local --skip-editable`
- [ ] `uv run pytest -q`
- [ ] Swift package tests / Xcode build run if iOS code changed.
- [ ] `uv run python scripts/public-release-audit.py --strict` if public docs, templates, assets, privacy copy, or release surfaces changed.

## Release note

- [ ] User-visible change; add the `release-note` label after maintainer triage.
- [ ] No user-visible release note required.

## Breaking change

- [ ] This is backward compatible.
- [ ] This intentionally breaks a public contract and is linked to an accepted design issue.

## Notes

Mention App Store/privacy-copy implications, migration requirements, screenshots, or intentionally deferred follow-up work. Screenshots must use synthetic or redacted data.
