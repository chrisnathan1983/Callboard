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
| `activate() -> void` | Fires `arrive` after setup. Build the Stage before activating it. Graph compilation errors block activation. Managed Stages activate once per entry; unmanaged Stages retain the existing repeatable behavior. |
| `deactivate() -> void` | Cancels current runs and queued triggers, releases waits registered with `RuleEngine.interruptible()`, and clears pending diagnostics. For managed Stages this also makes the Stage dormant. Stage exit also cancels runs. |
| `accepts_calls() -> bool` | Returns false before build, when the graph has compile errors, or while a managed Stage is dormant. |
| `attach_state_store(store, instance_id, saved, fired, shared) -> bool` | Injects dictionaries before initialization. Returns false if the Stage's Blackboard or engine has already been initialized. Usually called by `StageStateStore.attach()` or `load_stage()`. |
| `define_shared(key, default_val = false, state_key = &"")` | Defines a shared Blackboard key backed by the StageStateStore's shared dictionary. |
| `fire(event: StringName, payload := {}) -> void` | Dispatches a Call ID such as `deliver` or a relay event ID such as `relay:calm_guard`. The optional dictionary is the event payload available to guards and steps. `on_change` is reserved and dispatched automatically after a Blackboard commit. Build first. Valid unmanaged Stages can fire without `activate()`; invalid graphs and dormant managed Stages block Calls. |
| `publish_gameplay_event(event_id, arguments = {}) -> void` | Emits a typed host request only when the Stage is built, its graph is valid, and a managed Stage is active. The host owns the request's meaning. |
| `respond_gameplay_request(request_id, accepted, data = {}) -> bool` | Completes one published correlated request. Returns false for duplicate/late IDs or response data that violates its declared schema. |
| `fire_relay_once(relay, latch, source_id, source_event) -> bool` | Applies the same lifecycle and graph checks as `fire()`. It reports success only after synchronously committing an unset Boolean latch and emitting the relay. |
| `get_var(key: StringName) -> Variant` | Reads the resolved Blackboard value. An unknown key returns `null`. |
| `write_var(key: StringName, value: Variant, writer: StringName = &"") -> bool` | Writes a declared key using its Variant type. Integer inputs to float keys are converted to floats. Returns true when a changed value is accepted; false for rejected or unchanged writes. An optional writer label appears in the live Blackboard view. |
| `is_set(key: StringName) -> bool` | Returns the value's truthiness. |
| `define_local(key, default_val = false, state_key = &"")` | Defines a key on the runtime Blackboard. Its initial value is rebuilt on each Stage load. |
| `define_saved(key, default_val = false, state_key = &"")` | Defines a key backed by `saved_vars`. The optional stable key selects the entry in the save dictionary. |
| `has_fired(rule_id: StringName) -> bool` | Checks whether a rule has a one-shot latch. Pass the current rule ID after a rename. |
| `fire_relay_once(relay, latch, source_id, source_event) -> bool` | Uses a declared Boolean Blackboard key as a latch. If it is false, it commits true before emitting `rule_fired(source_id, source_event)` and dispatching `relay:<relay>`. Returns false when the latch write is rejected, unchanged, already set, or cannot commit synchronously. Pass the bare relay name. |
| `register_external_writer(key, source = &"gameplay", value_type = "Variant") -> void` | Declares a gameplay producer before validation. Supported explicit types are `bool`, `int`, `float`, `String`, and `StringName`; `Variant` leaves type compatibility to runtime writes. |
| `check() -> Array[String]` | Runs the rule validator on the built Stage. |

### Typed event payloads

Declare optional payload schemas with `PayloadFieldData` entries in the StageDefinition's `payload_fields` array. In the Callboard rule inspector, select a rule and add fields under **Payload fields for [trigger]**. Set the field name and type (`bool`, `int`, `float`, or `String`). The schema is specific to an event ID; relay IDs include their prefix, such as `relay:parcel_ready`.

```gdscript
stage.fire(&"interact", {"action": "confirm", "item": "key"})
```

Use `payload.action == "confirm"`, `payload.accepted == true`, or `payload.count >= 2` in Requires, Forbids, and Cancel If. Use `has(payload.item)` and `missing(payload.item)` for explicit presence checks. Combine terms with `and`/`&&`, `or`/`||`, parentheses, or `any(...)`, for example `any(sensor_active, override_enabled)` and `(completed_count >= required_count) and payload.action == "confirm"`. Comparisons may use another Blackboard key on the right, as in `completed_count >= required_count`; a `payload.` prefix reads that field from the Call payload. Numeric keys support all six operators. `String` and `StringName` values support `==` and `!=`, including quoted strings and `&"name"` StringName literals. Boolean values support equality and inequality. Missing and incompatible values fail a comparison, including `!=`. Integer-to-integer comparisons are exact. Comparisons involving a float use approximate equality for `==` and `!=`, and numeric ordering. Without a schema for an event, payload values are checked against the comparison at runtime. Once any fields are declared for an event, referenced fields must be declared and match their runtime Variant type. A bare name such as `door_open` still addresses the Blackboard.

The inspector lists the selected trigger's declared fields and guard payload references separately, including fields nested in grouped expressions. When a trigger schema exists, Callboard validates field names, operand types, and operators against it. Without a schema, runtime comparison still checks the actual Variant type. Rule overlap analysis remains conservative for compound expressions: it may report a possible overlap when it cannot prove the formulas exclusive. Renaming a Blackboard key updates references on either side of a comparison and inside grouped guards. Relays emitted by rules and `repeat_emit` forward the original authored payload.

Use the built-in `emit_relay(relay, field_map = {})` verb to dispatch a relay immediately at a chosen point in a rule's ordered steps. Pass the bare relay name. An empty mapping forwards a deep copy of the complete incoming payload. A non-empty mapping selects and optionally renames fields, with output field names as keys and input field names as values:

```gdscript
emit_relay(&"parcel_ready", {"item": "gift_id", "accepted": "approved"})
```

Missing input fields are omitted from the emitted payload. When input and output schemas are declared, authoring validation checks mapped field names and types; the runtime checks supplied values against the output schema before dispatch. The relay dispatch carries the current event ancestry, so recursive relay chains remain subject to the same depth and per-frame dispatch limits. The rule board draws the step as a relay emitter, and live step traces include its relay name and argument position.

### Waiting in a rule

```gdscript
wait_for_call(&"host_reply", &"payload.accepted == true", 3.0, &"reply_timeout")
wait_for_call(&"relay:prop_ready")
wait_until(&"completed_count >= 3", 5.0, &"setup_timeout")
```

