@tool
class_name CallboardConnections extends RefCounted
## Calls and relays authoring panel, separated from the graph controller.

const Style := preload("res://addons/callboard/editor/board_style.gd")

var panel: PanelContainer
var rows := VBoxContainer.new()
var cards: Dictionary = {}
var expanded: Dictionary = {}
var delete_dialog := ConfirmationDialog.new()
var _scroll := ScrollContainer.new()
var _pending_delete := ""
var _rename_handler: Callable
var _delete_handler: Callable
var _error_handler: Callable
var _fire_handler: Callable

func setup(parent: Node, create_call_button: Button, layout_changed: Callable,
		rename_handler: Callable, delete_handler: Callable, error_handler: Callable,
		fire_handler: Callable) -> PanelContainer:
	_rename_handler = rename_handler
	_delete_handler = delete_handler
	_error_handler = error_handler
	_fire_handler = fire_handler
	var fields := VBoxContainer.new()
	fields.custom_minimum_size.x = Style.LIST_WIDTH
	fields.add_theme_constant_override("separation", Style.ENTRY_GAP)
	var header := HBoxContainer.new()
	var title := Style.label("Calls & relays", Style.TEXT, 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)
	header.add_child(create_call_button)
	fields.add_child(header)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rows.add_theme_constant_override("separation", Style.ENTRY_GAP)
	rows.minimum_size_changed.connect(layout_changed, CONNECT_DEFERRED)
	_scroll.add_child(rows)
	fields.add_child(_scroll)
	panel = Style.panel(fields, Style.SURFACE, Vector2(12, 10), true)
	delete_dialog.title = "Delete Call or relay"
	delete_dialog.ok_button_text = "Delete"
	delete_dialog.confirmed.connect(_delete_selected)
	parent.add_child(delete_dialog)
	return panel

func clear_expanded() -> void:
	expanded.clear()

func refresh(data: GraphDraft, editable: bool, preferred := "") -> void:
	for card in rows.get_children():
		rows.remove_child(card)
		card.queue_free()
	cards.clear()
	var ids := RuleConnections.ids(data)
	for id in expanded.keys():
		if not ids.has(id):
			expanded.erase(id)
	if ids.has(preferred):
		expanded[preferred] = true
	for id in ids:
		var card := _make_card(data, editable, id)
		cards[id] = card
		rows.add_child(card)
	if ids.is_empty():
		rows.add_child(Style.label("No Calls or relays.", Style.MUTED, 13))
	if cards.has(preferred):
		_reveal.call_deferred(preferred)

func confirm_delete(data: GraphDraft, editable: bool, id: String) -> void:
	if not editable or not RuleConnections.edit_error(data, id).is_empty():
		return
	_pending_delete = id
	var affected := RuleConnections.impact(data, id)
	var prompt := "Delete '%s'?" % id
	if not affected.is_empty():
		prompt += "\n\nThese connections will be removed. Listed steps will be deleted.\n"
		prompt += "\n".join(affected.slice(0, 6))
		if affected.size() > 6:
			prompt += "\n… and %d more. See the full list in Calls & relays." % (affected.size() - 6)
	delete_dialog.dialog_text = prompt
	delete_dialog.popup_centered()

func _reveal(id: String) -> void:
	var card: Control = cards.get(id)
	if card != null and panel.is_visible_in_tree():
		_scroll.ensure_control_visible(card)

func _make_card(data: GraphDraft, editable: bool, id: String) -> PanelContainer:
	var card := VBoxContainer.new()
	card.add_theme_constant_override("separation", 6)
	var is_relay := id.begins_with(RuleConnections.RELAY_PREFIX)
	var edit_error := RuleConnections.edit_error(data, id)
	var name_edit := LineEdit.new()
	name_edit.name = "ConnectionName"
	name_edit.text = id.trim_prefix(RuleConnections.RELAY_PREFIX)
	name_edit.tooltip_text = id
	name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_edit.editable = editable and edit_error.is_empty() and id != "arrive"
	var header := HBoxContainer.new()
	header.add_child(name_edit)
	var delete := Button.new()
	Style.button_icon(delete, &"Remove", "✕")
	delete.accessibility_name = "Delete %s" % id
	delete.pressed.connect(func() -> void: confirm_delete(data, editable, id))
	delete.name = "DeleteConnection"
	delete.disabled = not editable or not edit_error.is_empty()
	delete.visible = editable
	delete.tooltip_text = "Delete %s" % id if edit_error.is_empty() else edit_error
	header.add_child(delete)
	card.add_child(header)

	var actions := HBoxContainer.new()
	var kind := Style.label("Relay" if is_relay else "Call", Style.RELAY if is_relay else Style.EVENT, 13)
	kind.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	actions.add_child(kind)
	var affected := RuleConnections.impact(data, id)
	var details_button := Button.new()
	details_button.text = "%d %s" % [affected.size(), "use" if affected.size() == 1 else "uses"]
	details_button.tooltip_text = "Show or hide affected rules"
	details_button.toggle_mode = true
	details_button.button_pressed = expanded.has(id)
	actions.add_child(details_button)
	var rename := Button.new()
	rename.text = "Rename"
	rename.disabled = true
	rename.visible = name_edit.editable
	actions.add_child(rename)
	card.add_child(actions)

	var details_text := "\n".join(affected) if not affected.is_empty() else "No rule connections."
	if id == "arrive":
		details_text += "\n\nThe Stage lifecycle fires this built-in Call."
	elif data.external_calls.has(id):
		details_text += "\n\nUpdate any gameplay code or scene triggers that fire this ID."
	var details := Style.label(details_text, Style.TEXT, 13)
	details.name = "ConnectionDetails"
	details.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	details.visible = details_button.button_pressed
	details_button.toggled.connect(func(open: bool) -> void:
		details.visible = open
		if open:
			expanded[id] = true
		else:
			expanded.erase(id))
	card.add_child(details)
	if not editable and not is_relay:
		var fire_row := HBoxContainer.new()
		var fire_hint := Style.label("Trigger this Call", Style.MUTED, 12)
		fire_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		fire_row.add_child(fire_hint)
		var fire := Button.new()
		fire.name = "FireCall"
		fire.text = "Fire"
		fire.tooltip_text = "Fire '%s' on the live Stage" % id
		fire.disabled = not _fire_handler.is_valid()
		fire.pressed.connect(func() -> void:
			if _fire_handler.is_valid():
				_fire_handler.call(id))
		fire_row.add_child(fire)
		card.add_child(fire_row)

	var error := Style.label("", Style.WARNING, 13)
	error.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	error.hide()
	card.add_child(error)
	var commit := func() -> void:
		if rename.disabled:
			return
		var new_name := name_edit.text.strip_edges()
		var failure: String = _rename_handler.call(id, new_name)
		if failure.is_empty():
			var new_id := RuleConnections.RELAY_PREFIX + new_name if is_relay else new_name
			refresh(data, editable, new_id)
		else:
			error.text = failure
			error.show()
	name_edit.text_changed.connect(func(value: String) -> void:
		rename.disabled = value.strip_edges() == id.trim_prefix(RuleConnections.RELAY_PREFIX)
		error.hide())
	name_edit.text_submitted.connect(func(_value: String) -> void: commit.call())
	rename.pressed.connect(commit)
	return Style.entry(card)

func _delete_selected() -> void:
	var error: String = _delete_handler.call(_pending_delete)
	_pending_delete = ""
	if not error.is_empty():
		_error_handler.call(error)
