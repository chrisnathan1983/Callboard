## Working checklist

- Test each change with the relevant tests; add or update focused tests when behavior changes.
- Update the README and any directly affected documentation when behavior, setup, or commands change.
- Keep TODO status current, and mark work complete only after verifying it.

## Suggested implementation order

1. Start with the playback/wait and Shared write fixes in §1. Fix latch/dispatch behavior and editor/runtime type agreement before adding features that rely on those paths.
2. Implement change triggers, immediate relay emission, and typed runtime inputs, then cancellable waits, parallel groups, branches/random selection, and the expanded guard grammar. Design trigger syntax, validator metadata, and cancellation semantics alongside the engine changes.
3. Build the cross-Stage bus, extended restoration, and Session scope on the corrected runtime. Then add generic contact and item integration, named actor states, and dynamic prompts.
4. Expand staging and camera/input controls, and add the corresponding board authoring and live diagnostics. Follow with templates, cross-Stage validation, reachability analysis, and the scenario harness. The package and leak checks can proceed independently of the new features.


## 1. Runtime correctness and authoring safety

The first five items retain the high priority assigned in `TODO.md`.

- [x] **Give playback and waits per-run ownership.** See [StagingVerbs](addons/callboard/core/staging_verbs.gd), [RuleEngine](addons/callboard/core/rule_engine.gd), and [CoreVerbs](addons/callboard/core/core_verbs.gd).
  - [x] Stage deactivation releases registered interruptible waits. Delays and `repeat_emit` use the engine's injected clock. Restart cancels the active run and starts only the latest same-frame replacement after the cancellation wakeup; unit tests cover replacement and repeat behavior.
  - [x] Match completion to the requested playback instance. `play_animation` checks the emitted animation name and a per-player playback ticket; `play_audio` captures and checks its `AudioStreamPlayback` instance. A later built-in playback supersedes the earlier wait, including replay of the same animation. Runtime unit tests pass for name filtering and replacement cancellation.
  - [x] Wait until Godot has created the audio playback object before requesting it, and recheck player/run ownership after the frame boundary.
  - [x] Define and test all playback exit cases:
    - [x] Replacement, including replay of the same clip, cancels the earlier wait; Restart and Stage deactivation release run-owned waits.
    - [x] Stop and target removal cancel the waiting run and prevent its remaining steps.
    - [x] Looping playback waits until stopped, superseded, or cancelled; an optional positive timeout cancels the wait. A zero timeout means no timeout.
    - [x] `Cancel If` releases playback waits and prevents the cancelled run from continuing.
  - [x] Make `interruptible()` accept supported signal arities and clean up source connections and pending diagnostics on completion, cancellation, and deactivation. Regression tests cover two-argument signals and cleanup.
  - [x] Preserve non-blocking visual effects after successful rule completion, while preventing a cancelled or superseded run from resuming its remaining steps. Unit tests cover Restart, timed-light ownership, and replacement cancellation.

- [x] **Make Shared Blackboard writes atomic and ordered.** See [Blackboard](addons/callboard/core/blackboard.gd) and [StageStateStore](addons/callboard/core/stage_state_store.gd).
  - [x] A store supplies shared state across loaded Stages, validates writes against their declared types, and exposes writer attribution and change notifications.
  - [x] Commit each shared write once in the store and deliver notifications in commit order, including listener-triggered writes.
  - [x] Test nested writes from source and receiving Stages, unchanged values, rejected types, consistent notification order, and final writer attribution.

- [x] **Emit a one-shot relay only after committing its latch.** See [`Stage.fire_relay_once()`](addons/callboard/core/stage.gd) and [`Blackboard.write()`](addons/callboard/core/blackboard.gd).
  - [x] The helper checks for an eligible Stage, a relay ID, a declared Boolean latch, and an unset latch value.
  - [x] Return an actionable write result through the Stage and Blackboard APIs. Emit the relay and `rule_fired`, and return success, only after a successful latch commit.
  - [x] Cover repeated calls following a rejected Shared write and re-entry from a listener during a successful latch commit.