`wait_for_call(event, payload_guard = &"", timeout = 0.0, timeout_relay = &"")` observes future events on the same Stage. Use the full `relay:` ID when waiting for a relay. The optional guard checks the incoming event's payload. The event still dispatches to its ordinary listeners, and the waiting rule resumes afterward with its original payload. Events that arrived before the wait was armed are discarded. For a host acknowledgment, declare the reply Call and have the host send it with `Stage.fire()` after the wait is armed. A host replying to a preceding `gameplay_event` step in the same rule can defer its reply to let the wait arm first.

`wait_until(condition, timeout = 0.0, timeout_relay = &"")` checks the guard immediately with the current Blackboard and the rule's original payload. If the guard fails, the step rechecks on each committed Blackboard change.

For both steps, zero waits indefinitely. The first match or timeout wins. Success continues the sequence. Timeout ends the sequence and suppresses the rule's completion relay. If supplied, the bare timeout relay name dispatches with the original payload and event ancestry, so another rule can handle recovery. Restart, Cancel If, and Stage deactivation release the subscriptions and stop the interrupted sequence. The live debugger shows pending waits and traces matches, timeouts, and cancellations.

### Runtime step inputs

To read the current rule's payload or Blackboard at step execution time, use a typed reference in an argument expression:

```gdscript
add_var(&"coins", callboard_payload(&"reward"))
say(guide, callboard_payload(&"message"))
gameplay_event(&"reward_claimed", {"amount": callboard_payload(&"reward")})
set_var(&"next_target", callboard_blackboard(&"selected_target"))
```

`callboard_payload(key)` reads the field from this rule run's incoming payload; `callboard_blackboard(key)` reads the current declared Blackboard value when the step starts. The Callboard argument picker offers the compatible fields declared for the trigger and typed Blackboard keys. It also offers dynamic values inside host request dictionaries and relay field maps. The references can be nested in arrays and dictionaries.

The reference type comes from the payload schema or Blackboard declaration. Known mismatches are rejected while building or analyzing the Stage; integer values may feed float arguments. Within host request dictionaries and relay maps, references can be nested in arrays or dictionaries. If a payload field is absent at runtime, or a value does not match its declared or destination type, Callboard warns and skips only that step. This lets the rest of the rule sequence continue. Without a payload schema, the destination argument type is checked against the actual runtime value. Existing arguments that use constants, Stage props, or verb-factory expressions continue to be evaluated when the Stage builds.

### Blackboard change triggers

Use the reserved trigger ID `on_change` to run a rule after a declared Blackboard value commits a different value. Its payload contains `key` (String), `previous`, `value`, `scope` (String), and `writer` (String). `previous` and `value` retain the Blackboard key's declared Variant type, so numeric, Boolean, String, and other supported values can be compared or consumed by a step. For example, add `payload.key == "garage_open"` to Requires to filter a listener to one key, then inspect `context["payload"]["previous"]` and `context["payload"]["value"]` in a custom step.

Local, Saved, Shared, and Session writes all use the same trigger. Shared transitions are delivered in store commit order to every loaded Stage that declares the shared storage key. The writer label follows the commit. Initialization defaults and restored values do not fire `on_change`; unchanged or rejected writes do not fire it either. A managed dormant Stage receives shared state updates but does not replay change events on activation. Its next committed change is delivered normally. Feedback from a rule's `set_var` or `add_var` step carries the active event ancestry into `on_change`, so the existing 64-event depth and per-frame dispatch limits stop recursive chains. Use specific key guards and re-entry policies to avoid unintended feedback.

Step callables receive authored fields at the top level for compatibility and also under `context["payload"]`. Callboard metadata is grouped under `context["_callboard"]` (`rule` and `run`); reserve `payload` and `_callboard` as field names. Queued runs retain and recheck their own payload. Cancel If always reads the payload of the active run.

| Signal | When it fires |
| --- | --- |
| `rule_fired(rule_id: StringName, event: StringName)` | A rule starts, or `fire_relay_once()` reports the supplied source. |
| `var_changed(key: StringName, value: Variant)` | An accepted write that changes the stored Blackboard value. The key uses its current name. |
| `scored(points: int)` | A scoring step emits a score delta. The game owns the total. |
| `gameplay_event(event_id: StringName, arguments: Dictionary)` | A `gameplay_event` step asks host code to apply a project-specific action. |
| `gameplay_request(request_id: int, event_id: StringName, arguments: Dictionary)` | A `gameplay_request` step asks the host to act and includes the correlation ID to return with its acknowledgment. |
| `gameplay_request_finished(request_id: int, event_id: StringName, outcome: StringName, data: Dictionary)` | Reports `accepted`, `rejected`, `timed_out`, or cancellation/dispatch outcomes. Accepted/rejected data includes `request_id`, `accepted`, and declared response fields. |
| `dispatch_blocked(action: String, reason: String)` | A Call, relay, or gameplay event was blocked because the Stage is unbuilt, its graph is invalid, or it is dormant. The action identifies the rejected entry point; the reason gives the applicable lifecycle or graph error. |

Connect to `stage.gameplay_event` after loading the Stage. The addon emits the authored ID and a deep copy of the arguments; it does not interpret them. `Stage.scored` and the `score(points)` verb remain available for score deltas.

### Correlated host requests

`gameplay_event()` remains one-way. Use `gameplay_request()` when a rule must wait for a host response:

```gdscript
var request_step := verbs.gameplay_request(
    &"check_access",
    {"card_id": &"blue_key"},
    3.0,
    {&"remaining_uses": TYPE_INT},
    &"access_check_timed_out"
)

func _on_gameplay_request(request_id: int, event_id: StringName,
		arguments: Dictionary) -> void:
	if event_id == &"check_access":
		var allowed := inventory.has(arguments["card_id"])
		stage.respond_gameplay_request(request_id, allowed,
			{&"remaining_uses": inventory.remaining_uses(arguments["card_id"])})
```

Connect to `gameplay_request` before starting rules. The wait is registered before the request signal is emitted, so a host can acknowledge synchronously. A zero timeout waits indefinitely; a positive timeout emits the step's optional timeout relay and ends the current rule run. Rule cancellation and Stage deactivation cancel the pending request. `gameplay_request_finished` fires before the waiting rule resumes, so a host listener can update Blackboard values for following steps.

The final optional `request_id` argument is `0` for an automatically allocated ID or a positive host-supplied ID. IDs are unique within that live Stage instance and are never reusable. The host must respond on the same Stage instance. Duplicate, late, and unknown responses return false and do not fire the completion signal.

