## Overall

This is a well-scoped and thoughtful project. A few things I'd keep exactly as they are:

- **The model/view split.** The graph view emits semantic signals and never touches data, and wires are derived from triggers and relays rather than stored.
- **One validator for both editor and runtime.** `Zone.validate()` is used by the board, the game, and the save gate. Refusing to save when the draft doesn't compile is a good safety net.
- **Live mode.** Reusing the same `RuleBoard` read-only in-game, with rule pulses, makes the tool easy to debug with.
- **The comments.** They explain *why* (for example, the `clear_view` note about GraphEdit's deferred `move_child`).

## Things that look broken or stale

1. **Float noise in saved rects.** `Rect2(40, 20, 630.00024, 300.00012)` shows up in the `.tres`. The legacy generator rounds, but the resource path doesn't. Round in `_sync_layout`.
2. **README drift.** It mentions "inspect variable usage" in the Blackboard, which isn't implemented.

## Design improvements

- **`Zone` is a god class.** It is the router, blackboard, verb library, and validator all at once. Splitting it into `Blackboard`, a rule router, verb packs, and a validator would let zones opt into the verbs they need. It would also make the engine testable without a Node3D.
- **Verbs duplicate their own metadata.** Each verb calls `_step(&"say", [n, text, seconds], f)`, so the args array must be kept in sync by hand. Since `ZoneDefinition._build_step` already has the spec, it could set `step.verb` and `step.args` itself. Verbs would then just build closures, and the unset-prop check would move there.
- **Untyped dictionaries as the data model.** They make snapshot/undo trivial, which is a fair tradeoff. But typed sub-resources (`RuleData`, `StepData`, `VariableData`) would give you cleaner diffs, type safety, and the native inspector. At minimum, centralize the dictionary shapes in one place.
- **Renames break saved state.** `once` latches in `fired` are keyed by rule id, so renaming a rule orphans save data. Variable rename exists, but there is no rename or delete for events or relays (only `add_event`), so those can drift.
- **No validator checks for cycles or exclusivity.** Relay loops (A→B→A) aren't detected. Rules sharing a trigger, like `z1_caught` and `z1_delivered`, rely on mutually exclusive guards you can't verify. A cheap static check for both would be valuable.
- **`write_var` accepts undeclared keys silently.** A debug-build assert would catch typos at runtime.
- **`Expression` runs authored text with the zone as base.** A resource can call any method, such as `queue_free()`. That's fine for dev-authored data, but worth documenting if you ever load third-party zones.
- **`ctx` is unused.** `{"item_id": &"parcel"}` is passed on `deliver` but nothing reads it. Either add ctx-based conditions or remove it.

## Smaller code points

- **`game_manager.gd`:** `load_zone()` and `load_zone_scene()` are copy-pasted. Make the first call the second. Type `hud`, and connect `scored` to a method rather than a lambda.
- **`BumpProp`:**
  - It reaches into zone internals (`rule_fired.emit`, `is_set(relay)` as a latch, a blackboard key that equals the relay name). A `Zone.latch_and_fire(key)` API would keep the prefab decoupled.
  - `get_node("BumpArea")` is fragile; use an `@export` or a lookup.
- **`Player`:**
  - Use InputMap actions instead of hardcoded keys.
  - Overlapping `stun()` calls end the later stun early.
  - `interact()` triggers every overlapping area, so pick the nearest one.
- **`plugin.gd`:** Validate zone names (entering "zone" would generate `class_name Zone` and collide), and remove the leftover `<- change to match` comment.
- **Legacy script backend:** `ZoneSource` parsing/generation duplicates the resource path. If the `.tres` route is the future, delete the legacy path and move the shared helpers (`parse_literal`, `step_text`, `format_literal`) into a small utility class.
- **Undo history:** Dragging a SpinBox pushes one entry per tick. Coalescing consecutive edits to the same field would help.

## Testing and tooling

- Split the monolithic smoke test into deterministic unit tests (`ZoneSource` round-trips, validator cases, router guard logic) and a small number of runtime tests. The 4-second `create_timer` waits are flaky by nature. Consider a mockable clock for `repeat_emit` and delays.
- Consider GUT or gdUnit4, plus a CI job running Godot headless.
- Expand `.gitignore` (`export_presets.cfg` if sensitive, temp files).

## Priorities

If I were picking an order: fix the test and README drift first, then the `sleeping` double-fire and `&zzz_tick` typo, then drop the duplicated verb args, then add the validator cycle check. The `Zone` split and typed resources can wait until a second real zone puts pressure on the design.