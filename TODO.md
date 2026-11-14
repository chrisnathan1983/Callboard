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

- [ ] **Give playback and waits per-run ownership.** See [StagingVerbs](addons/callboard/core/staging_verbs.gd), [RuleEngine](addons/callboard/core/rule_engine.gd), and [CoreVerbs](addons/callboard/core/core_verbs.gd).
  - [x] Stage deactivation releases registered interruptible waits. Delays and `repeat_emit` use the engine's injected clock. Restart cancels the active run and starts only the latest same-frame replacement; unit tests cover replacement and repeat behavior.
  - [x] Match completion to the requested playback instance. `play_animation` checks the emitted animation name and a per-player playback ticket; `play_audio` captures and checks its `AudioStreamPlayback` instance. A later built-in playback supersedes the earlier wait, including replay of the same animation. Runtime unit tests pass for name filtering and replacement cancellation.
  - [ ] Define and test all playback exit cases:
    - [x] Replacement, including replay of the same clip, cancels the earlier wait; Restart and Stage deactivation release run-owned waits.
    - [ ] Stop and target removal must release the wait with defined behavior. Add tests for both audio and animation targets.
    - [ ] Define looping behavior and an optional timeout; add tests for a loop that never emits completion and for timeout cleanup.
    - [ ] Verify `Cancel If` releases playback waits and prevents the cancelled run from continuing.
  - [x] Make `interruptible()` accept supported signal arities and clean up source connections and pending diagnostics on completion, cancellation, and deactivation. Regression tests cover two-argument signals and cleanup.
  - [x] Preserve non-blocking visual effects after successful rule completion, while preventing a cancelled or superseded run from resuming its remaining steps. Unit tests cover Restart, timed-light ownership, and replacement cancellation.

- [ ] **Make Shared Blackboard writes atomic and ordered.** See [Blackboard](addons/callboard/core/blackboard.gd) and [StageStateStore](addons/callboard/core/stage_state_store.gd).
  - [x] A store supplies shared state across loaded Stages, validates writes against their declared types, and exposes writer attribution and change notifications.
  - [ ] Commit each write once in the store and deliver notifications in commit order, including listener-triggered writes. Currently `Blackboard.write()` updates the shared dictionary and emits the local change before `_on_shared_changed()` writes the value again. A prior probe committed `1`, wrote `2` from a listener, and then saw the older `1` overwrite `2`.
  - [ ] Test nested writes from source and receiving Stages, unchanged values, rejected types, consistent notification order, and final writer attribution. Use this ordering for Blackboard-triggered rules in §2.

- [ ] **Emit a one-shot relay only after committing its latch.** See [`Stage.fire_relay_once()`](addons/callboard/core/stage.gd) and [`Blackboard.write()`](addons/callboard/core/blackboard.gd).
  - [x] The helper checks for an eligible Stage, a relay ID, a declared Boolean latch, and an unset latch value.
  - [ ] Return an actionable write result through the Stage and Blackboard APIs. Emit the relay and `rule_fired`, and return success, only after a successful latch commit. Today `write()` returns `void`, and a rejected write can still produce both signals.
  - [ ] Cover repeated calls following a rejected Shared write and re-entry from a listener during a successful latch commit.

- [ ] **Apply lifecycle and graph-validity checks consistently at public dispatch entry points.** See [Stage](addons/callboard/core/stage.gd), [StageDefinition](addons/callboard/core/stage_definition.gd), and the [API reference](addons/callboard/docs/api.md).
  - [x] `activate()` blocks graph compilation errors, and managed Stages reject Calls while dormant. The compiler keeps inert placeholders for invalid steps to preserve editor metadata indices.
  - [ ] Decide how to migrate the current direct-Call behavior on unmanaged Stages. The API lists compilation errors as an activation blocker and separately documents dormant filtering for `fire()`. Define one initialization and graph-validity policy for Calls, external relay helpers, and other public dispatch paths, including calls before `build()`.
  - [ ] Report the blocked Call or relay and the relevant rule or compile diagnostic. Test a partially compiled graph with a valid step beside an invalid step, an unbuilt Stage, a valid unmanaged Stage, and a dormant managed Stage.

