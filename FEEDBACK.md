## Tier 1: the design can't be expressed faithfully without these

| Gap | Evidence in code | Why the scenario needs it |
| :---- | :---- | :---- |
| **Rules can't trigger on Blackboard changes** | Triggers are only Calls and relays. `var_changed` goes to host code, not rules. | Shared keys carry state across houses, but nothing in a neighbor reacts to them. House 2's recorder making House 1's Buster howl needs an `on_change` trigger. |
| **No cross-stage events** | `StageStateStore` syncs values only. A dormant Stage ignores Calls. | Cross-house gags are events. They need a store-level bus that delivers live to loaded Stages and queues or resolves into state for unloaded ones. |
| **No mid-rule relay emission** | Only `repeat_emit` and the rule's final `emits` fire relays. | One rule can't fire "icicle fell", then "mailbox rattled", then "bone out" in sequence. A built-in `emit_relay` verb with `Step.emits` and `emit_arg` is the natural fit. |
| **No parallel steps** | `RuleEngine._run` awaits steps strictly in order. | Chains need simultaneous beats (Prancer rings the bell while the garage opens). A `fork` or step group with an optional join is needed. |
| **No branching or randomness inside a rule** | Variants require separate rules plus overlap warnings. | Reindeer reactions, critter idles, and wrong-gift lines need weighted or random picks (seeded, saved for determinism) and per-step guards or `branch`. |
| **Guards can't express OR, key comparisons, or string Blackboard values** | `GuardExpression` has literal-only comparisons, and string Blackboard keys are rejected. | "Racecar or fingerboard", `gifts_delivered >= gifts_required`, and enum states like `curtain == "open"` all need it. |
| **Step arguments are compile-time only** | `_build_step` evaluates with props and constants, with no payload. | A step can't say or score something derived from the incoming gift. `set_var` and `say` need payload-bound arguments. |
| **No wait-for or timeout step** | Delay is only `.after()`. | "Grandma jumps if the bell rings within 3 seconds of the curtain opening" needs `wait_for(relay or guard, timeout)`. |
| **No inventory or item model** | The demo gives gifts up front, and `GiftTarget` is demo code. | Items with capacity, held state, consume and return, wrong-item outcomes, and `has_item` guards should be core. A generic `DeliveryTarget` replaces the demo's hard-coded policy. |

## Tier 2: needed to make the houses feel directed

| Gap | Notes |
| :---- | :---- |
| **Actor state machines** | About 8 reindeer, 8 critters, and NPCs each have idle, reacting, and done states. Ambient `repeat_emit` loops trigger the "emitted but no listener" validator warning. Actors with named states, driven by `set_state` steps and Blackboard keys, would fit better. |
| **Prop-to-prop contact triggers** | `TriggerArea` ENTER is player- and companion-only, and `BumpProp` checks the Player group. Sleds hitting trash cans, trains hitting paint cans, and the puck hitting the garage button need a contact trigger for arbitrary bodies, plus an EXIT mode. |
| **Cutscene control** | `stun_courier` stands in for input lock, and there's no camera direction. Add `lock_input` and `release_input` verbs that release on cancel, and camera verbs for focus, shake, and framing. |
| **Richer staging verbs** | `move_to` and `rotate_to` are linear and need easing or paths. Missing: generic property tween, light color/energy/flicker, particle restart, audio stop/pitch/bus, shader parameter, spawn/despawn, reparent (critter wearing the turtleneck), and animation speed/blend. |
| **More restoration binding kinds** | Only visibility, transform, and marker snap exist. Add a variant binding (saved int selects a child, material, or animation), a generic property binding, and light/audio/particle state. Otherwise every critter outcome needs `_restore_state()` code. |
| **Dynamic prompts** | `prompt_text` is static. "Deliver gift" vs "Treat critter" vs "Boop" should come from held item and Blackboard state. |
| **Run vs profile scope** | Scopes are local, saved, and shared. Strikes and score for a night should reset between nights while progression persists, so a session scope and reset rules are needed. |

## Tier 3: scale and workflow

| Gap | Why it matters at 8 houses |
| :---- | :---- |
| **Reusable rule patterns** | You'll repeat hazard loop, gift delivery, critter decoy, and completion about 8 times, plus 20 delivery rules. Without parameterized templates, each copy is hand-edited with fresh state keys. |
| **Restoration and writer editing in the UI** | Bindings and external writers are Inspector-only on the `.tres`. Dozens per house is error-prone. |
| **Cross-stage validation** | The store only reports conflicts among loaded Stages. A project-wide pass should check shared-key types, unwritten shared keys, and that cross-house targets exist. |
| **Solvability analysis** | Check that every house can reach completion and that no one-shot can be consumed before its gift. The validator only catches "nothing sets it" per key. |
| **Scenario test harness** | Current tests are hand-written. A headless Call-sequence runner, rule coverage report, and time fast-forward in the live debugger would make 20 deliveries testable. |
| **Async stage loading** | `load_stage` instantiates synchronously. On mobile, streaming a house mid-walk will hitch, so it needs threaded load and prewarm. |
| **Localization** | `say` and letters take raw strings. Use translation keys. |
| **Managed lifecycle in the UI** | I saw `managed_lifecycle` in the snapshot but no control in the inspector. Check whether it's reachable. |

## What stays outside the addon

Per-frame behavior like the tracking telescope and Rudolph's follow AI belongs in game scripts, and so do the ring order and the night timer. The addon just needs to expose clean hooks to them: contact triggers, state machines, and the cross-stage bus.

## Suggested build order

1. **Rule engine:** `on_change` trigger, `emit_relay`, `fork`, `wait_for`, branch and random, and the expanded guard grammar. These change the core and the validator, so do them first.
2. **State:** store-level event bus with dormant queueing, new binding kinds, and session scope.
3. **Gameplay components:** inventory and `DeliveryTarget`, contact triggers, actor states, and dynamic prompts.
4. **Staging verbs:** the expanded verb set and camera and input lock.
5. **Tooling:** templates, binding editor, cross-stage validation, solvability checks, and the test harness.

I can spec the first group in detail (trigger syntax, validator rules, cancellation behavior for `fork` and `wait_for`) next, since everything else builds on those.