- [x] **Apply lifecycle and graph-validity checks consistently at public dispatch entry points.** See [Stage](addons/callboard/core/stage.gd), [StageDefinition](addons/callboard/core/stage_definition.gd), and the [API reference](addons/callboard/docs/api.md).
  - [x] `activate()` blocks graph compilation errors, and managed Stages reject Calls while dormant. The compiler keeps inert placeholders for invalid steps to preserve editor metadata indices.
  - [x] Define the dispatch policy: callers must build first; valid unmanaged Stages accept direct Calls without `activate()`, while invalid graphs and dormant managed Stages block all dispatch entry points.
  - [x] Report blocked Calls and relays through `dispatch_blocked` and debug diagnostics. Test a partially compiled graph with valid and invalid steps, an unbuilt Stage, a valid unmanaged Stage, and a dormant managed Stage.

- [x] **Bound recursive dispatch and queued work.** See [RuleEngine](addons/callboard/core/rule_engine.gd) and [CoreVerbs](addons/callboard/core/core_verbs.gd).
  - [x] The engine limits completion-relay recursion to 64 levels and supports Ignore, Restart, and Queue re-entry.
  - [x] Preserve event ancestry through synchronous nested public `fire()` calls, relay steps, and queued work. `fire_from_context()` carries ancestry into callbacks that resume after a yield.
  - [x] Cap each rule's pending queue at 128 and dispatch work at 256 rules per engine per process frame. Excess queue entries are dropped, and diagnostics report the event chain.
  - [x] Cover cycles through host callbacks and rules, including cycles that yield, and verify ordinary queued triggers still recheck guards and retain their payloads.

- [x] **Check initial cancellation before consuming a one-shot rule.** See [RuleEngine](addons/callboard/core/rule_engine.gd).
  - [x] Existing tests cover the start-latch policy for runs cancelled after they start.
  - [x] Evaluate `Cancel If` against the incoming payload before dispatch and again at `_run()` entry, so a rejected one-shot does not set its latch, emit `rule_fired`, trace a start, or run a step. A regression confirms a later payload can pass and consume the latch.
  - [x] Keep the explicit start-latch policy: once an eligible run starts, interruption does not clear its one-shot latch. No completion-latch/retry mode is added; authors needing retry behavior should use a non-one-shot rule and explicit state guards.

- [x] **Align type rules across compilation, validation, and runtime.** See [RuleValidator](addons/callboard/core/rule_validator.gd), [GuardExpression](addons/callboard/core/guard_expression.gd), and [Blackboard](addons/callboard/core/blackboard.gd).
  - [x] Typed payload fields, payload presence checks, typed Blackboard writes with integer-to-float widening, and numeric `add_var` validation already exist.
  - [x] Validate static `set_var` target and value types. Match runtime writes, including the permitted integer-to-float widening; mismatched literal writes are reported before dispatch.
  - [x] Align payload schema behavior: a missing event schema permits dynamic values checked at runtime, while a declared event schema rejects undeclared fields and enforces declared types.
  - [x] Compare integer/integer operands exactly for payload and Blackboard guards. Preserve approximate equality for float/float and mixed int/float comparisons, and test numeric ordering and equality behavior.

- [x] **Make editor validation safe to run while editing.** See [RuleGraphReader](addons/callboard/model/rule_graph_reader.gd), [Stage](addons/callboard/core/stage.gd), and [StageDefinition](addons/callboard/core/stage_definition.gd).
  - [x] Analysis has opt-in preview-prop reuse via `can_reuse_analysis_props()` and can resolve scene-assigned props.
  - [x] Separate resource-only checks from scene-backed checks. Opening a definition, ordinary edits, undo/redo, and relay renames use resource checks without instantiating a Stage or evaluating authored expressions. **Analyze Scene** and **Save** run scene-backed compilation.
  - [x] Make scene-backed checks explicit and document preview behavior. The API reference lists script initialization, tree callbacks, Stage hooks, verb factories, and authored expressions that may execute. Editor smoke tests verify opening and editing do not instantiate the preview or rerun Stage setup; explicit analysis resolves scene props.

- [x] **Restore original colors after overlapping mesh effects.** See [`StagingVerbs.flash()`](addons/callboard/core/staging_verbs.gd).
  - [x] The effect isolates materials and uses the latest tween's ownership while allowing earlier tweens to finish and release waiting rules.
  - [x] Cache the untinted base color on each isolated material. A regression overlaps two flashes across a multi-surface mesh with distinct base colors and verifies a sibling mesh using the same source resource remains unchanged.

