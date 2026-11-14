@tool
extends TriggerArea
## Demo-specific delivery policy. The addon supplies selection, context, and dispatch.

# Configure one Boolean declaration per target in the scene. Stage collects it
# during editor analysis and runtime build. Its Source appears in the live debugger.
@export var callboard_writers: Array[BlackboardWriterData] = []

func is_interaction_eligible(_actor: Node) -> bool:
	# Eligibility controls the prompt. Keep undelivered gifts selectable even when
	# the office is closed to deliveries so the clerk can explain the refusal.
	# TriggerArea also checks whether the owning Stage currently accepts Calls.
	var flag := _delivery_flag()
	return flag != null and is_instance_valid(_stage) and not _stage.is_set(flag.key)

func handle_interaction(_actor: Node, interaction_context: Dictionary) -> Dictionary:
	# A real game's handler can check inventory and consume the item here. This
	# demo gives the player both gifts up front. Ctx on each scene node supplies
	# a String gift_id. Preserve the scene's ID if the actor supplied context with
	# the same key, so the flag we write and the rule we dispatch stay in sync.
	interaction_context["gift_id"] = ctx.get("gift_id", "")
	var accepted := (
		_stage.is_set(&"guard_calmed") and _stage.is_set(&"permit_stamped")
		and not _stage.is_set(&"lamp_on"))
	if accepted:
		# Publish the saved flag before the accepted Call runs. Its authored rule
		# shows the matching gift, increments the counters, and emits the receipt
		# relay. Both the resolver and the graph can now read the new flag.
		var flag := _delivery_flag()
		_stage.write_var(flag.key, true, flag.source)
	return {"accepted": accepted, "payload": interaction_context}

func _delivery_flag() -> BlackboardWriterData:
	return callboard_writers[0] if callboard_writers.size() == 1 else null