- [ ] **Bound recursive dispatch and queued work.** See [RuleEngine](addons/callboard/core/rule_engine.gd) and [CoreVerbs](addons/callboard/core/core_verbs.gd).
  - [x] The engine limits completion-relay recursion to 64 levels and supports Ignore, Restart, and Queue re-entry.
  - [ ] Preserve event ancestry through nested public `fire()` calls, relay steps, and queued work. Public `fire()` currently resets depth, and the prior bounded probe ran 1,000 mutually queued dispatches in a single call.
  - [ ] Cap pending queue size and dispatch work per frame. Define overflow and deferral behavior, preserve ordering for accepted work, and show the event chain when a limit is reached.
  - [ ] Cover cycles through host callbacks and rules, including cycles that yield, and verify ordinary queued triggers still recheck guards and retain their payloads.

- [ ] **Check initial cancellation before consuming a one-shot rule.** See [RuleEngine](addons/callboard/core/rule_engine.gd).
  - [x] Existing tests cover the start-latch policy for runs cancelled after they start.
  - [ ] Evaluate `Cancel If` against the incoming payload before setting the latch, emitting `rule_fired`, or tracing a start. `_run()` currently performs those actions before checking whether the run can continue.
  - [ ] Consider an explicit completion-latch policy for sequences that should be retryable after interruption. If added, define successful completion, re-entry, and persistence semantics.

- [ ] **Align type rules across compilation, validation, and runtime.** See [RuleValidator](addons/callboard/core/rule_validator.gd), [GuardExpression](addons/callboard/core/guard_expression.gd), and [Blackboard](addons/callboard/core/blackboard.gd).
  - [x] Typed payload fields, payload presence checks, typed Blackboard writes with integer-to-float widening, and numeric `add_var` validation already exist.
  - [ ] Catch incompatible `set_var` writes during validation. The existing write checks know which keys are declared. A String write to a Boolean key can pass authoring checks and be dropped at runtime.
  - [ ] Align declared, undeclared, and partially declared payload schema behavior. An undeclared schema currently produces an incompatible-literal/operator warning for comparisons that runtime can evaluate.
  - [ ] Compare integer operands exactly without converting them to floats. Both payload and Blackboard numeric comparisons currently share the approximate float path; the prior review found `1000001 == 1000000` could pass. Define and test float and mixed-number comparison semantics as well.

- [ ] **Make editor validation safe to run while editing.** See [RuleGraphReader](addons/callboard/model/rule_graph_reader.gd), [Stage](addons/callboard/core/stage.gd), and [StageDefinition](addons/callboard/core/stage_definition.gd).
  - [x] Analysis has opt-in preview-prop reuse via `can_reuse_analysis_props()` and can resolve scene-assigned props.
  - [ ] Separate resource-only checks from scene-backed checks. The analysis path can parent a preview in the editor tree, run Stage build hooks, and evaluate argument expressions and verb factories. Reuse reduces scene rebuilds but still recompiles the graph.
  - [ ] Make scene-backed checks explicit and document which `@tool` callbacks, Stage hooks, and step factories must be safe during preview. Verify ordinary static edits avoid executing project setup or custom expressions.

- [ ] **Restore original colors after overlapping mesh effects.** See [`StagingVerbs.flash()`](addons/callboard/core/staging_verbs.gd).
  - [x] The effect isolates materials and uses the latest tween's ownership while allowing earlier tweens to finish and release waiting rules.
  - [ ] Cache the untinted base color per isolated material or surface. The current cache stores one material ID/color pair per mesh, so another flash can capture an in-flight tint. Verify overlap on a multi-surface mesh with different base colors and keep unrelated instances unaffected.

## 2. Rule language and control flow

