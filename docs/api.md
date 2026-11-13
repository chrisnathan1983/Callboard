# Callboard API reference

[← Back to Callboard](../README.md)

[Stage](#stage) · [StageDefinition](#stagedefinition) · [Blackboard](#blackboard) · [TriggerArea](#triggerarea) · [Built-in verbs](#built-in-verbs) · [Custom verbs](#custom-verbs) · [RuleEngine](#ruleengine)

## Stage

[`Stage`](../addons/callboard/core/stage.gd) extends `Node3D`. Your game owns scene loading. The Stage builds its props, Blackboard, and rules during runtime `_ready()`, then calls `_restore_state()`. Call `activate()` once the Stage is ready and your listeners are connected.

```gdscript
extends Node3D

@export var stage_scene: PackedScene

var stage: Stage
var saved_vars: Dictionary = {}
var fired_rules: Dictionary = {}

func load_stage() -> void:
    stage = stage_scene.instantiate() as Stage
    stage.saved_vars = saved_vars
    stage.fired = fired_rules
    add_child(stage)
    stage.activate()

func unload_stage() -> void:
    stage.deactivate()
    remove_child(stage)
    stage.queue_free()
    stage = null
```

Call `load_stage()` from a parent already in the scene tree. Keep a pair of dictionaries per Stage if your game loads several Stages. Both dictionaries are shared by reference. Serialize and restore them in your save system if they should survive a game restart. See the [demo manager](../scripts/game_manager.gd) for signal wiring and reload behavior.

| Method | Contract |
| --- | --- |
| `activate() -> void` | Fires `arrive` after setup. Graph compilation errors block activation. Each call can dispatch `arrive` again. |
| `deactivate() -> void` | Cancels the current engine runs and clears pending work from diagnostics. Stage exit also cancels runs. |
| `fire(event: StringName, ctx := {}) -> void` | Dispatches an event and optional payload. Awaiting the rules is the engine's responsibility. Custom steps can read payload values from their `Dictionary` argument. |
| `get_var(key: StringName) -> Variant` | Reads the resolved Blackboard value. An unknown key returns `null`. |
| `write_var(key: StringName, value: Variant) -> void` | Writes a declared key using its Variant type. Integer inputs to float keys are converted to floats. |
| `is_set(key: StringName) -> bool` | Returns the value's truthiness. |
| `define_local(key, default_val = false, state_key = &"")` | Defines a key on the runtime Blackboard. Its initial value is rebuilt on each Stage load. |
| `define_saved(key, default_val = false, state_key = &"")` | Defines a key backed by `saved_vars`. The optional stable key selects the entry in the save dictionary. |
| `has_fired(rule_id: StringName) -> bool` | Checks whether a rule has a one-shot latch. Pass the current rule ID after a rename. |
| `fire_relay_once(relay, latch, source_id, source_event) -> bool` | Uses a declared Boolean Blackboard key as a latch. If it is false, writes true, emits `rule_fired(source_id, source_event)`, then dispatches `relay:<relay>`. Returns false for an empty relay, missing latch, or already truthy latch. Pass the bare relay name. |
| `check() -> Array[String]` | Runs the rule validator on the built Stage. |

| Signal | When it fires |
| --- | --- |
| `rule_fired(rule_id: StringName, event: StringName)` | A rule starts, or `fire_relay_once()` reports the supplied source. |
| `var_changed(key: StringName, value: Variant)` | An accepted Blackboard write. The key uses its current name. |
| `scored(points: int)` | A scoring step emits a score delta. The game owns the total. |

### Stage hooks

| Override | Purpose |
| --- | --- |
| `_build_props() -> void` | Create or bind props before rule steps are compiled. |
| `_build_blackboard() -> void` | Define or initialize script-owned keys after authored defaults are applied. |
| `_restore_state() -> void` | Restore scene presentation after the graph is built. The demo uses this to restore the guard's position and reward visibility. |
| `_make_verbs(context: StepContext) -> CoreVerbs` | Return the verb factory. The default is `StagingVerbs.new(context)`. |

Use `@tool` on the Stage script and custom verb factory so Callboard can analyze them in the editor. Initialize typed prop references in the scene or in `_build_props()` before the editor or runtime compiles steps.

## StageDefinition

[`StageDefinition`](../addons/callboard/core/stage_definition.gd) is the resource assigned to `Stage.definition`. The editor saves variables, rules, steps, and groups as typed subresources. Dictionary-based definitions migrate to format version 3 and retain their persisted state keys.

| Field | Purpose |
| --- | --- |
| `stage_script` | The `@tool` script extending `Stage`. |
| `preview_scene_path` | Optional scene path for editor analysis of scene-assigned props. Callboard otherwise looks for a same-name sibling `.tscn`, then falls back to constructing the script. |
| `external_calls` | Events supplied by gameplay. Include `arrive` when using that lifecycle trigger. |
| `external_vars` | Declared Blackboard keys that gameplay writes. This tells validation which values have a writer outside the graph. |
| `variables`, `rules`, `groups` | Authored subresources. Rule steps are stored with the rule. |

Use the generated `.tscn` when loading a Stage that relies on scene-assigned nodes. `StageDefinition.instantiate()` creates a Stage from its script and assigns the definition. Find working examples in [Stage 01](../stages/stage_01/) and the [scene-assigned prop fixture](../tests/fixtures/assigned_prop_stage.tscn).

Step arguments and delays are evaluated at graph compilation using Godot's [Expression](https://docs.godotengine.org/en/stable/classes/class_expression.html). Use project-authored data. The expressions can call methods and reference typed props and script constants. The event payload is available to the step callable when the rule runs.

## Blackboard

[`Blackboard`](../addons/callboard/core/blackboard.gd) is accessible as `stage.bb`. Gameplay can use the Stage wrappers above. Verb factories receive the same Blackboard through `StepContext.bb`.

| Method | Behavior |
| --- | --- |
| `define(key, scope, default, state_key = &"")` | Uses the default value's Variant type as the schema. Scope is `&"local"` or `&"saved"`. |
| `get_var(key)`, `write(key, value)` | Read or write a declared value. Writes to undeclared keys produce an error. Integer writes to float keys are converted. Other type mismatches warn and discard the write. Saved values with an outdated type revert to the declared default during setup. |
| `has(key)`, `is_set(key)` | Test whether a key is declared or whether its value is truthy. |
| `alias(old_key, new_key)`, `resolve_key(key)` | Support renamed keys. Callboard records aliases when it renames authored variables. |

The `changed(key, value)` signal is forwarded as `Stage.var_changed`. Use the write methods when gameplay changes a value so validation and notifications apply.

## TriggerArea

[`TriggerArea`](../addons/callboard/core/trigger_area.gd) extends `Area3D`. Place it under a Stage, add a `CollisionShape3D`, and set `event` and optional `ctx`. It locates the closest Stage ancestor.

- **ENTER** dispatches when a body in the `Player` or `Companion` group enters. Its mask uses physics layers 2 and 4, respectively.
- **INTERACT** dispatches when your controller calls `interact()`. The demo [player](../scripts/actors/player.gd) finds a nearby area using the trigger layer, physics layer 3.

Use [`StageCollisionLayers`](../addons/callboard/core/collision_layers.gd) for the bit masks, or call `stage.fire()` directly from your own interaction system.

## Built-in verbs

The default factory is [`StagingVerbs`](../addons/callboard/core/staging_verbs.gd), which inherits [`CoreVerbs`](../addons/callboard/core/core_verbs.gd). Each method returns a `Step`. Optional arguments are shown with their defaults.

| Factory | Verb | Effect |
| --- | --- | --- |
| Core | `set_var(key, value = true)` | Write a Blackboard value. |
| Core | `score(points)` | Emit a score delta. |
| Core | `repeat_emit(interval, tick)` | Emit `relay:<tick>` every interval in seconds until the rule is cancelled. This step occupies the rule while it runs. |
| Staging | `show_node(n, should_be_visible = true)` | Set a `Node3D`'s visibility. |
| Staging | `pop(n)`, `bounce(n)` | Play a scale animation. |
| Staging | `light(n, on, duration = 0.0, key = &"lamp_on")` | Set visibility and write a Boolean Blackboard key. A positive duration turns the light off on timeout or cancellation. |
| Staging | `say(n, text, seconds = 1.0)` | Show temporary text at a node. |
| Staging | `move_to(n, dest, offset = Vector3.ZERO, duration = 0.7)` | Tween a node to a target with an offset. |
| Staging | `flash(m)`, `jump(m)` | Tint a mesh or animate a vertical hop. Both use a BaseMaterial3D material override. |
| Staging | `stun_player(seconds)` | Invoke `stun(seconds)` on the first node in the `Player` group. The player controller supplies that method. |

## Custom verbs

Create a factory with public, typed methods returning [`Step`](../addons/callboard/core/step.gd). Factories run during editor analysis and runtime setup. Put gameplay effects inside the returned callable so they happen only during a rule run.

Save as `door_verbs.gd` beside your Stage script.

```gdscript
@tool
extends StagingVerbs

func unlock_door(door: Node3D, key: StringName) -> Step:
    var bb := context.bb
    var step := Step.new(func(_payload: Dictionary) -> void:
        bb.write(key, true)
        door.hide()
    )
    step.sets = [key]
    return step
```

Add this override to the Stage script.

```gdscript
const DoorVerbs = preload("door_verbs.gd")

func _make_verbs(context: StepContext) -> CoreVerbs:
    return DoorVerbs.new(context)
```

Declare a Boolean Blackboard key `door_open` and assign a typed `Node3D` property named `door` on the Stage. In the step picker, select `unlock_door` with arguments `door` and `&"door_open"`.

- `Step.sets` lists Blackboard keys written by the step. `Step.emits` names a relay the callable sends. These fields describe the step for validation and graph display.
- A step sends a relay by dispatching `relay:<name>` through the engine. Set `Step.emit_arg` to the zero-based argument index when that argument supplies the name so Callboard can rewrite it during a relay rename.
- A step callable accepts a payload dictionary and can await work or return a signal. `Step.after(seconds)` adds a delay before execution.
- For a custom step that awaits internally, capture `engine.token()` on entry and check `engine.alive(payload["_rule"], token)` after each await before applying more effects. Resolve the engine through `context.engine_ref` and release the strong reference before awaiting. See [`repeat_emit`](../addons/callboard/core/core_verbs.gd) for the pattern.

[`StepContext`](../addons/callboard/core/step_context.gd) supplies `bb`, the Stage `host`, a weak `engine_ref`, and the `score` callable. Treat underscore-prefixed payload fields as engine-owned.

## RuleEngine

[`RuleEngine`](../addons/callboard/core/rule_engine.gd) is exposed as `stage.engine` after setup. Use it for custom asynchronous verbs, diagnostics, or tests with a deterministic clock. The constructor accepts a Blackboard, a latch dictionary, and a wait callable of the form `func(seconds: float) -> Signal`.

| API | Purpose |
| --- | --- |
| `token()`, `alive(rule, token)` | Check whether a run can continue after asynchronous work. |
| `wait_tracked(seconds, rule_id, label)` | Use the configured clock and surface the wait in the live debugger. Returns the wait signal. |
| `track_signal(signal_to_track, rule_id, label, seconds = -1.0)` | Show a pending operation until its signal fires. A negative duration means the remaining time is unknown. |
| `active_snapshot()`, `pending_snapshot()` | Read active rules and queued counts, or pending waits and their remaining times. |
| `trace_event(entry)` | Observe lifecycle events. Entries include `time_ms`, `kind`, `rule`, `event`, `step`, `verb`, and `detail`. |
| `pending_changed(entries)`, `run_cancelled(rule_id)`, `all_cancelled` | Observe wait changes and cancellation. |

The rule engine dispatches matching rules in authored order. A rule's steps run in order and await their completion when applicable. A rule's own relay fires after its final step completes. Different rules can overlap. The re-entry policy governs repeated triggers of the same rule.

The [unit suite](../tests/unit.gd) exercises guards, re-entry, cancellation, and migration. The [runtime smoke test](../tests/smoke.gd) shows how to drive a Stage through the same calls the game uses.
