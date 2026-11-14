# Callboard feature backlog

Implement these features in the addon. Each item covers rule authoring, runtime behavior, and the checks that define completion.
Please run / create applicable tests after completing each task. Update the TODO.
Keep the readme in sync with the code.

## 1. Call and relay payloads in guards

- [ ] Let a stage definition optionally declare typed payload fields for its Calls and relays. In guard expressions such as `payload.action == "confirm"`, the `payload.` prefix identifies an incoming field. Bare keys continue to refer to the Blackboard.
- [ ] Support string and Boolean equality, numeric comparisons, and field presence checks. A missing or incompatible field makes a value comparison fail, including inequality. Provide a separate presence check for rules that intentionally handle missing fields.
- [ ] Use the event payload in `requires`, `forbids`, and `cancel_if`. Recheck queued runs against their own payload when they start and use the active run's payload at cancellation checkpoints. Preserve payload fields when forwarding relays and keep engine bookkeeping out of the authored field namespace.
- [ ] Show fields from the selected trigger in the rule inspector. Validate field names and operand types where a schema is available, and list payload references separately from Blackboard dependencies.
- **Done when** one Call routes different payloads to different rules, with coverage for missing fields, relays, queued runs, and cancellation after a wait.

## 2. Numeric Blackboard updates

- [ ] Add an `add_var(key, delta)` core verb. Read the current value when the step executes and write the result through the Blackboard. Allow negative deltas and preserve the declared numeric type.
- [ ] Register the target as both a read and a write. Offer numeric keys in the step editor and flag invalid operands, including fractional deltas for integer keys.
- **Done when** repeated Calls update the same counter, a later step sees the new value, and saved counters continue from their restored value.

## 3. Contextual interactions

- [ ] Add prompt text, an optional icon, and priority to interactable triggers. Include an eligibility hook that receives the interacting actor and can query the host game's current state.
- [ ] Provide a resolver that selects one eligible trigger for an actor from overlapping candidates. Use a deterministic tie-break, update the selected prompt when availability changes, and dispatch only to the selected trigger. Let any input action or UI subscribe to the selected prompt and invoke the same interaction API.
- [ ] Pass an interaction context to the handler and let the handler produce the outcome and payload for Callboard. Projects supply inventory, item consumption, and interaction policy through this integration point.
- **Done when** overlapping triggers yield one prompt and one dispatch, eligibility can change while the actor stays in range, and accepted and rejected attempts can drive different rules.

## 4. Staging verbs and gameplay integration

- [ ] Expose the existing timed light behavior as an authored verb. Define the optional Blackboard key, return state after the timer, and cancellation behavior. Validate the target and key before play.
- [ ] Add reusable steps for audio playback, rotation, and animation playback or posing using Godot nodes. Where a step can wait for completion, make that behavior explicit and release its wait when the stage deactivates.
- [ ] Make tint effects work with compatible materials assigned to mesh surfaces as well as material overrides. Isolate any material changes to the target instance. Separate the transform portion of `jump` so it still works when tinting is unavailable.
- [ ] Add a typed outbound gameplay event on `Stage` and a corresponding verb for the graph, using authored event IDs and arguments. Host scripts subscribe and apply project-specific effects. Keep the existing scoring API available.
- **Done when** the verbs are selectable in the inspector, invalid targets are diagnosed there, two props can share a source material without sharing tint changes, and a graph can request a gameplay action through a standard stage API.

## 5. External Blackboard writers

- [ ] Add an editor-facing registration mechanism for external Blackboard writers. Let addon components and gameplay scripts declare which keys they own, including keys passed to latch helpers. Keep existing `external_vars` declarations valid.
- [ ] Use the same declarations in editor analysis and runtime validation. Treat declared external writes as producers, flag undeclared or incompatible keys, and keep warnings for keys with no known producer. Route actual writes through the typed Blackboard API and expose the writer source in the live debugger when available.
- [ ] Document how scene components publish continuous or per-frame state as Blackboard values or discrete Calls. Give scripts a supported way to declare their outputs so a stage author can see where a guard's inputs come from.
- **Done when** a scene component's declared output can feed a guard without a false warning, an undeclared key is diagnosed, and an external latch appears as a writer.

## 6. Stage persistence and activation

- [ ] Provide a reusable state store keyed by stable stage instance ID. Store each stage's saved Blackboard values and one-shot rule latches together. Support restoring that state before stage initialization and preserve the existing dictionary injection path for current callers.
- [ ] Add an explicit shared Blackboard scope backed by the same store. Validate types and propagate changes to loaded stages that declare the shared key. Keep local values, stage-saved values, and shared values selectable in the Blackboard editor.
- [ ] Provide an opt-in managed lifecycle for streamed stages. Load and restore a stage while dormant, activate it once on entry, and cancel pending work and ignore incoming Calls on deactivation. Keep the existing lifecycle behavior for stages that have not opted in.
- [ ] Add declarative restoration bindings from saved or shared values to supported node properties such as visibility, transforms, and light state. Apply them after state loads and before activation. Validate node paths and value types in the editor, and retain the script hook for custom restoration.
- **Done when** two instances of the same stage scene retain independent state and latches through unload and reload, exchange shared values without activation-time copying, and restore their visuals while dormant without dispatching Calls or starting rule loops.