## 2. Rule language and control flow

- [x] **Trigger rules on Blackboard changes.** See [Stage](addons/callboard/core/stage.gd) and [RuleEngine](addons/callboard/core/rule_engine.gd).
  - [x] `Blackboard.changed` and `Stage.var_changed` notify host code. Shared notifications can reach other loaded Stages.
  - [x] Add the reserved `on_change` trigger with a typed payload envelope (`key`, `previous`, `value`, `scope`, `writer`); transition values retain their Blackboard Variant type. Local, Saved, and Shared commits notify listeners; initialization/restoration, no-op writes, rejected writes, and dormant managed Stages do not dispatch.
  - [x] Validate filtered listeners against declared Blackboard keys and known writers. Carry rule ancestry through `set_var`, `add_var`, and shared commits so recursive change chains use the existing depth and per-frame dispatch limits. Document the payload and lifecycle policy in the API reference.

- [x] **Add immediate `emit_relay` with payload forwarding and field mapping.** See [CoreVerbs](addons/callboard/core/core_verbs.gd), [Step](addons/callboard/core/step.gd), and [RuleValidator](addons/callboard/core/rule_validator.gd).
  - [x] Completion relays and `repeat_emit` forward the incoming payload. `Step.emits` and `emit_arg` already carry step-level relay metadata.
  - [x] Emit once at a chosen point in a sequence; forward the full incoming payload or select and remap fields. Validate mapped schemas and runtime output types, expose the emitter and argument in board connections and traces, include it in cycle analysis, and carry dispatch ancestry into the new relay.

- [x] **Support typed runtime step inputs from the Call payload and Blackboard.** See [StageDefinition](addons/callboard/core/stage_definition.gd), [RuntimeInputRef](addons/callboard/core/runtime_input_ref.gd), and [RuleInspector](addons/callboard/editor/rule_inspector.gd).
  - [x] Authored payload schemas drive guard checks. Custom step callbacks receive the runtime payload, and `add_var` reads the current key value before applying its authored delta.
  - [x] Add `callboard_payload()` and `callboard_blackboard()` typed references resolved for each step run. Existing constant, prop, and verb-factory arguments remain build-time expressions. Missing values and runtime type mismatches warn and skip the affected step while later steps continue.
  - [x] Support dynamic values for `set_var`, `add_var`, `say`, scoring, relay field maps, and host request dictionaries. The inspector offers compatible declared payload and Blackboard sources and known schema mismatches are rejected during Stage build.

- [x] **Add cancellable `wait_for_call` and `wait_until` steps with timeouts.** See [RuleEngine](addons/callboard/core/rule_engine.gd) and [Step](addons/callboard/core/step.gd).
  - [x] `.after()` delays and verb-specific waits already exist, with an injected timer for engine tests.
  - [x] Wait for a future Call or relay with an optional payload guard, or for a Blackboard condition. An already-true condition completes immediately. Matching Calls and relays still dispatch normally before the waiting sequence resumes.
  - [x] Success continues the sequence. Timeout ends it and can emit a recovery relay. Restart, Cancel If, and deactivation release the wait. Injected-clock tests cover first-result ordering, Restart, Stage deactivation, and a filtered host acknowledgment.

- [x] **Add sequential and parallel step groups.** See [`RuleEngine._run()`](addons/callboard/core/rule_engine.gd).
  - [x] The engine awaits a rule's steps in order. Independent rules can already overlap, and some verbs support non-blocking playback.
  - [x] Add the runtime `Step.parallel()` group with ordered child sequences and an optional join. Joined groups wait for every branch; unjoined groups let the parent continue while the branches remain owned by its run. Restart, **Cancel If**, and Stage teardown cancel branch work; branch lifecycle is traced.
  - [x] Serialize nested `StepData` branches recursively with join mode, and compile authored groups into runtime `Step.parallel()` steps.
  - [x] Add Rule Inspector authoring for nested branches, including branch add/remove/reorder and per-branch step editing. Branch start, completion, and cancellation events include branch details in the live trace.