`response_schema` maps response field names to Godot Variant type constants such as `TYPE_INT`, `TYPE_BOOL`, or `TYPE_STRING`. A nonempty schema rejects undeclared fields and incompatible values; omitted fields are allowed, and integer values widen to float fields. An empty schema accepts dynamic response values. Response fields `request_id` and `accepted` are reserved. An invalid response is rejected without settling the request, allowing the host to correct it before timeout. Completion outcomes are `accepted` or `rejected`; the `data` dictionary contains those reserved fields alongside the validated response fields. Timeout and cancellation outcomes carry an empty data dictionary.

### Input and camera control

Create one [`StageControlAdapter`](../core/stage_control_adapter.gd) in your host and assign it to `stage.control_adapter` before the Stage starts rules. Share the adapter between Stages that control the same players or camera rigs. Connect to `state_changed` and read the current state for the channels your host handles.

```gdscript
var controls := StageControlAdapter.new()

func bind_stage_controls(stage: Stage) -> void:
    stage.control_adapter = controls

func _ready() -> void:
    controls.state_changed.connect(_apply_controls)
    _apply_controls()

func _apply_controls() -> void:
    player.cutscene_input_locked = controls.is_input_locked(&"gameplay")
    camera_rig.set_callboard_shot(controls.camera_request(&"main"))
    camera_rig.set_callboard_shake(controls.shake_request(&"main"))
```

Implement the player flag and camera rig methods in your host. Combine the flag with the host's other input restrictions, and check it wherever gameplay input enters, including touch and interaction. Keep the rig's normal shot as its baseline. A `null` shot request restores that baseline and a `null` shake request clears the shake layer. Treat requests as read-only and only restart a blend or shake when its effective request changes. Stop or replace any tween or animation from the previous request as ownership changes.

The typed `StageControlAdapter.CameraRequest` has a `kind` and these fields:

| Kind | Fields |
| --- | --- |
| `FOCUS` | `target: Node3D` and `blend_seconds: float`. A freed target reads as `null`. |
| `FRAME` | `shot: StringName`, a host-defined framing preset, and `blend_seconds: float`. |
| `SHAKE` | `strength: float` in host-defined units and `frequency: float` in Hz. |

One rule run owns at most one input lock per channel, one focus or framing request per camera channel, and one shake request per camera channel. An input channel stays locked until every owner has released it. For each camera layer, the most recent owner takes effect. Releasing it restores the next live request or returns that layer to the host. Parallel branches share their parent run's ownership. Use a wait or delay to hold an effect, and a release step to end it early. Remaining requests clear automatically on completion, a timeout that ends the run, Restart, Cancel If, Stage deactivation, or teardown.

### Stage hooks

| Override | Purpose |
| --- | --- |
| `_build_props() -> void` | Create or bind props before rule steps are compiled. |
| `_build_blackboard() -> void` | Define or initialize script-owned keys after authored defaults are applied. |
| `_declare_external_writers() -> void` | Call `register_external_writer()` for outputs provided by Stage gameplay code. Runs after authored keys are applied and before graph validation. |
| `_restore_state() -> void` | Restore custom scene state after the graph is built and before declarative restoration bindings run. |
| `_make_verbs(context: StepContext) -> CoreVerbs` | Return the verb factory. The default is `StagingVerbs.new(context)`. Put game-specific effects and Blackboard key defaults in a Stage-specific subclass. |

Use `@tool` on the Stage script and custom verb factory so Callboard can analyze them in the editor. Initialize typed prop references in the scene or in `_build_props()` before the editor or runtime compiles steps.

Callboard opens StageDefinitions and processes ordinary graph edits with resource-only checks. These checks do not instantiate the Stage, run project setup, invoke custom verb factories, or evaluate authored step expressions. The **Analyze Scene** button runs the scene-backed checks explicitly; saving also runs them before writing. Scene analysis may instantiate the preview scene and run script initialization, tree callbacks, `_build_props()`, `_build_blackboard()`, `_declare_external_writers()`, `_make_verbs()`, and authored argument expressions. Keep `@tool` callbacks and these hooks safe to run in the editor: avoid starting gameplay, changing project files, or creating persistent external state. Prefer idempotent setup and release temporary resources when the preview is freed. Custom verb signatures and scene-assigned props become available after scene analysis.

## StageDefinition

[`StageDefinition`](../core/stage_definition.gd) is the resource assigned to `Stage.definition`. The editor saves variables, rules, steps, and groups as typed subresources. Older dictionary-based definitions migrate to the current format and retain their persisted state keys.

| Field | Purpose |
| --- | --- |
| `stage_script` | The `@tool` script extending `Stage`. |
| `preview_scene_path` | Optional scene path for editor analysis of scene-assigned props. Callboard otherwise looks for a same-name sibling `.tscn`, then falls back to constructing the script. |
| `managed_lifecycle` | Opts the Stage into dormant loading, activation on entry, and Call filtering while dormant. |
| `cross_stage_instance_ids` | Runtime Stage IDs that may identify instances of this definition. Declare IDs here to let the Callboard validate targeted cross-Stage events before those Stages load. |
| `restoration_bindings` | `StageRestorationBinding` resources that restore scene state, including visuals, transforms, typed properties, lights, audio, and continuous particles before activation. |
| `external_calls` | Events supplied by gameplay. Use bare IDs for Calls and `relay:<name>` IDs for external relays. Include `arrive` when using that lifecycle trigger. |
| `call_positions` | Saved graph positions keyed by external event ID. |
| `external_vars` | Declared Blackboard keys that gameplay writes. This tells validation which values have a writer outside the graph. |
| `external_writers` | `BlackboardWriterData` resources describing key, source label, and output type for typed gameplay producers. These declarations satisfy guard producer checks and are checked against the Blackboard schema. |
| `variables`, `rules`, `groups` | Authored subresources. Rule steps are stored with the rule. |

Use the generated `.tscn` when loading a Stage that relies on scene-assigned nodes. `StageDefinition.instantiate()` creates a Stage from its script and assigns the definition.

For cross-Stage authoring checks, list each host-assigned target ID in the destination definition's `cross_stage_instance_ids` field in the Inspector. The Callboard scans StageDefinitions in the configured stage folders. It checks targeted IDs against those declarations, checks that recipients declare or listen for the event, and compares literal or typed runtime payload fields with each recipient schema. Broadcasts are checked against all configured definitions that receive the event. Runtime IDs or payloads that cannot be resolved statically still receive the store's runtime checks.