- [ ] **Trigger rules on Blackboard changes.** See [Stage](addons/callboard/core/stage.gd) and [RuleEngine](addons/callboard/core/rule_engine.gd).
  - [x] `Blackboard.changed` and `Stage.var_changed` notify host code. Shared notifications can reach other loaded Stages.
  - [ ] Add an authored change trigger such as `on_change` with a typed payload identifying the key and its committed value transition. Integrate local, saved, and shared writes, define initialization/restoration and dormant behavior, and validate writers and listeners. Route feedback loops through §1 dispatch limits.

- [ ] **Add immediate `emit_relay` with payload forwarding and field mapping.** See [CoreVerbs](addons/callboard/core/core_verbs.gd), [Step](addons/callboard/core/step.gd), and [RuleValidator](addons/callboard/core/rule_validator.gd).
  - [x] Completion relays and `repeat_emit` forward the incoming payload. `Step.emits` and `emit_arg` already carry step-level relay metadata.
  - [ ] Emit once at a chosen point in a sequence, forward the incoming payload, and optionally select or remap fields. Validate mapped types and expose the emitter and its argument in board connections, cycle analysis, and traces. Carry dispatch ancestry into the new relay.

- [ ] **Support typed runtime step inputs from the Call payload and Blackboard.** See [StageDefinition](addons/callboard/core/stage_definition.gd) and [RuleInspector](addons/callboard/editor/rule_inspector.gd).
  - [x] Authored payload schemas drive guard checks. Custom step callbacks receive the runtime payload, and `add_var` reads the current key value before applying its authored delta.
  - [ ] Add explicit typed references resolved at step execution. Authored arguments now evaluate at Stage build time against props, constants, and the verb factory. Keep those existing arguments valid and define what happens when a runtime value is missing or has an incompatible type.
  - [ ] Let authors use dynamic values for `set_var`, `add_var`, `say`, scoring, relay mapping, and host request arguments. Expose compatible sources in the board and validate known input types.

- [ ] **Add cancellable `wait_for_call` and `wait_until` steps with timeouts.** See [RuleEngine](addons/callboard/core/rule_engine.gd) and [Step](addons/callboard/core/step.gd).
  - [x] `.after()` delays and verb-specific waits already exist, with an injected timer for engine tests.
  - [ ] Wait for a Call or relay, optionally matched by payload, or for a Blackboard/guard condition. Define whether an already-true condition completes immediately and how a matching event interacts with regular dispatch.
  - [ ] Expose success, timeout, and interruption to authored recovery paths. Dispose subscriptions and timers through §1's run-owned wait handling. Test simultaneous timeout and success, Restart, Stage deactivation, and receipt of a host acknowledgment.

- [ ] **Add sequential and parallel step groups.** See [`RuleEngine._run()`](addons/callboard/core/rule_engine.gd).
  - [x] The engine awaits a rule's steps in order. Independent rules can already overlap, and some verbs support non-blocking playback.
  - [ ] Add an authored `fork` or parallel group with an optional join. Specify child order, how outcomes propagate at a join, and ownership of unjoined work. Apply run cancellation and teardown to every branch and expose branch progress in diagnostics.

- [ ] **Add conditional branches and deterministic random choices inside a rule.** See [RuleData](addons/callboard/core/rule_data.gd), [StepData](addons/callboard/core/step_data.gd), and [RuleValidator](addons/callboard/core/rule_validator.gd).
  - [x] Separate rules can route by guards, with overlap diagnostics and an explicit allowance for intentional overlap.
  - [ ] Add per-step guards or branch groups, including a default path. Add uniform and weighted selection, with a seed and restorable random state when reproducibility across loads is required.
  - [ ] Validate branch conditions and weights, and make nested step groups and selected outcomes visible in the board and trace.

- [ ] **Expand guard expressions.** See [GuardExpression](addons/callboard/core/guard_expression.gd) and [RuleValidator](addons/callboard/core/rule_validator.gd).
  - [x] Existing guards support Blackboard truthiness and numeric comparisons with literals, plus typed payload comparisons and `has()`/`missing()` checks.
  - [ ] Add OR and grouping, key-to-key comparisons such as `completed_count >= required_count`, and String/StringName Blackboard comparisons for named states. Blackboard storage already accepts string defaults. The guard evaluator currently restricts Blackboard comparisons to numbers.
  - [ ] Keep parsing, type checking, rename/reference tracking, overlap analysis, and the guard editor in sync. Use the numeric and unknown-type rules from §1.

