# TODO

## Gameplay and runtime

- [ ] Fix overlapping `Player.stun()` calls so an earlier timeout cannot end a later stun.
- [ ] Make `Player.interact()` trigger only the nearest eligible area. It currently hits every eligible overlapping area.
- [ ] Replace hardcoded movement and interaction keys in `Player` with InputMap actions. Preserve the current default bindings.
- [ ] Move the one-shot latch and relay dispatch in `BumpProp` behind a `Zone` API. The prop currently uses `zone.is_set(relay)` as a latch, writes the Blackboard key directly, and calls `zone.rule_fired.emit(...)`. Replace `get_node("BumpArea")` with an explicit reference or a safe lookup.
- [ ] Remove the unused `item_id` field from the `ctx` dictionary passed on `deliver`. No delivery rule or step reads it.
- [ ] Type the HUD reference in `game_manager.gd` and connect `scored` to a named handler.

## Rule Board and authored data

- [ ] Fix rule renames so they preserve the saved `once` latch. The latch is keyed by rule ID, so renaming the rule currently orphans it. Preserve saved Blackboard values across key renames as well.
- [ ] Add the missing rename and delete actions for both events and relays. Update rule triggers and emit references on rename, and surface affected connections when deleting.
- [ ] Coalesce consecutive SpinBox changes to the same field into one undo entry per edit gesture.
- [ ] Centralize the authored dictionary shapes for rules, steps, and variables. Revisit typed sub-resources (`RuleData`, `StepData`, `VariableData`) when native Inspector editing or cleaner diffs justify a resource migration.

## Testing and tooling

- [ ] Add a CI job that imports the project and runs the existing headless suites on Godot 4.7. Evaluate GUT or gdUnit4 if the suite grows enough to benefit from a framework.
- [ ] Extend `.gitignore` for local temporary files and private export presets, if used.

## Deferred decisions

- [ ] Decide whether to retire the `ZoneSource` script backend after confirming whether script-authored rules are still needed. If retired, move shared helpers such as `parse_literal`, `step_text`, and `format_literal` into a focused utility and remove the legacy verb wrappers and `_legacy_verb()` from `Zone`.
- [ ] Revisit optional registered verb descriptors when a second zone needs a different mix of verbs or the Rule Board needs editor hints beyond typed GDScript signatures. Keep parameter types and execution in GDScript unless a concrete use case calls for a resource-backed schema.