Step arguments and delays are evaluated at graph compilation using Godot's [Expression](https://docs.godotengine.org/en/stable/classes/class_expression.html). Use project-authored data. The expressions can call methods and reference typed props and script constants. The event payload is available to the step callable when the rule runs.

## Blackboard

[`Blackboard`](../core/blackboard.gd) is accessible as `stage.bb`. Gameplay can use the Stage wrappers above. Verb factories receive the same Blackboard through `StepContext.bb`.

| Method | Behavior |
| --- | --- |
| `define(key, scope, default, state_key = &"")` | Uses the default value's Variant type as the schema. Scope is `&"local"`, `&"saved"`, `&"shared"`, or `&"session"`. |
| `get_var(key)`, `write(key, value, writer = &"") -> bool` | Read or write a declared value. A write returns true when a changed value is accepted; false when it is unchanged or rejected. Writes to undeclared keys produce an error. Integer writes to float keys are converted. Other type mismatches warn and discard the write. Saved or session values with an outdated type revert to the declared default during setup. |
| `has(key)`, `is_set(key)` | Test whether a key is declared or whether its value is truthy. |
| `alias(old_key, new_key)`, `resolve_key(key)` | Support renamed keys. Callboard records aliases when it renames authored variables. |

For named actor states, declare a `StringName` Blackboard key with a non-empty default such as `&"idle"`. That default is the initial state when no stored value exists. Use Saved scope when state should survive Stage reloads, Session scope for a host-defined session, Shared scope for multiple loaded Stages, or Local scope for a state that resets on rebuild. `set_state(key, &"active")` writes through the same typed path as other Blackboard changes; restoration comes from the declared scope and regular Stage restoration bindings. `idle`, `active`, and `resolved` are conventions, not a fixed enum. Guards and `on_change` rules can observe transitions. The addon does not impose a transition graph or own actor behavior.

The `changed(key, value)` signal is forwarded as `Stage.var_changed`. `value_changed(key, previous, value, scope, writer, dispatch_context)` is the richer commit signal used for authored `on_change` rules. It fires after the value changes and carries the previous committed value, scope, writer label, and any rule event ancestry. Use the write methods when gameplay changes a value so validation and notifications apply. Declare external producers through `external_vars` or typed `external_writers`; `on_change` listeners filtered to a key are checked against the Blackboard schema and declared writers. `BlackboardWriter` is a scene component with an exported `callboard_writers` list and a `publish(key, value)` method; the Stage collects its declarations during editor analysis and runtime setup. Custom scene nodes may expose the same property. The live Blackboard shows the most recent non-empty writer label for each key.

## StageStateStore

[`StageStateStore`](../core/stage_state_store.gd) is a Resource that owns per-instance `saved` and `fired` dictionaries, a shared Blackboard dictionary, and runtime-only session values. Use a distinct, stable ID for each loaded plot, even when two plots use the same scene.

```gdscript
var store := StageStateStore.new()
var left_yard := store.load_stage(yard_scene, &"house_01_left", self)
var right_yard := store.load_stage(yard_scene, &"house_01_right", self)

# Managed Stages have finished restoring but remain dormant here.
left_yard.activate()

store.unload_stage(left_yard)
store.unload_stage(right_yard)
```

`load_stage()` injects state before adding the Stage to the tree. `unload_stage()` deactivates it and retains its dictionaries for the next load. `&"session"` Blackboard variables retain values across Stage reloads for as long as this store instance remains alive. Call `store.reset_session()` at the host's session boundary to restore declared session keys to their defaults and clear values for currently undeclared keys. This notifies loaded Blackboards and can trigger `on_change` rules for changed values. Session values are not exported or included in durable profile saves. Use `&"saved"` for progression that must survive a session reset; one-shot latches remain in each Stage instance's `fired` dictionary and are unaffected by the reset. Save the Resource or serialize `stage_states` and `shared_values` with Variant-preserving storage to persist across game restarts. Shared Blackboard keys should use the same `state_key` and Variant type in every Stage. Conflicting declarations appear in Stage diagnostics, and incompatible shared writes are rejected. Direct `saved_vars` and `fired` dictionary injection remains supported for existing managers.

### Asynchronous loading and prewarming

Call these methods on the main thread with a live parent or SceneTree.

| API | Behavior |
| --- | --- |
| `await store.load_stage_async(scene_path, instance_id, parent) -> Stage` | Loads the resource, then instantiates and attaches on a later frame. A managed Stage is dormant on return. Connect host listeners and then call `activate()`. Failures log a diagnostic and return `null`. |
| `store.cancel_stage_load(instance_id) -> bool` | Cancels a pending mount and immediately releases its ID for reuse. The cancelled await returns `null` once the loader reaches its next cancellation check. A native read already underway is collected when it finishes. |
| `await store.prewarm_stage_scene(scene_path, tree) -> PackedScene` | Reads only the resource. Keep the returned scene in a host variable for later `load_stage()` calls. Release that reference when the scene leaves your preload window. |
| `stage_load_profiled(instance_id, resource_usec, instantiate_usec, attach_usec)` | Fires after a successful async mount. Resource time includes elapsed waiting for the native loader. Instantiation and attachment are measured independently on the main thread. Attachment includes the Stage's build and restoration callbacks. |

Each pending load reserves its ID within the store. A pending or loaded ID rejects duplicate requests. Distinct IDs can load the same path. If the parent is gone, outside its original tree, or queued for deletion when the load resumes, the await returns `null`.

Web exports use the same awaitable API with **Thread Support** disabled. Resource reads happen on the main thread after a frame boundary, with scene instantiation and attachment scheduled for a later frame. A large read, instantiation, or restoration can still stall a frame. Prewarm during a loading screen or before the player reaches the Stage. For presets that export selected scenes or resources, explicitly include Stage scenes referenced only by path.

`broadcast_event(event_id, arguments = {}, target_instance_id = &"") -> int` sends a live event to one loaded Stage ID or broadcasts to every eligible loaded Stage when the target is empty. It returns the number of recipients that accepted the event. Targets must currently be loaded, built, and able to accept Calls; managed dormant Stages are skipped. Broadcast recipients are processed in ascending instance-ID order. A Stage must declare the event in `external_calls` or listen for it in a rule. When a recipient has a payload schema for the event, supplied fields must be declared and match their types; omitted fields are allowed and integer values are converted for float fields. A recipient without a schema accepts the supplied dictionary as-is. Targeted unknown events, unknown targets, and invalid payloads are rejected with a warning.