- [ ] **Add typed `toggle_var` and `reset_var`.** See [CoreVerbs](addons/callboard/core/core_verbs.gd) and [Blackboard](addons/callboard/core/blackboard.gd).
  - [x] `set_var` and `add_var` handle declared keys; the Blackboard schema retains their declared defaults.
  - [ ] Toggle Boolean keys and reset supported keys to their declared defaults through the normal write API. Specify persistence, notification, and writer behavior for Saved, Shared, and any Session scope. Validate unsupported targets in the editor.

## 3. State, restoration, and Stage lifecycle

- [ ] **Expose Shared key identity and enforce early store attachment.** See [BlackboardPanel](addons/callboard/editor/blackboard_panel.gd), [StageStateStore](addons/callboard/core/stage_state_store.gd), and [Stage](addons/callboard/core/stage.gd).
  - [x] Shared variables use a storage key. `load_stage()` attaches the store before adding the Stage to the scene tree.
  - [ ] Expose a shared-key picker or project-level schema. The board generates unique keys for new variables and changes only the scope when a variable becomes Shared, so matching display names can refer to different values. Define how existing persisted keys are preserved or deliberately remapped.
  - [ ] Reject attachment once a Stage has initialized its Blackboard and engine. The public attach method presently accepts initialized Stages even though the services were built against their original dictionaries.

- [ ] **Add a store-level cross-Stage event bus.** See [StageStateStore](addons/callboard/core/stage_state_store.gd) and [Stage](addons/callboard/core/stage.gd).
  - [x] The store maintains stable Stage instance IDs and shares values. Managed Stages can load dormant and ignore ordinary Calls until activation.
  - [ ] Deliver typed messages to active, loaded recipients. Define a policy for dormant and unloaded recipients, such as bounded delivery upon activation or recording a durable state change. Specify routing, ordering, replay/deduplication, and when messages expire or survive a save.
  - [ ] Validate declared targets and payload contracts across Stage definitions. Include cross-Stage routes in the dispatch budget and traces.

- [ ] **Add Session scope and reset rules.** See [Blackboard](addons/callboard/core/blackboard.gd), [StageStateStore](addons/callboard/core/stage_state_store.gd), and [BlackboardPanel](addons/callboard/editor/blackboard_panel.gd).
  - [x] Local, Saved, and Shared scopes exist. Store-backed Saved values and latches persist by Stage instance ID.
  - [ ] Define host-controlled session start/reset, session counters and flags across Stage reloads, and how session state interacts with durable profile progression and one-shot latches. Make scope, reset rules, and serialization behavior explicit in the UI and API.

- [ ] **Extend declarative restoration.** See [StageRestorationBinding](addons/callboard/core/stage_restoration_binding.gd) and [Stage](addons/callboard/core/stage.gd).
  - [x] Saved/Shared keys can restore visibility, a local `Transform3D`, or a marker's global transform. Marker restoration can optionally seek and pause an `AnimationPlayer` at a resolved pose. Bindings run after `_restore_state()` and before activation, with runtime and validation coverage.
  - [ ] Add standalone animation pose binding. Current validation expressly limits pose settings to marker bindings, although live rules have `pose_animation`.
  - [ ] Add a typed variant binding (for example, an integer selects a child, material, or animation), generic property binding, and specific light, audio, and particle state where lifecycle handling calls for it. Simple light visibility already works through visibility binding.
  - [ ] Validate key type and scope, target and property compatibility, variant choices, and resources. Define restoration behavior so reloads reconstruct state and avoid replaying transient cues by default.

- [ ] **Support asynchronous Stage loading and prewarming.** See [`StageStateStore.load_stage()`](addons/callboard/core/stage_state_store.gd).
  - [ ] Add threaded resource loading and a prewarm path while keeping scene instantiation, attachment, and tree changes on the main thread. The existing API takes a `PackedScene` and instantiates and parents it synchronously.
  - [ ] Define cancellation, duplicate requests, error reporting, and activation handoff. Measure loading and instantiation separately so prewarming addresses the work that actually causes a frame hitch.

