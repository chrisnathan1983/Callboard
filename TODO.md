## Where the engine gets in the way

1. **Guards can't read payloads.**
   * `requires`, `forbids`, and `cancel_if` only evaluate Blackboard keys and numeric comparisons (`int`/`float`), not event payloads. A single `deliver` Call with `{item: trex}` cannot branch by item.
   * **Solution:** Declare distinct Calls per gift across the 20 neighborhood deliveries (`give:trex`, `give:pet`, `give:mailman`, etc.) and let gameplay code resolve which item was handed over.
   * **Naming Note:** Call IDs can contain colons (`give:trex`), but Blackboard keys must be valid GDScript identifiers (`got_trex`, not `got:trex`) so `GuardExpression` and `BlackboardPanel` accept them.

2. **No counter-increment verb.**
   * `CoreVerbs.set_var` only writes static values rather than incrementing counters.
   * **Solution:** Per-gift boolean flags work better anyway. Multi-gift households (House 2 and House 4 with 2 gifts, House 5 with 3 gifts) can list all required gift flags in `requires` on a `house_complete` rule for AND logic, while OR logic (e.g., racecar or fingerboard) uses two Calls emitting the same completion relay.

3. **Inventory and contextual prompts live outside Callboard.**
   * Carrying up to two items and switching the mobile action button prompt ("Deliver Gift 🎁", "Treat Critter 🐿️", "Boop / Interact 🔔") must be handled by external gameplay scripts.
   * **TriggerArea Prompt Metadata:** `TriggerArea` currently only exports `event`, `mode` (`ENTER` / `INTERACT`), and `ctx`. It needs prompt text/icon metadata and priority sorting so overlapping zones (e.g., standing near both a reindeer and a porch) display the highest-priority action on the single mobile button.
   * **GiftTarget & Rejections:** Build a player inventory and a `GiftTarget` area (for porches and yard critter spots) that checks held items, consumes the matching gift, and fires `give:<id>`. Wrong porch gifts—such as delivering the Shiny Red Racecar to the naughty kid at House 8 instead of the Lump of Coal—should fire a rejection Call (`deliver_wrong`), whereas dropping that same decoy at the critter spot fires the critter's `give:<id>` Call for a $+100$ bonus.

4. **Custom verbs and `Stage` signals are needed (`NightVerbs`).**
   * `RuntimeVerbCatalog` skips methods prefixed with `_`, so `StagingVerbs._light` is hidden from the Callboard verb picker.
   * `StagingVerbs.flash` and `jump` require a `BaseMaterial3D` `material_override` on target meshes and log a warning if missing.
   * `Stage` and `StepContext` only expose a `scored(points: int)` signal/callback; there is no built-in verb for strikes or player stuns.
   * **Solution:** Add a shared `NightVerbs extends StagingVerbs` base class (and matching signals on a shared `HouseStage extends Stage` subclass) for all 8 houses that:
     * Exposes a public `light(n, on, duration, key)` verb for timed floodlights and window silhouettes (House 1 porch motion light, House 4 parlor window).
     * Adds `strike(count)` and `stun_player(seconds)` verbs for wrong deliveries and getting caught in motion lights.
     * Adds a spin/pirouette verb (House 2 Dancer reflection, House 5 bicycle tire, House 6 power meter).
     * Adds an audio cue verb (House 1 Buster's bark and xylophone icicles, House 4 mechanical raven caw, House 5 handlebar bell, House 7 cuckoo chime).
     * Adds a freeze/pose verb or animation step (House 4 Vixen gargoyle freeze, window silhouette swaps).
     * Ensures imported 3D house props either supply a `BaseMaterial3D` override or use transform-only tweens (`pop`, `bounce`, `move_to`).

5. **Per-frame behavior and script-written keys need `external_vars`.**
   * Continuous or real-time updates belong in plain GDScript components (like `BumpProp`) rather than Callboard rules:
     * House 4: Rudolph acting as a live proximity light source when brought from the sleigh hub.
     * House 6: Rhythmic shader syncing between the roof Christmas lights and the hovering UFO.
     * House 7: The miniature yard train circling the tracks (firing a Call when diverted by the railway switch) and the attic telescope kid tracking Santa's position in real time.
   * **Validator Requirement (`external_vars`):** Whenever a gameplay script or `Stage.fire_relay_once()` writes a Blackboard key outside of a verb step (such as `yard_lit` when Rudolph walks into House 4), that key must be listed in `external_vars` on the `StageDefinition`, otherwise `RuleValidator` will flag `"rule '...' checks key '...' but nothing sets it"`.

6. **Window streaming and cross-house state make persistence critical.**
   * **Per-House State Dictionaries:** To support the 3-house sliding window (`[center - 1, center, center + 1]`), the manager must hold 8 separate pairs of `saved_vars` and `fired` dictionaries—one pair per house—rather than a single global pair.
   * **Global vs. Per-House State:** `Blackboard` only has `local` and per-stage `saved` scopes. Cross-house state—like Rudolph following Santa from the center sleigh hub into House 4, or which decoys have already been pulled from the 2D sack—must be synced by the manager into the active house's Blackboard on `activate()`.
   * **Dormant Neighbor Loading:** Instantiating a house as an adjacent neighbor runs `_ready()` (`build()` and `_restore_state()`), which snaps completed props into place. Only call `activate()` (firing `arrive` and starting loops like Dasher's standoff) when Santa enters the center lot, and call `deactivate()` when leaving.
   * **Saved Scope by Default:** Local Blackboard variables reset on unload, so anything persistent—delivered main gifts, fed critters, completed Rube Goldberg prop chains, and `yard_lit` states—must be declared as `saved`.
   * **State Restoration Helper:** Every visible state change needs a matching entry in `_restore_state()`. Add a small restore helper (mapping `saved_key` $\rightarrow$ node visibility, transform, or light state) on the shared `HouseStage` base script to cut repetition across all 8 stages.