Delivery is synchronous and live-only: dormant and unloaded Stages are skipped without buffering; no events are replayed or persisted. Repeated sends are each delivered once per eligible recipient; there is no deduplication. A broadcast includes its source Stage if that Stage is active, loaded, and listens for the event. The store caps cross-Stage recipient dispatches at 256 per process frame. Each destination uses its normal RuleEngine per-frame budget and event-depth ancestry. `emit_cross_stage()` records a `cross_stage_sent` row in the source Stage trace, and recipients record the ordinary `event_fired` trace.

## Declarative restoration

Add `StageRestorationBinding` resources to a StageDefinition. `VISIBILITY` maps a saved/shared/session Boolean to `visible` on a `CanvasItem` or `Node3D` (including lights). `TRANSFORM` applies a saved/shared/session `Transform3D` to a `Node3D`. `SNAP_TO_MARKER` uses a saved/shared/session Boolean to snap a `Node3D` to a `Marker3D`; optionally set both the AnimationPlayer path and animation name to seek and pause at a resolved pose. `POSE_ANIMATION` uses a saved/shared/session Boolean key as a gate, with `target_path` set to an `AnimationPlayer`; when true, it seeks and pauses the configured clip without moving the target. `CHILD_INDEX` uses an integer key to select one entry from `child_choices`; paths are relative to the Stage root, must point beneath `target_path`, and the selected child is made visible while the other listed choices are hidden. `PROPERTY` copies a Blackboard value to `property_name` on the target. It requires a writable property with a compatible declared type; integer values can be converted to float properties. `LIGHT_ENERGY` and `LIGHT_COLOR` restore numeric energy and `Color` on a `Light3D`. `AUDIO_PLAYBACK` uses a Boolean to stop or restore playback on an `AudioStreamPlayer`, `AudioStreamPlayer2D`, or `AudioStreamPlayer3D`; restoration always stops existing playback, and true does not replay audio by default. Set `replay_audio_on_restore` only for stateful audio such as a loop, and provide a stream. `PARTICLE_EMITTING` uses a Boolean to stop or restart continuous `GPUParticles3D` or `CPUParticles3D`; one-shot emitters are rejected so transient bursts are not replayed during loading. Callboard analysis validates key scope and type, node paths, property/resource compatibility, marker type, and animation reference. Bindings run after `_restore_state()` and before activation.

## TriggerArea

[`TriggerArea`](../core/trigger_area.gd) extends `Area3D`. Place it under a Stage, add a `CollisionShape3D`, and set `event` and optional `ctx`. It locates the closest Stage ancestor.

- **ENTER** dispatches when a body in a configured `trigger_groups` group enters. The default remains `Player` and `Companion`, preserving existing scenes. Set `trigger_groups` to an empty array to accept bodies from any group; use it for movable props, projectiles, vehicles, or other host-defined groups. Collision masks still apply independently. Each contact Call receives `payload.body` with the body's name, current scene path, instance ID, and groups; the Node itself is not included, so the payload does not retain a scene object.
- In `ENTER` mode, set `exit_event` to dispatch a separate Call when a matching body leaves. Exit Calls are sent only for bodies whose entry occurred while the Stage accepted Calls. Dormant or invalid Stages do not queue or replay contact Calls; an exit that occurs while dormant is suppressed and clears that contact. The metadata describes the body at signal time and its instance ID is only valid for the current runtime session.
- **INTERACT** is selected by an [`InteractionResolver`](../core/interaction_resolver.gd) from the actor's overlapping trigger areas. Configure the resolver with the actor and its reach area, then call `resolver.interact(context)` from the input handler or UI.

`TriggerArea` defaults to collision layer `TRIGGER` and mask `PLAYER | COMPANION`, preserving the addon's previous runtime behavior. These defaults are set before scene data is applied, so authored `collision_layer` and `collision_mask` values remain in effect. Set `collision_mask_override` to a nonnegative mask to replace the authored mask at runtime; `-1` means no override, and `0` intentionally disables all collision-mask matches. The override does not change the collision layer. Use [`StageCollisionLayers`](../core/collision_layers.gd) for the standard bit masks, or call `stage.fire()` directly from your own interaction system.

Interactable triggers expose `prompt_text`, optional `prompt_icon`, and `interaction_priority`. Set `prompt_translation_key` to resolve the prompt through `TranslationServer`; `prompt_fallback_text` is used when that key has no translation, and `prompt_substitutions` fills named placeholders such as `{item}`. Literal `prompt_text` remains the default when no key is authored. A dynamic prompt provider can return `text: String`, or `translation_key` with optional `fallback` and `substitutions` for a localized host-dependent prompt. The resolver chooses the eligible trigger with the highest priority, then the shortest distance from the actor, then the lexicographically first node path. It polls while the actor remains in range, so Blackboard or host state can update availability and prompt values without an area exit/re-entry. `set_interaction_enabled(false)` emits a state-change signal that refreshes connected resolvers immediately.

```gdscript
var resolver := InteractionResolver.new()
add_child(resolver)
resolver.configure(actor, reach_area, func(interacting_actor: Node) -> Dictionary:
    return {"held_item": inventory.held_item_id(interacting_actor)}
)
resolver.prompt_changed.connect(_show_prompt) # (text, icon, priority)
resolver.selected_trigger_changed.connect(_refresh_selection)

# Callbacks can read live context and captured Blackboard state.
trigger.set_eligibility_hook(func(interacting_actor: Node, context: Dictionary) -> bool:
    return context.get("held_item") == &"permit" and stage.get_var(&"permit_stamped")
)
trigger.set_prompt_provider(func(interacting_actor: Node, context: Dictionary) -> Dictionary:
    return {"translation_key": &"PROMPT_USE_ITEM", "fallback": "Use {item}",
        "substitutions": {"item": context.get("held_item", "")}, "icon": trigger.prompt_icon}
)
trigger.set_interaction_handler(func(interacting_actor: Node, context: Dictionary) -> Dictionary:
    inventory.erase("permit")
    return {"accepted": true, "payload": {"accepted": true, "item": "permit"}}
)
var result: Dictionary = resolver.interact({"source": "door_ui"})
trigger.set_interaction_enabled(false) # immediately updates the in-range prompt
```

