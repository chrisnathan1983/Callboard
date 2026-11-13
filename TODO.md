## Where the engine gets in the way

1. **Guards can't read payloads.** `requires`, `forbids`, and `cancel_if` only check Blackboard keys. A single `deliver` Call with `{item: trex}` can't branch. Use distinct Calls per gift (`give:trex`, `give:pet`, …) and let gameplay code resolve which item was handed over.
2. **No counter verb.** `set_var` only writes values. Per-gift bool flags work better anyway: `house_complete` lists them all in `requires`. That covers the AND logic, and OR logic (racecar or fingerboard) is two Calls emitting one relay.
3. **Inventory lives outside Callboard.** Carrying two items needs a player inventory and a `GiftTarget` area that checks the held items, fires `give:<id>`, and consumes the item. Wrong gifts should fire a rejection Call.
4. **Custom verbs are needed.** Add a shared `NightVerbs extends StagingVerbs` with a `light(key)` promoted out of Stage 01, plus spin or pirouette, audio (Buster's howl), and a freeze pose. `flash` and `jump` only work on meshes with a `BaseMaterial3D` override, so imported art may skip them with a warning.
5. **Per-frame behavior isn't graph territory.** The tracking telescope and similar effects belong in plain scripts like `BumpProp`.
6. **Window streaming makes state critical.**
   - Local variables reset on unload, so anything that persists must be `saved`: gifts, critter, chain results, `yard_lit`.
   - Every visible result needs a matching line in `_restore_state()`.
   - The manager must hold one dict pair per house, since `GameManager` currently holds one.
   - A small restore helper (saved key → node visibility or position) would cut the repetition.
