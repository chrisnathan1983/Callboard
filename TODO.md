# TODO

## Rule Board and authored data

- [ ] Add the missing rename and delete actions for both events and relays. Update rule triggers and emit references on rename, and surface affected connections when deleting.
- [ ] Centralize the authored dictionary shapes for rules, steps, and variables. Revisit typed sub-resources (`RuleData`, `StepData`, `VariableData`) when native Inspector editing or cleaner diffs justify a resource migration.

## Deferred decisions

- [ ] Evaluate GUT or gdUnit4 if the headless suites grow enough to benefit from a framework.

- [ ] Decide whether to retire the `ZoneSource` script backend after confirming whether script-authored rules are still needed. If retired, move shared helpers such as `parse_literal`, `step_text`, and `format_literal` into a focused utility and remove the legacy verb wrappers and `_legacy_verb()` from `Zone`.
- [ ] Revisit optional registered verb descriptors when a second zone needs a different mix of verbs or the Rule Board needs editor hints beyond typed GDScript signatures. Keep parameter types and execution in GDScript unless a concrete use case calls for a resource-backed schema.