`InteractionResolver.configure(actor, reach_area, context_provider)` accepts an optional Callable that receives the actor and returns a Dictionary. You can also call `set_context_provider()` later. The returned context is reevaluated during each resolver refresh and is passed to eligibility and prompt callbacks; explicit context passed to `refresh()` or `interact()` overrides provider fields. A one-argument `set_eligibility_hook(actor)` remains supported; the two-argument form receives `(actor, context)`. The eligibility hook controls whether a trigger is offered. Override `is_interaction_eligible(actor)` for reusable actor-only eligibility. `set_prompt_provider()` receives `(actor, context)` and returns a Dictionary with optional `text: String`, `translation_key`, `fallback`, `substitutions`, and `icon: Texture2D` fields; a literal `text` takes precedence, otherwise a supplied key is localized. Omitted fields use the authored prompt defaults. The prompt signal carries the resolved text, icon, and priority; read `resolver.selected_trigger` when the subscriber needs the trigger itself. `selected_trigger_changed` has no arguments and fires when selection changes.

Use `set_interaction_enabled(false)` to remove a target while it remains overlapped. The resolver subscribes to trigger state changes and immediately selects the next eligible target or clears the prompt. Blackboard- and inventory-backed eligibility can also change between frames; the resolver's normal refresh polling picks up those updates. Callbacks should be side-effect free because prompt and eligibility callbacks can be evaluated repeatedly.

Interaction handlers receive a deep copy of trigger `ctx`, overlaid with the resolver context provider's values and then the explicit context passed by the caller. `set_interaction_handler()` or an override of `handle_interaction(actor, context)` returns `{accepted: bool, payload: Dictionary}`. Accepted results dispatch the trigger's `event`; rejected results dispatch `rejected_event` if configured. The returned result dictionary includes `accepted`, dispatched `event`, and `payload`. `interaction_completed(actor, result)` on the trigger and `interaction_completed(trigger, result)` on the resolver report the result. Inventory checks, item consumption, and other game policy stay in the host handler.

### DeliveryTarget

`DeliveryTarget` is an optional `TriggerArea` subtype for item handoffs. It does not own an inventory. The host supplies three synchronous callbacks: a held-item provider, an atomic consume-if-still-held callback, and an optional return-to-inventory callback. The consume callback must verify and remove the exact item in one operation; it is called only after the target accepts the item ID and has capacity. This makes a wrong item, a missing item, a full target, or a stale inventory snapshot leave the item unconsumed.

Set `accepted_item_ids` to restrict accepted IDs; an empty list accepts any nonempty held item. `capacity = -1` allows unlimited deliveries, `0` disables the target, and a positive value limits the runtime `delivered_count`. A full target stops being eligible. Rejected attempts return a `reason` such as `wrong_item`, `no_item_held`, or `item_changed` and dispatch `rejected_event` when configured. Accepted payloads contain `item_id`, a runtime-only `delivery_id`, `delivered_count`, and `capacity`.

```gdscript
target.set_inventory_adapter(
    func(actor: Node) -> StringName: return inventory.held_item_id(actor),
    func(actor: Node, item_id: StringName) -> bool:
        return inventory.consume_if_held(actor, item_id),
    func(actor: Node, item_id: StringName) -> bool:
        return inventory.try_add(actor, item_id)
)
```

If later host work rolls back a delivery, call `return_delivery(delivery_id, actor)`. It releases capacity only when the return callback succeeds; the host can retry after making room in the inventory. Delivery IDs and capacity counters belong to the live target instance. Persist progression in Saved Blackboard variables, update the saved count after accepts and returns, and restore `delivered_count` with a typed property restoration binding when needed. Rules that need inventory state declare a Boolean Blackboard key such as `has_access_card` and have host code update it when inventory changes; there is no built-in `has_item()` guard or inventory model.

## Built-in verbs

The default factory is [`StagingVerbs`](../core/staging_verbs.gd), which inherits [`CoreVerbs`](../core/core_verbs.gd). Each method returns a `Step`. Optional arguments are shown with their defaults.

`CallboardLocalization.resolve(key, substitutions = {}, fallback = "")` is also available to host code. It asks `TranslationServer` for an explicit key and locale, uses the fallback when the key has no translation, then formats named placeholders such as `{item}`. Authored `say()` strings and literal prompt text are not translated implicitly.

