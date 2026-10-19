These seeds are deliberately synthetic. The batch objects are reduced from
`fixtures/health_bridge_batch_v1.synthetic.json`: one item from each record
family and catalog, with an empty cursor list. The invalid batch changes only
the generated date to an impossible calendar date. MCP date ranges use the
same public fixture window plus calendar extremes, reversed order, and an
invalid leap day. Truncated JSON exercises syntax rejection for both targets.

Keep all seeds below the harness byte limit. Run the campaign against disposable
copies; libFuzzer may add or reduce corpus files. Never add real exports,
credentials, pairing material, or operational payloads here.