- [x] **Add conditional branches and deterministic random choices inside a rule.** See [RuleData](addons/callboard/core/rule_data.gd), [StepData](addons/callboard/core/step_data.gd), and [RuleValidator](addons/callboard/core/rule_validator.gd).
  - [x] Separate rules can route by guards, with overlap diagnostics and an explicit allowance for intentional overlap.
  - [x] Add conditional step groups with first-match guards and one explicit Otherwise branch. Execute only the selected branch, preserve nested steps in resources, and allow branch reorder and guard-key renames.
  - [x] Add uniform and weighted random selection with an authored seed and restorable per-group RNG state across managed Stage reloads.
  - [x] Validate conditional guards, default paths, and supported operand types. Show branch conditions in board tooltips and selected outcomes in the live trace.
  - [x] Expose `CoreVerbs.branch_if()` and `CoreVerbs.choose_random()` as script-facing entry points backed by `Step.conditional()` and `Step.random_choice()`. Preserve branch order, cancellation, and seeded selection. Cover conditional dialogue responses and repeatable selection across a pool of eight idle animations.

- [x] **Expand guard expressions.** See [GuardExpression](addons/callboard/core/guard_expression.gd) and [RuleValidator](addons/callboard/core/rule_validator.gd).
  - [x] Existing guards support Blackboard truthiness and numeric comparisons with literals, plus typed payload comparisons and `has()`/`missing()` checks.
  - [x] Add OR and grouping to the guard parser with `any(sensor_active, override_enabled)`, `and`/`or` operators, and parentheses.
  - [x] Support key-to-key comparisons such as `completed_count >= required_count`, resolving both keys through the Blackboard schema and applying the operand type rules from §1.
  - [x] Support `String` and `StringName` Blackboard equality and inequality for named states, such as `operating_mode == "standby"`. Blackboard storage already accepts string defaults.
  - [x] Keep parsing, type checking, rename/reference tracking, overlap analysis, and the guard editor in sync. Use the numeric and unknown-type rules from §1. Compound formulas remain conservative in overlap analysis when exclusivity cannot be proved.

- [x] **Add typed `toggle_var` and `reset_var`.** See [CoreVerbs](addons/callboard/core/core_verbs.gd) and [Blackboard](addons/callboard/core/blackboard.gd).
  - [x] `set_var` and `add_var` handle declared keys; the Blackboard schema retains their declared defaults.
  - [x] Toggle Boolean keys and reset supported keys to their declared defaults through the normal write API. Local, Saved, and Shared writes retain scope-specific persistence, notifications, and writer attribution. Session scope is tracked in §3; these verbs will continue to use the same write path when it is added. The editor restricts toggle targets to Boolean keys and validation rejects invalid keys and defaults.

## 3. State, restoration, and Stage lifecycle

- [x] **Expose Shared key identity and enforce early store attachment.** See [BlackboardPanel](addons/callboard/editor/blackboard_panel.gd), [StageStateStore](addons/callboard/core/stage_state_store.gd), and [Stage](addons/callboard/core/stage.gd).
  - [x] Shared variables use a storage key. `load_stage()` attaches the store before adding the Stage to the scene tree.
  - [x] Expose existing Shared identities in a picker and allow a custom storage key for reuse across definitions. Keep display names separate; changing scope preserves `state_key`, and existing data is remapped only after an explicit storage-key edit. Legacy variables without `state_key` continue to use their display key.
  - [x] Reject attachment once a Stage has initialized its Blackboard or engine. `attach_state_store()` and `StageStateStore.attach()` return `false` without changing the Stage's references after initialization.

- [x] **Add a store-level cross-Stage event bus.** See [StageStateStore](addons/callboard/core/stage_state_store.gd) and [Stage](addons/callboard/core/stage.gd).
  - [x] The store maintains stable Stage instance IDs and shares values. Managed Stages can load dormant and ignore ordinary Calls until activation.
  - [x] Add `StageStateStore.broadcast_event()` for typed, live delivery to one or more active, loaded Stage instances. Tests cover a targeted `sensor:activated` event and a broadcast `system_overload` event.
  - [x] Add `CoreVerbs.emit_cross_stage()` so authored rules can send the same events with constants or typed runtime payload references.
  - [x] Define live-only delivery: skip dormant/unloaded recipients, preserve stable instance-ID order, include an eligible source Stage, deliver repeated sends without deduplication, and never queue, replay, or persist messages.
  - [x] Validate the loaded target, event declaration/listener, and each recipient's declared payload fields and types at delivery. Cross-Stage sends consume a per-frame store budget, preserve the RuleEngine ancestry/depth budget, and appear in source and recipient traces.
  - [x] Add authoring-time validation across unloaded Stage definitions. `cross_stage_instance_ids` on each StageDefinition declares host-assigned IDs; the Callboard scans configured stage folders, checks event recipients, and type-checks literal and typed runtime payload fields. Dynamic IDs retain runtime validation and receive a diagnostic when no registered target can be found.