| Factory | Verb | Effect |
| --- | --- | --- |
| Core | `set_var(key, value = true)` | Write a Blackboard value. |
| Core | `add_var(key, delta)` | Add a positive or negative numeric delta to an `int` or `float` Blackboard value when the step executes. Integer keys require a whole-number delta. |
| Core | `toggle_var(key)` | Invert a declared Boolean Blackboard value when the step executes. Other key types are rejected by validation and skipped with a warning at runtime. |
| Core | `reset_var(key)` | Write a declared key's authored default when the step executes. It supports any default whose Variant type matches the declaration. |
| Core | `score(points)` | Emit a score delta. |
| Core | `emit_cross_stage(event_id, arguments = {}, target_instance_id = &"")` | Send a typed live event through the StageStateStore. An empty target broadcasts to active loaded Stages that declare or listen for the event. Runtime payload references are supported inside `arguments`. |
| Core | `set_state(key, state)` | Write a non-empty named state into a declared `StringName` Blackboard key. The key's scope controls initial and restoration behavior. |
| Core | `repeat_emit(interval, tick = &"")` | Repeat at the interval until cancelled. If `tick` is supplied, emit `relay:<tick>` each interval; omit it for a relay-free ambient lifetime loop. |
| Staging | `show_node(n, should_be_visible = true)` | Set a `Node3D`'s visibility. |
| Staging | `light(n, on, duration = 0.0, key = &"")` | Set visibility immediately. A positive duration turns it off at timeout, rule cancellation, or Stage deactivation. The optional key mirrors the Boolean state and must be declared as a Boolean Blackboard value. |
| Staging | `set_light_color(light, color)`, `set_light_energy(light, energy)` | Set a `Light3D` color or a finite, nonnegative energy value. |
| Staging | `flicker_light(light, low_energy, high_energy, interval = 0.06, duration = 0.6)` | Alternate light energy for a bounded duration, then restore its original energy. The rule wait releases on completion or cancellation. |
| Staging | `restart_particles(particles)` | Restart CPU or GPU particle emitters in 2D or 3D. |
| Staging | `stop_audio(player)`, `set_audio_pitch(player, pitch_scale)`, `set_audio_bus(player, bus)` | Stop playback (releasing any wait for that playback), set positive pitch, or route to an existing AudioServer bus. |
| Staging | `set_shader_parameter(material, parameter, value)` | Set a declared `ShaderMaterial` uniform after checking its name and value type. |
| Staging | `spawn(scene, parent, owner = null, initial_transform = null)` | Instantiate a `PackedScene` under a parent. A non-null owner must be the parent or one of its ancestors; `initial_transform` is an optional local `Transform2D` or `Transform3D` matching the scene root. Null owner leaves the runtime instance unowned. |
| Staging | `despawn(n, expected_owner, destroy = true, keep_global_transform = true)` | Require the node's current owner to match `expected_owner` (pass null for an unowned runtime node), then queue it for deletion or detach it. Detaching can preserve its world transform and clears scene owners that are no longer ancestors. |
| Staging | `reparent(n, new_parent, expected_owner, new_owner, keep_global_transform = true)` | Require an expected current owner and an explicit new owner (null clears ownership), reject cycles, and optionally preserve Node2D/Node3D world transforms. |
| Staging | `pop(n)`, `bounce(n)` | Play a scale animation. |
| Staging | `say(n, text, seconds = 1.0)` | Show temporary text at a node. |
| Staging | `say_key(n, key, substitutions = {}, seconds = 1.0, fallback = "")` | Resolve a translation key when the rule runs, apply named substitutions, and use the fallback when no translation exists. |
| Staging | `move_to(n, dest, offset = Vector3.ZERO, duration = 0.7, transition = Tween.TRANS_LINEAR, ease = Tween.EASE_IN_OUT)` | Tween a node to a target with an offset. Duration zero snaps immediately; otherwise the rule waits for completion. |
| Staging | `snap_to_marker(n, marker, animation_player = null, animation_name = &"", animation_time = 0.0)` | Immediately copy a Marker3D world transform; optionally seek and pause an animation at a resolved pose. |
| Staging | `follow_path(n, path, duration = 1.0, orient_to_path = false, wait_for_completion = true, transition = Tween.TRANS_LINEAR, ease = Tween.EASE_IN_OUT)` | Follow the baked Curve3D of a Path3D by distance, optionally matching its orientation. |
| Staging | `tween_property(target, property, value, duration = 0.25, wait_for_completion = true, transition = Tween.TRANS_LINEAR, ease = Tween.EASE_IN_OUT)` | Tween a writable property when the current and destination values use compatible interpolatable types, including numeric, vector, transform, and color values. |
| Staging | `play_audio(player, wait_for_completion = false, timeout = 0.0)` | Play an `AudioStreamPlayer`, `AudioStreamPlayer2D`, or `AudioStreamPlayer3D`. Waiting holds the rule for this playback instance. A positive timeout releases the wait and cancels the run. |
| Staging | `rotate_to(n, target_rotation, duration = 0.25, wait_for_completion = true, transition = Tween.TRANS_LINEAR, ease = Tween.EASE_IN_OUT)` | Rotate a `Node3D` to Euler angles in radians. Set duration to zero for an immediate change or disable waiting to let the tween continue in the background. |
| Staging | `play_animation(player, animation, wait_for_completion = true, timeout = 0.0, custom_blend = -1.0, custom_speed = 1.0)` | Play a named `AnimationPlayer` clip with optional custom blend and speed. Waiting checks the completed clip name and the Callboard playback token. A positive timeout releases the wait and cancels the run. |
| Staging | `set_animation_speed(player, speed_scale)` | Set a finite, positive `AnimationPlayer.speed_scale` without changing its current clip. |
| Staging | `pose_animation(player, animation, time = 0.0)` | Seek to a time in a named clip and pause there. |
| Staging | `gameplay_event(event_id, arguments = {})` | Emit `Stage.gameplay_event` for host-owned behavior such as doors, quests, or inventory. |
| Staging | `gameplay_request(event_id, arguments = {}, timeout = 0.0, response_schema = {}, timeout_relay = &"", request_id = 0)` | Emit a correlated host request and wait for an accepted or rejected acknowledgment. Timeout ends the run and can fire a recovery relay; cancellation releases the request. |
| Staging | `lock_input(channel = &"gameplay")`, `release_input(channel = &"gameplay")` | Acquire or release this run's lock on a host input channel. |
| Staging | `camera_focus(target, blend_seconds = 0.0, channel = &"main")` | Request focus on a Stage `Node3D` prop. |
| Staging | `camera_frame(shot, blend_seconds = 0.0, channel = &"main")` | Request a named framing preset from the host camera rig. |
| Staging | `camera_shake(strength, frequency = 12.0, channel = &"main")` | Request shake on a separate layer from the shot. |
| Staging | `release_camera(channel = &"main")` | Release this run's shot and shake for the camera channel. |
| Staging | `flash(m)`, `jump(m)` | Tint compatible `BaseMaterial3D` overrides or mesh surfaces. Materials are duplicated for the target instance; `jump` still performs its hop when no tintable material exists. |

`set_state`, `toggle_var`, and `reset_var` write through `Blackboard.write()`. Local values remain Stage-local; Saved values update the Stage save dictionary; Shared values use the store's ordered, type-checked commit; Session values live in the StageStateStore's runtime-only session dictionary. Changed values emit the normal change notifications and record the running rule as writer. Rejected and unchanged writes retain the existing Blackboard behavior.

When `move_to` and `jump` overlap on the same node, the latest step controls its position. Earlier steps finish on their original schedule so their rules can continue.

`light` writes the supplied key only when it is non-empty. A timed turn-on writes `true`, then writes `false` when it turns off. A newer activation owns the node, so an older timeout cannot turn off a newer light state. The editor reports missing targets, missing/non-Boolean light keys, absent audio streams, and missing animation clips before Stage activation.

The wait options on `play_audio`, `rotate_to`, and `play_animation` are explicit. Audio and animation waits check completion against the playback started by the step, so a different clip or replacement audio instance cannot satisfy the wait. A later built-in playback on the same node supersedes the earlier wait and cancels that run. Stopping playback, removing its target from the SceneTree, or setting **Cancel If** also cancels the waiting run. A looping clip or stream waits until it is stopped or superseded; set a positive timeout to bound the wait. A timeout of `0.0` disables the timeout. Stage deactivation or Restart releases a run-owned wait. Non-waiting tween/audio/animation actions continue according to their Godot node's lifetime and process mode.

### Built-in cancellation behavior

The engine checks **Cancel If** before the first step and after each step or delay. **Restart** replaces an active run at its next cancellation check. A cancelled run skips its remaining steps and completion relay. One-shot latches record the start and stay set after cancellation.