## 4. Interactions, host integration, and staging

- [ ] **Make contact triggers game-agnostic.** See [TriggerArea](addons/callboard/core/trigger_area.gd).
  - [x] `TriggerArea` supports Enter and Interact. Interactions already expose host eligibility/handling hooks, accepted and rejected Calls, and payloads.
  - [ ] Honor scene-configured collision layers and masks, and make actor/body filtering optional and configurable. `_ready()` replaces both collision bitfields today, and the enter handler only accepts two fixed group names. Define compatibility for scenes relying on those defaults.
  - [ ] Support arbitrary body/prop contacts and an Exit Call or mode. Specify which body information is available in the payload and how managed/dormant Stages handle entry and exit.

- [ ] **Provide a generic item interaction and delivery contract.** The source proposals differ on whether inventory should be core. The existing addon delegates policy to the host. Confirm the scope of any optional reusable inventory component.
  - [x] `TriggerArea` provides `set_eligibility_hook()`, `set_interaction_handler()`, override points, and accepted/rejected outcome payloads. [InteractionResolver](addons/callboard/core/interaction_resolver.gd) selects one eligible target.
  - [ ] Define a reusable item-target or `DeliveryTarget` adapter for item IDs, held state, capacity, eligibility, consumption, returns, and wrong-item outcomes. Specify how an authored `has_item` guard or typed Blackboard declaration reads host inventory. Cover repeated attempts and rejected requests so an item is consumed at most once.
  - [ ] If a built-in inventory model is included, keep it optional and define its storage and lifecycle contract. Keep quests, dialogue content, navigation, and project-specific item and objective policy in host code via custom verbs and `gameplay_event`.

- [ ] **Add host request and acknowledgment.** See [`Stage.gameplay_event`](addons/callboard/core/stage.gd) and [`StagingVerbs.gameplay_event()`](addons/callboard/core/staging_verbs.gd).
  - [x] An authored `gameplay_event` step emits an ID and a deep-copied argument dictionary. The current signal is a one-way request.
  - [ ] Define optional correlation IDs, typed response data and success/rejection outcomes. Use §2 waits for timeout and cancellation. Define duplicate and late responses, and register interest early enough to catch a synchronous acknowledgment.

- [ ] **Support named actor states.** See [Blackboard](addons/callboard/core/blackboard.gd), [CoreVerbs](addons/callboard/core/core_verbs.gd), and [RuleValidator](addons/callboard/core/rule_validator.gd).
  - [ ] Add named states and a `set_state` step backed by typed Blackboard keys. Define transition, initial-state, and restoration semantics for idle, active, and resolved behaviors.
  - [ ] Support authored ambient behavior without requiring unused relays. Currently `repeat_emit` declares its relay and validation reports any emitted relay with no listener. Host scripts still own continuous behavior such as tracking, following, and navigation, plus game-specific objective ordering and session timers.

- [ ] **Support dynamic prompts and interaction enablement.** See [TriggerArea](addons/callboard/core/trigger_area.gd) and [InteractionResolver](addons/callboard/core/interaction_resolver.gd).
  - [x] The resolver reevaluates eligibility, notices changes to the configured prompt on refresh, and resolves again before dispatch. Triggers expose prompt text, icon, and priority.
  - [ ] Let authors derive prompt text/icon or availability from Blackboard state and host-provided context such as the held item. Add `set_interaction_enabled` and ensure disabling a target updates the resolver/prompt while the actor remains in range.

- [ ] **Add cancellation-safe input and camera control.**
  - [ ] Define generic `lock_input` and `release_input` requests with ownership, support for overlapping locks, and automatic release on cancellation or Stage teardown. Use host adapters for projects with their own controls.
  - [ ] Add camera focus, shake, and framing controls or typed host requests, with restoration when ownership changes or a sequence is interrupted.