- [x] **Add Session scope and reset rules.** See [Blackboard](addons/callboard/core/blackboard.gd), [StageStateStore](addons/callboard/core/stage_state_store.gd), and [BlackboardPanel](addons/callboard/editor/blackboard_panel.gd).
  - [x] Local, Saved, and Shared scopes exist. Store-backed Saved values and latches persist by Stage instance ID.
  - [x] Use `&"session"` as the scope identifier for per-session Blackboard variables such as `ambient_level` and `sequence_reversed`. Expose `reset_session()` as the host hook to restore those variables to their declared defaults at a session boundary.
  - [x] Define host-controlled session start/reset, session counters and flags across Stage reloads, and how session state interacts with durable profile progression and one-shot latches. Make scope, reset rules, and serialization behavior explicit in the UI and API.

- [x] **Extend declarative restoration.** See [StageRestorationBinding](addons/callboard/core/stage_restoration_binding.gd) and [Stage](addons/callboard/core/stage.gd).
  - [x] Saved/Shared keys can restore visibility, a local `Transform3D`, or a marker's global transform. Marker restoration can optionally seek and pause an `AnimationPlayer` at a resolved pose. Bindings run after `_restore_state()` and before activation, with runtime and validation coverage.
  - [x] Add standalone animation pose binding. A saved/shared/session Boolean key gates a resolved `AnimationPlayer` pose without requiring a marker or moving its target; the binding validates the key and clip and restores after `_restore_state()`.
  - [x] Add typed variant bindings for integer child selection and a generic type-checked property binding. Child choices are explicit Stage-relative paths; property bindings require a writable property compatible with the Blackboard key type.
  - [x] Add light energy and color bindings, Boolean audio playback bindings for AudioStreamPlayer, AudioStreamPlayer2D, and AudioStreamPlayer3D, and continuous particle-emitting bindings. Audio playback is stopped by default during restoration; explicit replay is available for stateful audio. One-shot particle systems are rejected.
  - [x] Validate key scope and type, target compatibility, and required audio streams; preserve binding settings through serialization. Restoration rebuilds continuous state and avoids replaying transient audio or particle cues by default.

- [x] **Support asynchronous Stage loading and prewarming.** See [`StageStateStore`](addons/callboard/core/stage_state_store.gd).
  - [x] Add path-based loading and prewarming. Native builds use threaded resource loading. Single-threaded Web builds yield before reading the resource on the main thread. Scene instantiation and attachment run on the main thread.
  - [x] Reserve stable IDs for pending requests, release them on cancellation or failure, and return successfully attached Stages dormant for host-controlled activation. Report resource load, instantiation, and attachment timings separately.

## 4. Interactions, host integration, and staging

- [x] **Make contact triggers game-agnostic.** See [TriggerArea](addons/callboard/core/trigger_area.gd).
  - [x] `TriggerArea` supports Enter and Interact. Interactions already expose host eligibility/handling hooks, accepted and rejected Calls, and payloads.
  - [x] Expose `TriggerArea.trigger_groups` for optional filtering by Godot body group. Cover matching and nonmatching bodies, including movable props, projectiles, and vehicles. Preserve the existing `Player` and `Companion` defaults; an empty list accepts any body group.
  - [x] Honor scene-configured collision layers and masks, and expose `collision_mask_override`. Keep `TRIGGER` and `PLAYER | COMPANION` as defaults; `-1` preserves the scene mask, while any nonnegative override replaces it (including `0`).
  - [x] Support arbitrary body/prop contacts and an optional `exit_event`. Include body name, current path, runtime instance ID, and groups in `payload.body` without retaining the Node. Filter both entry and exit by `trigger_groups`; only send paired exit Calls when entry occurred while the Stage accepted Calls, and do not queue dormant entry/exit events.

