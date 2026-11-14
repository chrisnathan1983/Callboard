# Callboard API reference

[← Back to Callboard](../README.md)

[Stage](#stage) · [StageDefinition](#stagedefinition) · [Blackboard](#blackboard) · [TriggerArea](#triggerarea) · [Built-in verbs](#built-in-verbs) · [Custom verbs](#custom-verbs) · [RuleEngine](#ruleengine)

## Stage

[`Stage`](../core/stage.gd) extends `Node3D`. Your game owns scene loading. The Stage builds its props, Blackboard, and rules during runtime `_ready()`, then calls `_restore_state()` and its declarative restoration bindings. Call `activate()` once the Stage is ready and your listeners are connected. A managed Stage stays dormant until activation.

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

Call `load_stage()` from a parent already in the scene tree. Keep a pair of dictionaries per Stage if your game loads several Stages. Both dictionaries are shared by reference. Serialize and restore them in your save system if they should survive a game restart.

Preserve Variant types when saving these dictionaries. For example, use `var_to_str()` and `str_to_var()`. JSON reads numbers as floats, so a JSON save layer needs to restore declared integer values to `int` before assigning `saved_vars`.

When `SceneTree.paused` is true, rule delays, repeat ticks, and timed lights stop counting down. They resume with their remaining time when the tree unpauses. Staging tweens follow the host node's pause behavior. A direct `fire()` call still dispatches rules while paused.

| Method | Contract |
| --- | --- |
| `activate() -> void` | Fires `arrive` after setup. Graph compilation errors block activation. Managed Stages activate once per entry; unmanaged Stages retain the existing repeatable behavior. |
| `deactivate() -> void` | Cancels current runs and queued triggers, releases waits registered with `RuleEngine.interruptible()`, and clears pending diagnostics. For managed Stages this also makes the Stage dormant. Stage exit also cancels runs. |
| `accepts_calls() -> bool` | Returns false while a managed Stage is dormant. `fire()` ignores Calls in that state. |
| `attach_state_store(store, instance_id, saved, fired, shared) -> void` | Injects dictionaries before initialization. Usually called by `StageStateStore.attach()` or `load_stage()`. |
| `define_shared(key, default_val = false, state_key = &"")` | Defines a shared Blackboard key backed by the StageStateStore's shared dictionary. |
| `fire(event: StringName, payload := {}) -> void` | Dispatches a Call ID such as `deliver` or a relay event ID such as `relay:calm_guard`. The optional dictionary is the event payload available to guards and steps. The engine runs any asynchronous work. Managed dormant Stages ignore Calls. |
| `get_var(key: StringName) -> Variant` | Reads the resolved Blackboard value. An unknown key returns `null`. |
| `write_var(key: StringName, value: Variant, writer: StringName = &"") -> void` | Writes a declared key using its Variant type. Integer inputs to float keys are converted to floats. An optional writer label appears in the live Blackboard view. |
| `is_set(key: StringName) -> bool` | Returns the value's truthiness. |
| `define_local(key, default_val = false, state_key = &"")` | Defines a key on the runtime Blackboard. Its initial value is rebuilt on each Stage load. |
| `define_saved(key, default_val = false, state_key = &"")` | Defines a key backed by `saved_vars`. The optional stable key selects the entry in the save dictionary. |
| `has_fired(rule_id: StringName) -> bool` | Checks whether a rule has a one-shot latch. Pass the current rule ID after a rename. |
| `fire_relay_once(relay, latch, source_id, source_event) -> bool` | Uses a declared Boolean Blackboard key as a latch. If it is false, writes true, emits `rule_fired(source_id, source_event)`, then dispatches `relay:<relay>`. Returns false for an empty relay, an invalid latch key, or an already set latch. Pass the bare relay name. |
| `register_external_writer(key, source = &"gameplay", value_type = "Variant") -> void` | Declares a gameplay producer before validation. Supported explicit types are `bool`, `int`, `float`, `String`, and `StringName`; `Variant` leaves type compatibility to runtime writes. |
| `check() -> Array[String]` | Runs the rule validator on the built Stage. |

### Typed event payloads

Declare optional payload schemas with `PayloadFieldData` entries in the StageDefinition's `payload_fields` array. In the Callboard rule inspector, select a rule and add fields under **Payload fields for [trigger]**. Set the field name and type (`bool`, `int`, `float`, or `String`). The schema is specific to an event ID; relay IDs include their prefix, such as `relay:parcel_ready`.

```gdscript
stage.fire(&"interact", {"action": "confirm", "item": "key"})
```

Use `payload.action == "confirm"`, `payload.accepted == true`, or `payload.count >= 2` in Requires, Forbids, and Cancel If. Use `has(payload.item)` and `missing(payload.item)` for explicit presence checks. Missing and incompatible values fail a comparison, including `!=`. String and Boolean fields support equality and inequality; numeric fields support the six comparison operators. A bare name such as `door_open` still addresses the Blackboard.

The inspector lists the selected trigger's declared fields and guard payload references separately. When a trigger schema exists, Callboard validates field names, literal types, and operators against it. Without a schema, runtime comparison still checks the actual Variant type. Relays emitted by rules and `repeat_emit` forward the original authored payload.

Step callables receive authored fields at the top level for compatibility and also under `context["payload"]`. Callboard metadata is grouped under `context["_callboard"]` (`rule` and `run`); reserve `payload` and `_callboard` as field names. Queued runs retain and recheck their own payload. Cancel If always reads the payload of the active run.

| Signal | When it fires |
| --- | --- |
| `rule_fired(rule_id: StringName, event: StringName)` | A rule starts, or `fire_relay_once()` reports the supplied source. |
| `var_changed(key: StringName, value: Variant)` | An accepted write that changes the stored Blackboard value. The key uses its current name. |
| `scored(points: int)` | A scoring step emits a score delta. The game owns the total. |
| `gameplay_event(event_id: StringName, arguments: Dictionary)` | A `gameplay_event` step asks host code to apply a project-specific action. |

Connect to `stage.gameplay_event` after loading the Stage. The addon emits the authored ID and a deep copy of the arguments; it does not interpret them. `Stage.scored` and the `score(points)` verb remain available for score deltas.

### Stage hooks

| Override | Purpose |
| --- | --- |
| `_build_props() -> void` | Create or bind props before rule steps are compiled. |
| `_build_blackboard() -> void` | Define or initialize script-owned keys after authored defaults are applied. |
| `_declare_external_writers() -> void` | Call `register_external_writer()` for outputs provided by Stage gameplay code. Runs after authored keys are applied and before graph validation. |
| `_restore_state() -> void` | Restore custom scene state after the graph is built and before declarative restoration bindings run. |
| `_make_verbs(context: StepContext) -> CoreVerbs` | Return the verb factory. The default is `StagingVerbs.new(context)`. Put game-specific effects and Blackboard key defaults in a Stage-specific subclass. |

Use `@tool` on the Stage script and custom verb factory so Callboard can analyze them in the editor. Initialize typed prop references in the scene or in `_build_props()` before the editor or runtime compiles steps.

## StageDefinition

[`StageDefinition`](../core/stage_definition.gd) is the resource assigned to `Stage.definition`. The editor saves variables, rules, steps, and groups as typed subresources. Older dictionary-based definitions migrate to the current format and retain their persisted state keys.

| Field | Purpose |
| --- | --- |
| `stage_script` | The `@tool` script extending `Stage`. |
| `preview_scene_path` | Optional scene path for editor analysis of scene-assigned props. Callboard otherwise looks for a same-name sibling `.tscn`, then falls back to constructing the script. |
| `managed_lifecycle` | Opts the Stage into dormant loading, activation on entry, and Call filtering while dormant. |
| `restoration_bindings` | `StageRestorationBinding` resources that restore visibility, saved transforms, Marker3D positions, and optional AnimationPlayer poses before activation. |
| `external_calls` | Events supplied by gameplay. Use bare IDs for Calls and `relay:<name>` IDs for external relays. Include `arrive` when using that lifecycle trigger. |
| `call_positions` | Saved graph positions keyed by external event ID. |
| `external_vars` | Declared Blackboard keys that gameplay writes. This tells validation which values have a writer outside the graph. |
| `external_writers` | `BlackboardWriterData` resources describing key, source label, and output type for typed gameplay producers. These declarations satisfy guard producer checks and are checked against the Blackboard schema. |
| `variables`, `rules`, `groups` | Authored subresources. Rule steps are stored with the rule. |

Use the generated `.tscn` when loading a Stage that relies on scene-assigned nodes. `StageDefinition.instantiate()` creates a Stage from its script and assigns the definition.

Step arguments and delays are evaluated at graph compilation using Godot's [Expression](https://docs.godotengine.org/en/stable/classes/class_expression.html). Use project-authored data. The expressions can call methods and reference typed props and script constants. The event payload is available to the step callable when the rule runs.

## Blackboard

[`Blackboard`](../core/blackboard.gd) is accessible as `stage.bb`. Gameplay can use the Stage wrappers above. Verb factories receive the same Blackboard through `StepContext.bb`.

| Method | Behavior |
| --- | --- |
| `define(key, scope, default, state_key = &"")` | Uses the default value's Variant type as the schema. Scope is `&"local"`, `&"saved"`, or `&"shared"`. |
| `get_var(key)`, `write(key, value)` | Read or write a declared value. Writes to undeclared keys produce an error. Integer writes to float keys are converted. Other type mismatches warn and discard the write. Saved values with an outdated type revert to the declared default during setup. |
| `has(key)`, `is_set(key)` | Test whether a key is declared or whether its value is truthy. |
| `alias(old_key, new_key)`, `resolve_key(key)` | Support renamed keys. Callboard records aliases when it renames authored variables. |

The `changed(key, value)` signal is forwarded as `Stage.var_changed`. Use the write methods when gameplay changes a value so validation and notifications apply. `BlackboardWriter` is a scene component with an exported `callboard_writers` list and a `publish(key, value)` method; the Stage collects its declarations during editor analysis and runtime setup. Custom scene nodes may expose the same property. The live Blackboard shows the most recent non-empty writer label for each key.

## StageStateStore

[`StageStateStore`](../core/stage_state_store.gd) is a Resource that owns per-instance `saved` and `fired` dictionaries plus a shared Blackboard dictionary. Use a distinct, stable ID for each loaded plot, even when two plots use the same scene.

```gdscript
var store := StageStateStore.new()
var left_yard := store.load_stage(yard_scene, &"house_01_left", self)
var right_yard := store.load_stage(yard_scene, &"house_01_right", self)

# Managed Stages have finished restoring but remain dormant here.
left_yard.activate()

store.unload_stage(left_yard)
store.unload_stage(right_yard)
```

`load_stage()` injects state before adding the Stage to the tree. `unload_stage()` deactivates it and retains its dictionaries for the next load. Save the Resource or serialize `stage_states` and `shared_values` with Variant-preserving storage to persist across game restarts. Shared Blackboard keys should use the same `state_key` and Variant type in every Stage. Conflicting declarations appear in Stage diagnostics, and incompatible shared writes are rejected. Direct `saved_vars` and `fired` dictionary injection remains supported for existing managers.

## Declarative restoration

Add `StageRestorationBinding` resources to a StageDefinition. `VISIBILITY` maps a saved/shared Boolean to `visible` on a `CanvasItem` or `Node3D` (including lights). `TRANSFORM` applies a saved/shared `Transform3D` to a `Node3D`. `SNAP_TO_MARKER` uses a saved/shared Boolean to snap a `Node3D` to a `Marker3D`; optionally set both the AnimationPlayer path and animation name to seek and pause at a resolved pose. Callboard analysis validates the key scope and type, node paths, marker type, and animation reference. Bindings run after `_restore_state()` and before activation.

## TriggerArea

[`TriggerArea`](../core/trigger_area.gd) extends `Area3D`. Place it under a Stage, add a `CollisionShape3D`, and set `event` and optional `ctx`. It locates the closest Stage ancestor.

- **ENTER** dispatches when a body in the `Player` or `Companion` group enters. Its mask uses physics layers 2 and 4, respectively.
- **INTERACT** is selected by an [`InteractionResolver`](../core/interaction_resolver.gd) from the actor's overlapping trigger areas. Configure the resolver with the actor and its reach area, then call `resolver.interact(context)` from the input handler or UI.

`TriggerArea` assigns its collision layer and mask on startup. Use [`StageCollisionLayers`](../core/collision_layers.gd) for the bit masks, or call `stage.fire()` directly from your own interaction system.

Interactable triggers expose `prompt_text`, optional `prompt_icon`, and `interaction_priority`. The resolver chooses the eligible trigger with the highest priority, then the shortest distance from the actor, then the lexicographically first node path. It polls while the actor remains in range, so host state can enable or disable an interaction without an area exit/re-entry.

```gdscript
var resolver := InteractionResolver.new()
add_child(resolver)
resolver.configure(actor, reach_area)
resolver.prompt_changed.connect(_show_prompt) # (text, icon, priority)
resolver.selected_trigger_changed.connect(_refresh_selection)

# For example, a host-owned inventory rule can decide whether this trigger is available.
trigger.set_eligibility_hook(func(interacting_actor: Node) -> bool:
    return inventory.has("permit")
)
trigger.set_interaction_handler(func(interacting_actor: Node, context: Dictionary) -> Dictionary:
    inventory.erase("permit")
    return {"accepted": true, "payload": {"accepted": true, "item": "permit"}}
)
var result: Dictionary = resolver.interact({"source": "door_ui"})
```

`set_eligibility_hook()` receives the interacting actor. It controls whether the trigger is offered. Override `is_interaction_eligible(actor)` for a reusable trigger subtype. The prompt signal carries the displayed text, icon, and priority; read `resolver.selected_trigger` when the subscriber needs the trigger itself. `selected_trigger_changed` has no arguments and fires when selection changes.

The interaction context begins as a deep copy of the trigger's `ctx`, then caller context values override matching keys. `set_interaction_handler()` or an override of `handle_interaction(actor, context)` returns `{accepted: bool, payload: Dictionary}`. Accepted results dispatch the trigger's `event`; rejected results dispatch `rejected_event` if configured. The returned result dictionary includes `accepted`, dispatched `event`, and `payload`. `interaction_completed(actor, result)` on the trigger and `interaction_completed(trigger, result)` on the resolver report the result. Inventory checks, item consumption, and other game policy stay in the host handler.

## Built-in verbs

The default factory is [`StagingVerbs`](../core/staging_verbs.gd), which inherits [`CoreVerbs`](../core/core_verbs.gd). Each method returns a `Step`. Optional arguments are shown with their defaults.

| Factory | Verb | Effect |
| --- | --- | --- |
| Core | `set_var(key, value = true)` | Write a Blackboard value. |
| Core | `add_var(key, delta)` | Add a positive or negative numeric delta to an `int` or `float` Blackboard value when the step executes. Integer keys require a whole-number delta. |
| Core | `score(points)` | Emit a score delta. |
| Core | `repeat_emit(interval, tick)` | Emit `relay:<tick>` every interval in seconds until the rule is cancelled. This step occupies the rule while it runs. |
| Staging | `show_node(n, should_be_visible = true)` | Set a `Node3D`'s visibility. |
| Staging | `light(n, on, duration = 0.0, key = &"")` | Set visibility immediately. A positive duration turns it off at timeout, rule cancellation, or Stage deactivation. The optional key mirrors the Boolean state and must be declared as a Boolean Blackboard value. |
| Staging | `pop(n)`, `bounce(n)` | Play a scale animation. |
| Staging | `say(n, text, seconds = 1.0)` | Show temporary text at a node. |
| Staging | `move_to(n, dest, offset = Vector3.ZERO, duration = 0.7)` | Tween a node to a target with an offset. |
| Staging | `play_audio(player, wait_for_completion = false)` | Play an `AudioStreamPlayer`, `AudioStreamPlayer2D`, or `AudioStreamPlayer3D`. Waiting holds the rule until the stream finishes. |
| Staging | `rotate_to(n, target_rotation, duration = 0.25, wait_for_completion = true)` | Rotate a `Node3D` to Euler angles in radians. Set duration to zero for an immediate change or disable waiting to let the tween continue in the background. |
| Staging | `play_animation(player, animation, wait_for_completion = true)` | Play a named `AnimationPlayer` clip. Waiting releases on clip completion or Stage deactivation. |
| Staging | `pose_animation(player, animation, time = 0.0)` | Seek to a time in a named clip and pause there. |
| Staging | `gameplay_event(event_id, arguments = {})` | Emit `Stage.gameplay_event` for host-owned behavior such as doors, quests, or inventory. |
| Staging | `flash(m)`, `jump(m)` | Tint compatible `BaseMaterial3D` overrides or mesh surfaces. Materials are duplicated for the target instance; `jump` still performs its hop when no tintable material exists. |

When `move_to` and `jump` overlap on the same node, the latest step controls its position. Earlier steps finish on their original schedule so their rules can continue.

`light` writes the supplied key only when it is non-empty. A timed turn-on writes `true`, then writes `false` when it turns off. A newer activation owns the node, so an older timeout cannot turn off a newer light state. The editor reports missing targets, missing/non-Boolean light keys, absent audio streams, and missing animation clips before Stage activation.

The wait options on `play_audio`, `rotate_to`, and `play_animation` are explicit. A waiting rule resumes when the source finishes; use a non-looping clip or stream when waiting for playback completion. Stage deactivation releases its wait. Non-waiting tween/audio/animation actions continue according to their Godot node's lifetime and process mode.

### Built-in cancellation behavior

The engine checks **Cancel If** before the first step and after each step or delay. **Restart** replaces an active run at its next cancellation check. A cancelled run skips its remaining steps and completion relay. One-shot latches record the start and stay set after cancellation.

| Verb | Effect after cancellation |
| --- | --- |
| `set_var`, `add_var`, `score`, `show_node` | Completed writes, score changes, and visibility changes stay applied. |
| `repeat_emit` | Checks before each tick and stops emitting when cancelled. Deactivation releases its timer wait immediately. |
| `pop`, `bounce`, `move_to`, waiting `rotate_to` | The tween finishes while the Stage remains in the tree. Deactivation immediately releases the rule's wait. |
| `flash`, `jump` | The tint restores the target instance's base colors and the hop returns to its base height. Deactivation immediately releases the rule's wait. |
| Waiting `play_audio`, `play_animation` | The rule waits for playback to finish. Stage deactivation immediately releases the wait. |
| `say` | The label expires on its own timer. A later `say` on the same node replaces it and starts a new timer. |
| `light` | A timed activation turns off on timeout, cancellation of its run, or Stage deactivation. A newer activation owns the light. Untimed visibility and Blackboard changes stay applied. |

Connect the gameplay event listener before activation so it also receives requests from arrival rules. Use the optional Blackboard key on the light step when guards need to check the current light state.

## Custom verbs

Create a factory with public, typed methods returning [`Step`](../core/step.gd). Factories run during editor analysis and runtime setup. Put gameplay effects inside the returned callable so they happen only during a rule run.

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

- `Step.reads` and `Step.sets` list Blackboard keys read and written by the step. `Step.emits` names a relay the callable sends. These fields describe the step for validation and graph display.
- A step sends a relay by dispatching `relay:<name>` through the engine. Set `Step.emit_arg` to the zero-based argument index when that argument supplies the name so Callboard can rewrite it during a relay rename.
- A step callable accepts a context dictionary and can await work or return a signal. Read event fields from `context["payload"]` (or from their top-level compatibility aliases). `Step.after(seconds)` adds a delay before execution.
- For a custom step that awaits internally, capture `engine.token()` on entry and check `engine.alive(context["_callboard"]["rule"], token)` after each await before applying more effects. Wrap a signal with `engine.interruptible(signal)` to resume the wait on deactivation, then perform the same cancellation check. Resolve the engine through `context.engine_ref` and release the strong reference before awaiting. See [`repeat_emit`](../core/core_verbs.gd) for the pattern.

[`StepContext`](../core/step_context.gd) supplies `bb`, the Stage `host`, a weak `engine_ref`, and the `score` callable. Engine run metadata is isolated under the step context's `_callboard` key.

## RuleEngine

[`RuleEngine`](../core/rule_engine.gd) is exposed as `stage.engine` after setup. Use it for custom asynchronous verbs, diagnostics, or tests with a deterministic clock. The constructor accepts a Blackboard, a latch dictionary, and a wait callable of the form `func(seconds: float) -> Signal`.

| API | Purpose |
| --- | --- |
| `token()`, `alive(rule, token)` | Check whether a run can continue after asynchronous work. |
| `interruptible(source)` | Return a signal that completes when the source emits or the engine deactivates. The caller checks cancellation before continuing its work. |
| `wait_tracked(seconds, rule_id, label)` | Use the configured clock and surface the wait in the live debugger. Returns the wait signal. |
| `track_signal(signal_to_track, rule_id, label, seconds = -1.0)` | Show a pending operation until its signal fires. A negative duration means the remaining time is unknown. |
| `active_snapshot()`, `pending_snapshot()` | Read active rules and queued counts, or pending waits and their remaining times. |
| `trace_event(entry)` | Observe lifecycle events. Entries include `time_ms`, `kind`, `rule`, `event`, `step`, `verb`, and `detail`. |
| `pending_changed(entries)`, `run_cancelled(rule_id)`, `all_cancelled` | Observe wait changes and cancellation. |

The rule engine dispatches matching rules in authored order. A rule's steps run in order and await their completion when applicable. A rule's own relay fires after its final step completes. Different rules can overlap. The re-entry policy governs repeated triggers of the same rule.

Graph compilation errors block editor saves and runtime `activate()`. `Stage.check()` reports advisory findings such as relay cycles and shared-trigger overlap. In a debug build, `activate()` logs those findings as warnings and still dispatches `arrive` if compilation succeeded. A direct call to `fire()` dispatches without running `activate()`.

The [unit suite in the source repository](https://github.com/chrisnathan1983/director_blackboard_demo_4/blob/main/addons/callboard/tests/unit.gd) exercises guards, re-entry, cancellation, and migration.

## Embedding the live debugger

`CallboardDebugPanel.create()` returns an unparented `PanelContainer` in debug builds when the board script is available. It returns `null` in release builds or when the authoring code is absent. Place the panel in your HUD and bind a Stage after the Stage has entered the scene tree.

```gdscript
var panel := CallboardDebugPanel.create()
if panel:
    add_child(panel)
    panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    panel.bind_stage(stage)
```

Call `bind_stage()` again after loading a replacement Stage. The HUD controls the panel's layout and visibility.
