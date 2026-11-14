@tool
class_name DeliveryTarget extends TriggerArea
## Optional item-delivery trigger backed by host-owned inventory callbacks.

@export var accepted_item_ids: Array[StringName] = []
## -1 means unlimited deliveries for this runtime instance; zero disables delivery.
@export_range(-1, 2147483647, 1) var capacity: int = -1
@export_range(0, 2147483647, 1) var delivered_count := 0
var _held_item_provider: Callable
var _consume_held_item: Callable
var _return_item_to_actor: Callable
var _active_deliveries: Dictionary = {}
var _next_delivery_id := 1

## Configure callbacks against the host inventory. consume_item must atomically verify
## that this exact item is still held and remove it; return_item restores a rolled-back delivery.
func set_inventory_adapter(held_item_provider: Callable, consume_item: Callable,
		return_item: Callable = Callable()) -> void:
	_held_item_provider = held_item_provider
	_consume_held_item = consume_item
	_return_item_to_actor = return_item

func is_interaction_eligible(actor: Node) -> bool:
	return is_instance_valid(actor) and _held_item_provider.is_valid() \
		and _consume_held_item.is_valid() and (capacity < 0 or delivered_count < capacity)

func handle_interaction(actor: Node, interaction_context: Dictionary) -> Dictionary:
	if not _held_item_provider.is_valid() or not _consume_held_item.is_valid():
		return _rejected(&"inventory_adapter_missing", &"", interaction_context)
	var held_value: Variant = _held_item_provider.call(actor)
	if not (held_value is String or held_value is StringName):
		return _rejected(&"no_item_held", &"", interaction_context)
	var item_id := StringName(held_value)
	if item_id.is_empty():
		return _rejected(&"no_item_held", item_id, interaction_context)
	if not accepted_item_ids.is_empty() and not accepted_item_ids.has(item_id):
		return _rejected(&"wrong_item", item_id, interaction_context)
	if capacity >= 0 and delivered_count >= capacity:
		return _rejected(&"target_full", item_id, interaction_context)
	if not bool(_consume_held_item.call(actor, item_id)):
		return _rejected(&"item_changed", item_id, interaction_context)
	var delivery_id := _next_delivery_id
	_next_delivery_id += 1
	_active_deliveries[delivery_id] = item_id
	delivered_count += 1
	var payload := interaction_context.duplicate(true)
	payload.merge({
		"item_id": String(item_id),
		"delivery_id": delivery_id,
		"delivered_count": delivered_count,
		"capacity": capacity,
	}, true)
	return {"accepted": true, "payload": payload}

## Return one previously accepted delivery when host-owned follow-up work rolls it back.
## Failed returns keep the delivery reservation so the host can retry safely.
func return_delivery(delivery_id: int, actor: Node) -> bool:
	if not _active_deliveries.has(delivery_id) or not _return_item_to_actor.is_valid():
		return false
	var item_id: StringName = _active_deliveries[delivery_id]
	if not bool(_return_item_to_actor.call(actor, item_id)):
		return false
	_active_deliveries.erase(delivery_id)
	delivered_count = maxi(0, delivered_count - 1)
	return true

func _rejected(reason: StringName, item_id: StringName,
		interaction_context: Dictionary) -> Dictionary:
	var payload := interaction_context.duplicate(true)
	payload.merge({
		"reason": String(reason),
		"item_id": String(item_id),
		"delivered_count": delivered_count,
		"capacity": capacity,
	}, true)
	return {"accepted": false, "payload": payload}