- [x] **Provide a generic item interaction and delivery contract.** The existing addon delegates inventory policy to the host; the optional adapter provides reusable delivery outcomes without introducing inventory storage.
  - [x] `TriggerArea` provides `set_eligibility_hook()`, `set_interaction_handler()`, override points, and accepted/rejected outcome payloads. [InteractionResolver](addons/callboard/core/interaction_resolver.gd) selects one eligible target.
  - [x] Add `DeliveryTarget` with accepted item IDs, host-provided held-item/consume/return callbacks, capacity, availability, and wrong-item outcomes. Consume only after eligibility and item checks, and require an atomic consume-if-still-held callback so rejected or repeated attempts cannot consume twice.
  - [x] Keep inventory storage out of the addon. Host code can mirror inventory facts into typed Boolean Blackboard keys for rule guards; there is no built-in `has_item()` guard. Delivery IDs are runtime-only; persist target progression through Saved Blackboard values and restoration bindings. Keep quests, dialogue, navigation, and project-specific item/objective policy in host code via custom verbs and `gameplay_event`.

- [x] **Add host request and acknowledgment.** See [`Stage.gameplay_request()`](addons/callboard/core/stage.gd) and [`StagingVerbs.gameplay_request()`](addons/callboard/core/staging_verbs.gd).
  - [x] An authored `gameplay_event` step emits an ID and a deep-copied argument dictionary. The current signal is a one-way request.
  - [x] Add correlated `gameplay_request` steps with optional host-provided IDs, typed response schemas, and accepted/rejected outcomes. Register the cancellable wait before emitting so synchronous replies are caught. Reject duplicate/late responses; expire pending requests on timeout, rule cancellation, Stage deactivation, or rebuild. Preserve one-way `gameplay_event` behavior.

- [x] **Support named actor states.** See [Blackboard](addons/callboard/core/blackboard.gd), [CoreVerbs](addons/callboard/core/core_verbs.gd), and [RuleValidator](addons/callboard/core/rule_validator.gd).
  - [x] Add `set_state(key, state)` for non-empty named values backed by a declared `StringName` Blackboard key with a non-empty StringName default. Validation rejects missing keys, wrong key types, and empty or incorrectly typed initial/transition states. Writes use normal scope persistence, change notifications, and writer attribution.
  - [x] Define initial and restoration semantics: the Blackboard default supplies initial state; Local resets on rebuild, Session lasts for the StageStateStore session, Saved restores across Stage reloads, and Shared state synchronizes loaded Stages. `idle`, `active`, and `resolved` are conventions; the addon does not enforce a transition graph.
  - [x] Make `repeat_emit(interval)` support a relay-free ambient lifetime loop. A tick relay is optional; when supplied it retains the existing listener validation and periodic dispatch behavior. Tracking, following, navigation, objective order, and session timers remain host-owned.

- [x] **Support dynamic prompts and interaction enablement.** See [TriggerArea](addons/callboard/core/trigger_area.gd) and [InteractionResolver](addons/callboard/core/interaction_resolver.gd).
  - [x] The resolver reevaluates eligibility, notices changes to the configured prompt on refresh, and resolves again before dispatch. Triggers expose prompt text, icon, and priority.
  - [x] Let authors derive prompt text/icon and availability from Blackboard state or host-provided context such as the held item. Keep one-argument eligibility callbacks compatible, and refresh the selected target and prompt immediately when `set_interaction_enabled` changes while the actor remains in range.

- [x] **Add cancellation-safe input and camera control.** See [StageControlAdapter](addons/callboard/core/stage_control_adapter.gd).
  - [x] Add `lock_input` and `release_input` with run-scoped ownership, overlapping locks, and automatic release. A shared host adapter coordinates Stages that control the same player or rig.
  - [x] Add typed camera focus, framing, and shake requests. Release restores the previous live request or returns control to the host. Cover explicit release, completion, timeout, Restart, Cancel If, and Stage teardown.

