This is a well-engineered Godot 4 addon. The separation between the runtime (`core/`), the authoring/serialization layer (`model/`), and the `GraphEdit` UI (`editor/`) is clean, and the test coverage across `unit.gd`, `editor_smoke.gd`, and `smoke.gd` is much stronger than typical Godot plugins.

(Note: PowerShell's default encoding turned UTF-8 symbols like `✕` and `—` into mojibake like `âœ•` in `addon_source.txt`, which is just an artifact of the text export.)

---

## 1. What Works Exceptionally Well

* **Deterministic Clock Injection (`RuleEngine.wait`)**: Injecting `wait: Callable` into `RuleEngine` so tests can pass a signal (`clock_tick`) instead of waiting on `SceneTreeTimer` makes async step delays, `repeat_emit` loops, mid-flight cancellation, and re-entry policies 100% deterministic in `tests/unit.gd`.


* **Save-Safe Renaming (`state_key` & `_saved_names`)**: Generating stable `@<hex>` UUIDs via `ZoneSource.new_state_key()` and resolving them in `Blackboard.resolve_key()` and `Rule.latch_key()` solves a painful game-dev problem—designers can rename Blackboard variables and rules in the editor without invalidating existing player save files or gameplay code.


* **Reference-Cycle Prevention**: Using `weakref(engine)` in `StepContext` and explicitly clearing `zone.engine.rules.clear()` before freeing preview instances in `RuleGraphReader` and `ZonePreview` prevents leaked `RefCounted` closures between `RuleEngine -> Rule -> Step -> Callable`.


* **`GraphEdit` Frame Disposal Workaround**: `RuleGraphView.clear_view()` properly works around Godot's internal deferred `move_child` bug on `GraphFrame`s by detaching elements first, marking them with `"dead"` metadata, renaming them to `"dead_%d"`, hiding them, and calling `queue_free()`.



---

## 2. Subtle Bugs & Runtime Edge Cases

### A. `StagingVerbs.light()` Ignores Rule Cancellation & `RESTART`

In `addons/director_blackboard/core/verbs.gd`, `light()` captures `var gen := engine.token()` and checks `current.token() == gen` when its duration timer expires:

```gdscript
if current and current.token() == gen and is_instance_valid(n):
    apply.call(false)

```

However, `_gen` only increments on `RuleEngine.cancel_all()` (zone deactivation). If the rule that turned on the light is aborted mid-flight by `cancel_if` or restarted via `ReentryPolicy.RESTART`, `current.token() == gen` remains `true`. The stale timer from the first run will still fire and turn the light off in the middle of the restarted run.

* **Fix**: Capture `var rule: Rule = _c["_rule"]` inside `f` and check `current.alive(rule, gen)` in the timeout callback, matching the pattern in `CoreVerbs.repeat_emit()`.



### B. `Rule.once` Blocks `ReentryPolicy.RESTART` and `QUEUE`

In `RuleEngine._run()`, `if r.once: fired[r.latch_key()] = true` latches the rule before the first step starts.
If a rule is configured with both `once = true` and `reentry = RESTART` (or `QUEUE`), any re-entering trigger during that first run is blocked at `RuleEngine.fire()` because `passes(r)` checks `if r.once and fired.has(r.latch_key()): return false` before calling `_dispatch()`. Even if it reached `_dispatch()`, the `while` loop in `_dispatch()` calls `passes(r)` again before running queued/restarted payloads.

* **Fix**: Either disable the `ReentryPolicy` dropdown in `RuleInspector` when `Run once` is checked, or move the `fired[r.latch_key()] = true` latch to the end of `_run()` (or allow active `RESTART` runs to bypass the `once` check in `passes(r)`).



### C. Scene-Placed Props (`@export` / `@onready`) Will Fail Editor Validation

`ZoneDefinition.instantiate()` creates a bare script instance via `zone_script.new()`, and `RuleGraphReader.analyze()` calls `instance.build()` on that unparented instance without instantiating the `.tscn` scene or entering the SceneTree.

* In `zone_01.gd`, this works because every prop (`guard`, `lamp`, `shelter`, etc.) is instantiated in code inside `_build_props()`.


* If a designer places a `Node3D` in `zone_02.tscn` in the 3D editor and references it via `@export var door: Node3D` or `@onready var door: Node3D = $Door`, `instance.get("door")` will be `null` during `ZoneDefinition.apply_graph()`. That puts `null` into `step.args`, causing `RuleValidator` to flag every step using `door` with `"has a '...' step with an unset prop"`.


* **Fix**: When `ZoneDefinition._build_step()` builds steps for editor validation (or in `VerbCatalog.props_of()`), either allow `ZoneDefinition` to reference the `.tscn` `PackedScene` for preview instantiation, or synthesize placeholder dummy objects of the declared `prop["class"]` when `zone.get(prop["name"]) == null` on an unparented preview instance.



### D. Overlapping `Label3D` Nodes in `StagingVerbs.say()`

`StagingVerbs.say()` creates a new `Label3D` at `Vector3(0, 1.6, 0)` and adds it as a child of `n`. Because `say()` is non-blocking, if two `say()` steps execute on the same actor within `seconds` of each other, both `Label3D` nodes render on top of each other at the exact same offset.

* **Fix**: Give the label a fixed name (e.g., `label.name = "DirectorSpeech"`) and free or replace any existing child with that name on `n` before adding the new one.



---

## 3. Editor Performance & UX

### A. Full Graph & 3D Zone Rebuild on Every `SpinBox` Tick

In `RuleBoard._changed()`, every edit calls both `RuleGraphReader.analyze(_data)` and `view.show_data(_data)` synchronously:

```gdscript
func _changed(select_id: String, spin: SpinBox = null) -> void:
    if not _editable or _restoring:
        return
    _sync_layout()
    RuleGraphReader.analyze(_data)
    view.show_data(_data)

```

When dragging a `SpinBox` (such as a step's `Delay (s)` in `RuleInspector` or a numeric default in `BlackboardPanel`), `value_changed` fires continuously on mouse movement. Although `_selecting_after_edit = spin != null` smartly prevents `RuleInspector` from destroying the active `SpinBox`, every tick still:

1. Instantiates a temporary `Zone`, builds all 3D meshes and physics shapes in `_build_props()`, compiles and executes `Expression`s for every step, and frees the `Zone`.


2. Destroys and recreates every `GraphNode`, `GraphFrame`, and connection wire on the `RuleGraphView` canvas.



* **Fix**: When `spin != null` and `_spin_drag_active` is `true`, update only the text of the affected `GraphNode` slot row (or defer `analyze()` and `view.show_data()` until mouse release in `RuleBoard._input()`).



### B. Repeated `RegEx` Compilation Inside Hot Loops

`ZoneDefinition._build_step()`, `ZoneSource.parse_literal()`, and `RuleConnections.rename()` call `RegEx.create_from_string(...)` every time they execute. Since `_build_step()` runs for every step of every rule on every `analyze()` call, hoisting those regexes into static variables or constants avoids repeated regex compilation.

---

## 4. Feedback on `TODO.md` (Callboard Rename & Backlog)

Your `TODO.md` plan is very well structured, especially **Commit 0** (splitting `ZoneSource` into `ExprText` + model helpers and removing the legacy script-parsing backend before renaming). A few specific notes on your checklist:

* **Re-entrancy is already implemented**: In `TODO.md` Part 2, *"P1: Define re-entrancy for rules"* is still unchecked, but `Rule.ReentryPolicy` (`IGNORE`, `RESTART`, `QUEUE`) is already implemented across `rule.gd`, `rule_engine.gd`, `rule_inspector.gd`, `zone_definition.gd`, and tested in `unit.gd` and `editor_smoke.gd`. You can check that off (unless you still want to add a `PARALLEL` option).


* **Simpler `.tres` Migration in Commit 2**: `TODO.md` suggests a `_set` fallback or `_get_property_list` shim on `StageDefinition`. In Godot 4:


* Implementing `_set(property: StringName, value: Variant) -> bool` on `StageDefinition` is the cleanest way to catch old property names (`&"zone_script"` -> `stage_script`, `&"external_events"` -> `external_calls`) when `ResourceLoader` parses an old `.tres` file.
* However, `_set()` is **not** called for `@export var rules: Array` if the property name `rules` itself hasn't changed. Instead of a `_get_property_list` shim, attach a setter (`@export var rules: Array = []: set = _set_rules`) that normalizes each rule dictionary in-place (renaming `"once"` to `"one_shot"` and filling default keys) as soon as the `.tres` loads.




* **Shared-Trigger Validation (`RuleValidator._find_shared_trigger_conflicts`)**: Right now, having two rules listen to the same event without mutually exclusive `requires`/`forbids` guards produces a validation warning. In many games, two independent rules intentionally react to `"arrive"` (e.g., one starts an ambient loop and another triggers an entrance animation). Only flagging shared triggers when both rules write to the same Blackboard key (`s.sets` overlap) or manipulate the same prop in `s.args` would reduce false-positive warnings even before adding a per-rule override flag.