- [ ] **Expand staging verbs.** See [StagingVerbs](addons/callboard/core/staging_verbs.gd).
  - [x] Built-ins cover visibility, timed light on/off, audio playback, translation, rotation, animation playback, and animation posing, alongside existing speech and mesh/prop effects.
  - [ ] Add `snap_to_marker` for live rules, reusing transform behavior from declarative restoration. Add configurable easing and path following for movement/rotation, and a typed generic property tween.
  - [ ] Add light color, energy, and flicker; `restart_particles`; audio stop, pitch, and bus; shader parameter changes; and animation speed and blend.
  - [ ] Add spawn, despawn, and reparent with explicit ownership and transform preservation options. Validate targets and parameters and use §1 cancellation and wait semantics for verbs that can block.

- [ ] **Support localization.** See [`StagingVerbs.say()`](addons/callboard/core/staging_verbs.gd) and [TriggerArea](addons/callboard/core/trigger_area.gd).
  - [ ] Add explicit translation-key support for authored speech, prompts, and host-supplied messages, with substitutions and fallback behavior. Preserve authored literal strings.

## 5. Board authoring and diagnostics

- [ ] **Explain why a rule did not run, and supply typed test payloads.** See [RuleEngine](addons/callboard/core/rule_engine.gd), [Callboard](addons/callboard/editor/callboard.gd), and [RuleInspector](addons/callboard/editor/rule_inspector.gd).
  - [x] Live traces cover fired events, starts, waits, steps, and cancellation. The inspector can edit payload field declarations.
  - [ ] Report failed guards with observed values, one-shot latch state, and Ignore/Restart/Queue decisions. Make order and rejection visible when several rules share a trigger.
  - [ ] Build a typed payload form from the trigger schema for live Call testing, with support for omitted fields. The current tester calls `fire(call_id)` with the default empty payload.

- [ ] **Expose and edit same-trigger rule order.** See [RuleEngine](addons/callboard/core/rule_engine.gd) and [RuleInspector](addons/callboard/editor/rule_inspector.gd).
  - [x] Rules are evaluated in authored array order. A synchronous write from an earlier rule can affect a later guard. The inspector can already reorder steps within a rule.
  - [ ] Show rule order by trigger, allow undoable reordering, and persist it independently of board layout. Add opt-in first-match and fallback routing for mutually exclusive outcomes while preserving existing multi-match dispatch by default.

- [ ] **Edit restoration, external writers, and managed lifecycle on the board.** See [StageDefinition](addons/callboard/core/stage_definition.gd), [GraphDraft](addons/callboard/model/graph_draft.gd), [RuleGraphReader](addons/callboard/model/rule_graph_reader.gd), and [BlackboardPanel](addons/callboard/editor/blackboard_panel.gd).
  - [x] `managed_lifecycle` is reachable through the `StageDefinition` resource in Godot's Inspector. It already round-trips through the draft, as do restoration bindings and external writers. Scene-based `BlackboardWriter` declarations also feed validation.
  - [ ] Add board controls for the lifecycle flag, typed writer declarations, and restoration bindings with key, target, marker, property, and animation pickers as applicable. Include standalone poses and the binding types from §3.
  - [ ] Add type-preserving defaults for `Transform3D` and other supported types. The Blackboard panel currently falls back to a `LineEdit` for unsupported Variants, which writes text back to a manually authored transform default on submit or focus loss. Preserve existing typed values across edits, undo, reload, and migration.

- [ ] **Add parameterized rule templates.**
  - [ ] Cover reusable interaction outcomes, repeating ambient behavior, conditional sequences, and objective completion. Define bindings for props, keys, Calls, relays, and payload fields.
  - [ ] Give instantiated rules fresh latch/storage identities by default, except for deliberately shared keys. Validate missing parameters and preserve internal references on duplication.

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
  - [ ] Exercise repeated editor/plugin setup and teardown, Stage unload, and pending-wait cancellation. Diagnose the smoke suite's rendering RID and ObjectDB leaks, distinguish fixture cleanup from addon ownership, and gate regressions with teardown log checks.
