# Release notes template

## How to use this template

Copy the content beginning with the `# Apple Health AI Bridge Receiver/CLI`
heading into `.github/release/notes-<canonical-tag>.md` for a future
Receiver/CLI release. Use the canonical tag in the filename, and never
overwrite a published note. The final GitHub Release body must match the
versioned notes file exactly.

Before drafting, check `component-versions.json` and
[versioning and compatibility](../../docs/versioning.md). The current
Receiver/CLI validator accepts `receiver` and `coordinated` scopes, not an
iOS-only checkpoint. Match the scope declared in `component-versions.json`:

- For `receiver`, replace the scope placeholder with the exact text
  `Receiver-only release` and include the exact sentence
  `No TestFlight update is required`.
- For `coordinated`, replace the placeholder with `Coordinated release` and
  omit both receiver-only statements.

Use only the applicable scope wording. Remove every instruction and placeholder
before saving the versioned note. The install reference must contain
`@<canonical-tag>` with the actual tag; release validation checks that reference
as well as the compatibility declarations.

## Release body

# Apple Health AI Bridge Receiver/CLI `<version>`

**`<insert the one applicable scope marker>`**

[In one or two sentences, lead with the user-visible benefit and state which
components this release changes.]

## Highlights

- [Describe a concrete user-facing improvement.]
- [Add only the most useful additional highlights.]

## Compatibility

Compatible iOS Companion: `<marketing-version> (<build>)`

Compatible Batch Protocol: `<schema-id> (<version>)`

## Install or upgrade

[Give the version-pinned install or upgrade action and when it is available.
Mention required migration, backup, or other user action.]

## Limits and privacy

[State material limits, supported paths, and any relevant privacy or transport
changes. Avoid claims that this release does not support.]

## Release assets and provenance

[List only the assets included with this release. Explain the applicable
checksum and provenance files, and how they bind to the exact source and
release. Follow the [release criteria](criteria.md) and the
[maintainer release procedure](../../docs/maintainer-guide.md#releases).]