| Verb | Effect after cancellation |
| --- | --- |
| `set_var`, `set_state`, `add_var`, `score`, `show_node` | Completed writes, score changes, and visibility changes stay applied. |
| `repeat_emit` | Checks before each tick and stops emitting when cancelled. Restart releases the timer wait on the next process frame; deactivation releases it immediately. |
| `pop`, `bounce`, `move_to`, waiting `rotate_to` | The tween finishes while the Stage remains in the tree. Restart releases the rule's wait on the next process frame; deactivation releases it immediately. The tween continues. |
| `flash`, `jump` | The tint restores the target instance's base colors and the hop returns to its base height. Restart releases the rule's wait on the next process frame; deactivation releases it immediately. The visual effect continues. |
| Waiting `play_audio`, `play_animation` | The rule waits for its playback instance to finish. Stop, target removal, timeout, **Cancel If**, Restart, replacement by a later built-in playback, or Stage deactivation cancels the wait and skips remaining steps. Run cancellation releases the wait on the next process frame; deactivation releases it immediately. |
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
- Runtime-created rules can use `Step.parallel([[step_a, step_b], [step_c]], true)` to run child sequences concurrently and join before the parent continues. Each branch's steps run sequentially in the order supplied; all branches start in array order. `join` defaults to `true`, so outcomes propagate by waiting for every branch. With `join = false`, the parent continues immediately while the branches remain owned by that rule run. Restart, **Cancel If**, and Stage deactivation cancel every branch and skip its remaining steps. Branch start, completion, and cancellation are included in the live trace with branch details.
- `StepData` serializes nested parallel groups through `parallel_branches` and `join_parallel`, and the Rule Inspector can create, remove, reorder, and edit branch steps. Use “Wait for every branch” to select joined or unjoined behavior.
- Conditional groups use `Step.conditional(conditions, branches, default_index)`. Conditions are evaluated in authored order with the incoming payload and Blackboard; the first true guard runs, or the explicit default branch runs if none match. The selected branch runs sequentially, then the parent continues. The Rule Inspector edits each guard and the Otherwise branch; the board tooltip lists paths, and the live trace records the selected branch. Guards use the existing `GuardExpression` grammar.
- Random groups use `Step.random_choice(branches, weights, seed, group_id, selection)`. Selection `0` is uniform; selection `1` uses relative non-negative weights, where zero disables a branch. The authored seed initializes a group's stream, and changing the seed starts a new stream. Give each authored group a stable ID so branch or step reordering preserves its stream. Managed Stages store each group's PRNG state alongside saved stage state and resume it after reload; the live trace records the chosen branch and mode.
- `CoreVerbs.branch_if(conditions, branches, default_branch_index = -1)` and `CoreVerbs.choose_random(branches, weights = PackedFloat32Array(), seed_value = 1, stable_group_id = &"", selection = 0)` expose those same groups when building runtime rules in script. Branches are arrays of ordered `Step` sequences; `branch_if` uses the first matching guard and the supplied default index, while `choose_random` keeps the seeded selection stream under the stable group ID. Both return ordinary group `Step`s, so Restart, **Cancel If**, and Stage teardown cancel their selected branch and remaining steps through the same run ownership rules.
- For a custom step that awaits internally, capture `engine.token()` on entry and check `engine.alive(context["_callboard"]["rule"], token)` after each await before applying more effects. Wrap a signal with `engine.interruptible(signal)` to resume the wait on deactivation, then perform the same cancellation check. Resolve the engine through `context.engine_ref` and release the strong reference before awaiting. See [`repeat_emit`](../core/core_verbs.gd) for the pattern.

[`StepContext`](../core/step_context.gd) supplies `bb`, the Stage `host`, a weak `engine_ref`, and the `score` callable. Engine run metadata is isolated under the step context's `_callboard` key.

## RuleEngine

[`RuleEngine`](../core/rule_engine.gd) is exposed as `stage.engine` after setup. Use it for custom asynchronous verbs, diagnostics, or tests with a deterministic clock. The constructor accepts a Blackboard, a latch dictionary, and a wait callable of the form `func(seconds: float) -> Signal`.

| API | Purpose |
| --- | --- |
| `token()`, `alive(rule, token)` | Check whether a run can continue after asynchronous work. |
| `fire_from_context(event, payload, context)` | Fire from a saved `_callboard.run.context` to preserve the event chain when a host callback resumes after a yield. Synchronous public `fire()` calls made during event and rule-start callbacks inherit the active chain. |
| `interruptible(source, completion_if = Callable(), cancel_on = [], run = {}, defer_cancel = false)` | Return a signal that completes when the source passes the optional predicate, any supplied cancellation signal emits, or the engine deactivates. `defer_cancel` coalesces same-frame Restart triggers before the replacement run begins. The caller checks cancellation before continuing its work. |
| `wait_tracked(seconds, rule_id, label)` | Use the configured clock and surface the wait in the live debugger. Returns the wait signal. |
| `track_signal(signal_to_track, rule_id, label, seconds = -1.0)` | Show a pending operation until its signal fires. A negative duration means the remaining time is unknown. |
| `active_snapshot()`, `pending_snapshot()` | Read active rules and queued counts, or pending waits and their remaining times. |
| `trace_event(entry)` | Observe lifecycle events. Entries include `time_ms`, `kind`, `rule`, `event`, `step`, `verb`, and `detail`. Rule starts and rejections also include authored `order` and `trigger_rule_count`; rejection records include reason, guard observations, one-shot latch state, and re-entry policy. `reentry_decision` records Ignore, Restart, Queue, or a dropped full-queue attempt. |
| `pending_changed(entries)`, `run_cancelled(rule_id)`, `all_cancelled` | Observe wait changes and cancellation. |
| `dispatch_limit_reached(limit, event_chain, rule_id)` | Observe recursion, per-frame work, or pending-queue limits. The engine also reports the limit with the event chain. |

The engine stops event ancestry deeper than 64, caps pending work per rule at 128, and allows 256 rule dispatches per engine per process frame. Excess queue entries are dropped; later triggers may still be accepted after the queue drains. The limit signal and error include the event chain to help locate cycles.

The rule engine dispatches matching rules in authored order. A rule's steps run in order and await their completion when applicable. A rule's own relay fires after its final step completes. Different rules can overlap. The re-entry policy governs repeated triggers of the same rule. Per-trigger routing defaults to multi-match; an optional First Match policy dispatches the first eligible rule, with an optional designated fallback evaluated only when all other listeners fail. These policies and the authored rule order are saved with `StageDefinition`, separately from node positions. The live DEBUG trace explains failed required, forbidden, and initial Cancel If guards with the observed Blackboard or payload values; it also shows one-shot latch state, policy decisions, and each rule's order among listeners for the Call.

In the live **Calls & relays** panel, **Test payload** appears for Calls with declared payload fields. Each editor matches the declared Boolean, integer, float, or String type. Uncheck a field to omit it from the test Call.

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