- [x] **Expand staging verbs.** See [StagingVerbs](addons/callboard/core/staging_verbs.gd).
  - [x] Built-ins cover visibility, timed light on/off, audio playback, translation, rotation, animation playback, and animation posing, alongside existing speech and mesh/prop effects.
  - [x] Add `snap_to_marker` for live rules, reusing transform behavior from declarative restoration. It copies the Marker3D's world transform and can optionally seek and pause an AnimationPlayer at a resolved pose; target, marker, clip, and time are validated.
  - [x] Add configurable Tween transition/ease settings to movement and rotation, with finite duration and enum validation.
  - [x] Add `follow_path` over a `Path3D`'s baked `Curve3D`, including optional path orientation, immediate zero-duration placement, and validated curve/options.
  - [x] Add a typed generic `tween_property` for compatible interpolatable values and writable property paths, with optional waiting and validated settings.
  - [x] Add `set_light_color` and `set_light_energy` for validated Light3D state.
  - [x] Add bounded `flicker_light`, restoring the original energy when complete and releasing rule waits safely on cancellation.
  - [x] Add `restart_particles` for CPU/GPU emitters in 2D/3D.
  - [x] Add `stop_audio`, `set_audio_pitch`, and `set_audio_bus`, including release of playback waits when stopped.
  - [x] Add typed `ShaderMaterial` uniform changes with name/type validation.
  - [x] Add custom blend/speed to `play_animation` and a `set_animation_speed` control.
  - [x] Add spawn, despawn, and reparent with explicit ownership and transform preservation options. Validate targets and parameters; these verbs do not block and need no wait cancellation handling.

- [x] **Support localization.** See [`StagingVerbs.say_key()`](addons/callboard/core/staging_verbs.gd), [CallboardLocalization](addons/callboard/core/callboard_localization.gd), and [TriggerArea](addons/callboard/core/trigger_area.gd).
  - [x] Add `say_key()` and `CallboardLocalization.resolve()` for explicit translation keys, named substitutions, and fallback text. Resolve speech when the rule runs; keep `say()` literal.
  - [x] Add authored and dynamic localized prompts to `TriggerArea`, with fallback and substitutions. Preserve literal `prompt_text` and existing literal prompt-provider values.
  - [x] Document host-supplied localization, speech, prompt configuration, and behavior in the API reference and README; add focused unit coverage.

## 5. Board authoring and diagnostics

- [x] **Explain why a rule did not run, and supply typed test payloads.** See [RuleEngine](addons/callboard/core/rule_engine.gd), [Callboard](addons/callboard/editor/callboard.gd), and [RuleInspector](addons/callboard/editor/rule_inspector.gd).
  - [x] Live traces cover fired events, starts, waits, steps, and cancellation. The inspector can edit payload field declarations.
  - [x] Report failed required, forbidden, and initial Cancel If guards with observed values, one-shot latch state, and Ignore/Restart/Queue decisions. Include authored rule order and rejection in the live trace when several rules share a trigger.
  - [x] Build a typed payload form from each Call's declared trigger schema for live testing. Permit individual fields to be omitted; preserve empty-payload testing for Calls without a declared schema.
  - [x] Run the unit and editor smoke suites with these additions and confirm the emitted trace metadata and payload-form interaction.

- [x] **Expose and edit same-trigger rule order.** See [RuleEngine](addons/callboard/core/rule_engine.gd) and [RuleInspector](addons/callboard/editor/rule_inspector.gd).
  - [x] Rules are evaluated in authored array order. A synchronous write from an earlier rule can affect a later guard. The inspector can already reorder steps within a rule.
  - [x] Show rule order by trigger, allow undoable reordering, and persist it independently of board layout. Add opt-in first-match and fallback routing for mutually exclusive outcomes while preserving existing multi-match dispatch by default.

- [x] **Edit restoration, external writers, and managed lifecycle on the board.** See [StageDefinition](addons/callboard/core/stage_definition.gd), [GraphDraft](addons/callboard/model/graph_draft.gd), [RuleGraphReader](addons/callboard/model/rule_graph_reader.gd), and [BlackboardPanel](addons/callboard/editor/blackboard_panel.gd).
  - [x] `managed_lifecycle` is reachable through the `StageDefinition` resource in Godot's Inspector. It already round-trips through the draft, as do restoration bindings and external writers. Scene-based `BlackboardWriter` declarations also feed validation.
  - [x] Add board controls for the lifecycle flag, typed writer declarations, and restoration bindings with key, target, marker, property, and animation pickers as applicable. Include standalone poses and the binding types from §3.
  - [x] Add type-preserving defaults for `Transform3D` and other supported types. The Blackboard panel parses serialized Variant values only when they retain the default original type; checks cover edits, undo snapshots, resource reload, and migration.

