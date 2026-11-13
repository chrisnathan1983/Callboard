@tool
class_name CallboardContextMenu extends PopupMenu
## Builds and positions the graph's contextual creation/edit menu.

var context_target: Dictionary = {}
var create_position := Vector2.ZERO

func open_for(data: Dictionary, graph: RuleGraphView, pointer: Vector2, event_disabled: bool,
		create_event: int, create_rule: int, create_group: int,
		edit_target: int, duplicate_rule: int, delete_target: int) -> void:
	create_position = (pointer + graph.scroll_offset) / graph.zoom
	context_target = graph.context_target_at(pointer)
	clear()
	if context_target.is_empty():
		add_item("New Call", create_event)
		set_item_disabled(0, event_disabled)
		add_item("New rule", create_rule)
		add_item("New group", create_group)
	else:
		var kind: String = context_target["kind"]
		add_item("Manage Call" if kind == "event" else "Edit " + kind, edit_target)
		if kind == "rule":
			add_item("Duplicate rule", duplicate_rule)
		add_separator()
		add_item("Delete " + kind, delete_target)
		if kind == "event":
			var error := RuleConnections.edit_error(data, context_target["id"])
			var index := get_item_index(delete_target)
			set_item_disabled(index, not error.is_empty())
			set_item_tooltip(index, error)
	position = Vector2i(graph.get_screen_transform() * pointer)
	popup()
