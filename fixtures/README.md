# Fixtures

Fixtures in this directory are synthetic and intentionally small. They are not
copied from Apple Health exports, screenshots, logs, wiki records, or personal
devices.

Files:

- `health_bridge_batch_v1.synthetic.json`: canonical synthetic batch fixture.
- `health_bridge_batch_v1.apple-health-smoke.json`: Apple Health-shaped smoke
  fixture using `apple_health.*` source keys and `hk-*` stable record IDs; still
  synthetic, not copied from a device.
- `health_bridge_batch_v1.synthetic.ndjson`: line-oriented synthetic examples
  for future parser design notes.

Fixture identifiers, source names, dates, values, and cursors are invented for
contract testing.