- [x] **Add parameterized rule templates.**
  - [x] Cover reusable interaction outcomes, repeating ambient behavior, conditional sequences, and objective completion. Define bindings for props, keys, Calls, relays, and payload fields.
  - [x] Give instantiated rules fresh rule IDs, latch identities, storage keys, and internal relay names by default; allow explicitly shared storage or latch identities. Validate missing and incompatible bindings, and preserve internal relay, variable, and nested group references when instantiating or duplicating.

- [ ] **Validate across Stages.** See [StageStateStore](addons/callboard/core/stage_state_store.gd) and [RuleValidator](addons/callboard/core/rule_validator.gd).
  - [x] The store checks Shared type conflicts among loaded boards. Per-Stage validation checks declared producers, listeners, cycles, and overlapping rules.
  - [ ] Scan authored Stage definitions, including unloaded Stages, for conflicting Shared types, Shared reads with no declared producer, and unresolved cross-Stage event targets and payload contracts. Reuse the resource-only validation path where possible and account for declared host writers.

- [ ] **Analyze objective reachability.**
  - [ ] Let authors declare completion conditions, then check whether plausible Call and state sequences can reach them. Flag one-shot paths that can be consumed before their prerequisites are met.
  - [ ] Report which paths depend on unknown host behavior or random branches. The existing per-key “nothing sets it” check and relay-cycle analysis provide inputs, while reachability needs to model order, state, and latches.

## 6. Testing, clean installs, and exports

- [ ] **Add a reusable scenario test harness.** See [addon unit tests](addons/callboard/tests/unit.gd) and [RuleEngine](addons/callboard/core/rule_engine.gd).
  - [x] Hand-written headless tests exercise Call sequences, typed payload routing, restoration, and re-entry. Engine delays and repeat loops can already use an injected clock.
  - [ ] Add a headless Call-sequence runner with payloads, Stage activation/teardown, state and outcome assertions, and rule/branch coverage. Add live debugger time fast-forward for waits driven by the test clock and document how external playback and host work are handled.

- [ ] **Make the developer test panel conditional and report errors accurately.** See [plugin registration](addons/callboard/plugin.gd) and [TestRunnerPanel](addons/callboard/editor/test_runner_panel.gd).
  - [x] A repository developer panel runs headless suites and captures output. The installable ZIP deliberately excludes addon test scripts.
  - [ ] Register the panel only when runnable suites exist, and list only available suites in partial checkouts. It currently registers unconditionally, including from the installed ZIP where its configured suites are absent.
  - [ ] Detect unexpected script/engine errors and test failures in both suite badges and aggregate results, even when the child exits with code 0. Keep deliberately asserted diagnostics distinguishable from failures and report teardown leaks.

- [ ] **Exercise the packaged addon in CI and diagnose teardown leaks.** See [CI workflow](.github/workflows/test.yml), [package script](.github/scripts/package_addon.py), [export filter](addons/callboard/editor/export_plugin.gd), and [editor smoke suite](addons/callboard/tests/editor_smoke.gd).
  - [x] CI targets Godot `4.7.2`, runs four suites before packaging, and checks runtime with authoring layers removed. Editor assertions cover the export filter, which removes tests from exports and strips authoring layers from release exports.
  - [ ] Build and install the actual ZIP in a blank addon-only fixture, enable the plugin, run a minimal Stage, and perform real debug and release exports. Check that expected assets are retained, developer tooling is available only with its suites, and the exported runtime starts.
  - [x] Diagnose and fix the editor smoke suite's rendering RID and ObjectDB leaks: attach temporary controls to the test SceneTree, explicitly free temporary widgets and invalid-step Node fixtures, and allow queued cleanup to finish before exit.
  - [ ] Exercise repeated editor/plugin setup and teardown, Stage unload, and pending-wait cancellation, and gate regressions with teardown log checks.
  - [ ] Re-enable package and release jobs after most TODO implementation work is complete by setting the GitHub Actions repository variable `CALLBOARD_PUBLISH_PACKAGES` to `true`. Until then, CI runs tests without building packages or publishing releases.
