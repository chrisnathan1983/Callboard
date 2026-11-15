@tool
class_name RuleInspector extends ScrollContainer
## Property editor for the selected rule (or group). Edits the model dictionaries in place and
## emits `changed`. Step argument widgets are generated from the verb's typed signature:
## props become dropdowns of compatible props, bools check boxes, numbers spin boxes,
## Blackboard `key` parameters a dropdown of declared keys, anything else a raw expression box.

signal changed(rule_id: String)
signal numeric_changed(rule_id: String, spin: SpinBox)
signal structure_changed(rule_id: String)   # inspector rebuilt itself; board should refresh the graph
signal delete_requested(rule_id: String)
signal duplicate_requested(rule_id: String)
signal rule_move_requested(rule_id: String, direction: int)
signal trigger_routing_edited(trigger: StringName, mode: int, fallback_rule_id: StringName)
signal group_edited(group_name: String)
signal group_delete_requested(group_name: String)
signal content_size_changed

const Style := preload("res://addons/callboard/editor/board_style.gd")
const GuardExpression := preload("res://addons/callboard/core/guard_expression.gd")
const TriggerRoutingData = preload("res://addons/callboard/core/trigger_routing_data.gd")

var _data: GraphDraft
var _rule: RuleData
var _group: GroupData
var _read_only := false
var _box := VBoxContainer.new()

func _init() -> void:
	custom_minimum_size = Vector2(284, 0)
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_box.add_theme_constant_override("separation", 8)
	_box.minimum_size_changed.connect(_on_content_minimum_size_changed)
	add_child(_box)

func _ready() -> void:
	if Engine.is_editor_hint():
		custom_minimum_size.x = 284 * get_theme_default_base_scale()

func content_height() -> float:
	return _box.get_combined_minimum_size().y

func _on_content_minimum_size_changed() -> void:
	content_size_changed.emit()

func clear() -> void:
	_clear()
	_rule = null
	_group = null

func show_rule(rule: RuleData, data: GraphDraft, read_only := false) -> void:
	if not is_same(_rule, rule):
		scroll_vertical = 0
	_rule = rule
	_group = null
	_data = data
	_read_only = read_only
	_build_rule()

func show_group(group: GroupData, data: GraphDraft, read_only := false) -> void:
	if not is_same(_group, group):
		scroll_vertical = 0
	_group = group
	_rule = null
	_data = data
	_read_only = read_only
	_clear()
	_title("Group")
	var name_edit := LineEdit.new()
	name_edit.text = group.name
	var apply := func(_t := "") -> void: _rename_group(name_edit)
	name_edit.text_submitted.connect(apply)
	name_edit.focus_exited.connect(apply)
	_box.add_child(name_edit)
	var del := Button.new()
	del.text = "Delete group (keeps its rules)"
	del.pressed.connect(func() -> void: group_delete_requested.emit(group.name))
	_box.add_child(del)
	if read_only:
		_lock(_box)

func _clear() -> void:
	for c in _box.get_children():
		_box.remove_child(c)
		c.queue_free()

func _rebuild_later() -> void:
	call_deferred("_build_rule")

# --- Rule form --------------------------------------------------------------------

func _build_rule() -> void:
	if _rule == null:
		return
	_clear()
	var r := _rule
	_add_diagnostics(_data.errors_for(r), "Errors", Style.ERROR)
	_add_diagnostics(_data.warnings_for(r), "Warnings", Style.WARNING)
	_line("ID", r.id, func(t: String) -> void: _set_id(t))

	var trig := HBoxContainer.new()
	var trig_edit := LineEdit.new()
	trig_edit.text = r.trigger
	trig_edit.tooltip_text = trig_edit.text
	trig_edit.placeholder_text = "trigger"
	trig_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var apply_trig := func(_t := "") -> void:
		trig_edit.tooltip_text = trig_edit.text.strip_edges()
		_set_trigger(trig_edit.tooltip_text)
	trig_edit.text_submitted.connect(apply_trig)
	trig_edit.focus_exited.connect(apply_trig)
	trig.add_child(_name_label("Trigger"))
	trig.add_child(trig_edit)
	var pick := MenuButton.new()
	Style.button_icon(pick, &"GuiDropdown", "▾")
	pick.flat = false
	pick.accessibility_name = "Pick trigger"
	pick.tooltip_text = "Pick a declared Call or an emitted relay"
	var options := _trigger_options()
	for o in options:
		pick.get_popup().add_item(o)
	pick.get_popup().index_pressed.connect(func(i: int) -> void:
		trig_edit.text = options[i]
		apply_trig.call())
	trig.add_child(pick)
	_box.add_child(trig)
	_box.add_child(_payload_schema_panel())

	for g in AuthoredData.GUARDS:
		_box.add_child(_guard_menu(g))

	var policy := OptionButton.new()
	var one_shot := CheckBox.new()
	one_shot.text = "One-shot"
	one_shot.tooltip_text = "Latch when the rule starts. Reuse the Stage's fired dictionary to preserve the latch across loads."
	one_shot.button_pressed = r.one_shot
	one_shot.toggled.connect(func(on: bool) -> void:
		r.one_shot = on
		if on and r.reentry != Rule.ReentryPolicy.IGNORE:
			r.reentry = Rule.ReentryPolicy.IGNORE
			policy.select(policy.get_item_index(Rule.ReentryPolicy.IGNORE))
		for incompatible_policy in [Rule.ReentryPolicy.RESTART, Rule.ReentryPolicy.QUEUE]:
			policy.get_popup().set_item_disabled(
				policy.get_item_index(incompatible_policy), on)
		changed.emit(r.id))
	_box.add_child(one_shot)

	var reentry := HBoxContainer.new()
	reentry.add_child(_name_label("While running"))
	policy.name = "ReentryPolicy"
	policy.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	policy.add_item("Ignore", Rule.ReentryPolicy.IGNORE)
	policy.add_item("Restart", Rule.ReentryPolicy.RESTART)
	policy.add_item("Queue", Rule.ReentryPolicy.QUEUE)
	var menu := policy.get_popup()
	menu.set_item_tooltip(0, "Drop triggers received while this rule is running.")
	menu.set_item_tooltip(1, "Stop at the next cancellation check and use the latest trigger. Unavailable for one-shot rules.")
	menu.set_item_tooltip(2, "Run pending triggers in order once the active run ends. Unavailable for one-shot rules.")
	for incompatible_policy in [Rule.ReentryPolicy.RESTART, Rule.ReentryPolicy.QUEUE]:
		menu.set_item_disabled(policy.get_item_index(incompatible_policy), r.one_shot)
	if r.one_shot and r.reentry != Rule.ReentryPolicy.IGNORE:
		r.reentry = Rule.ReentryPolicy.IGNORE
	policy.select(policy.get_item_index(r.reentry))
	policy.item_selected.connect(func(i: int) -> void:
		if r.one_shot and policy.get_item_id(i) != Rule.ReentryPolicy.IGNORE:
			policy.select(policy.get_item_index(Rule.ReentryPolicy.IGNORE))
			return
		r.reentry = policy.get_item_id(i)
		changed.emit(r.id))
	reentry.add_child(policy)
	_box.add_child(reentry)
	var overlap := CheckBox.new()
	overlap.text = "Expect shared-trigger overlap"
	overlap.tooltip_text = "Suppress shared-trigger overlap warnings for this rule. Use when concurrent runs are intentional."
	overlap.button_pressed = r.allow_overlap
	overlap.toggled.connect(func(on: bool) -> void:
		r.allow_overlap = on
		changed.emit(r.id))
	_box.add_child(overlap)
	_box.add_child(_trigger_order_panel(r))

	_line("Emits relay", r.emit, func(t: String) -> void:
		r.emit = t
		changed.emit(r.id))

	var grp := HBoxContainer.new()
	grp.add_child(_name_label("Group"))
	var ob := OptionButton.new()
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ob.fit_to_longest_item = false
	ob.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	ob.add_item("(none)")
	var sel := 0
	for i in _data.groups.size():
		ob.add_item(_data.groups[i].name)
		if _data.groups[i].name == r.group:
			sel = i + 1
	ob.select(sel)
	ob.item_selected.connect(func(i: int) -> void:
		r.group = "" if i == 0 else _data.groups[i - 1].name
		changed.emit(r.id))
	grp.add_child(ob)
	_box.add_child(grp)

	_title("Steps")
	for i in r.steps.size():
		_box.add_child(_step_panel(i))
	var add := MenuButton.new()
	add.text = "+ Add step"
	add.flat = false
	var verbs: Array = _data.catalog.map(func(v: Dictionary) -> String: return v["name"])
	verbs.append("Parallel group")
	verbs.append("Conditional branches")
	for v in verbs:
		add.get_popup().add_item(v)
	add.get_popup().index_pressed.connect(func(i: int) -> void:
		r.steps.append(_new_step_data(verbs[i]))
		changed.emit(r.id)
		_rebuild_later())
	_box.add_child(add)

	var buttons := HBoxContainer.new()
	var dup := Button.new()
	dup.text = "Duplicate"
	dup.pressed.connect(func() -> void: duplicate_requested.emit(r.id))
	buttons.add_child(dup)
	var del := Button.new()
	del.text = "Delete rule"
	del.pressed.connect(func() -> void: delete_requested.emit(r.id))
	buttons.add_child(del)
	_box.add_child(buttons)

	if _read_only:
		_lock(_box)

func _add_diagnostics(messages: Array[String], heading: String, color: Color) -> void:
	if messages.is_empty():
		return
	_box.add_child(Style.label(heading, color, 13))
	for message in messages:
		var label := Style.label(message, color, 12)
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_box.add_child(label)

func _trigger_order_panel(rule: RuleData) -> Control:
	var panel := VBoxContainer.new()
	_title("Order for “%s”" % rule.trigger)
	var peers: Array[RuleData] = _data.rules.filter(func(item: RuleData) -> bool:
		return item.trigger == rule.trigger)
	for index in peers.size():
		var peer_id := peers[index].id
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = "%d. %s" % [index + 1, peers[index].id]
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var up := Button.new()
		up.text = "Up"
		up.tooltip_text = "Move this rule earlier for its trigger"
		up.disabled = index == 0 or _read_only
		up.pressed.connect(func() -> void: rule_move_requested.emit(peer_id, -1))
		row.add_child(up)
		var down := Button.new()
		down.text = "Down"
		down.tooltip_text = "Move this rule later for its trigger"
		down.disabled = index == peers.size() - 1 or _read_only
		down.pressed.connect(func() -> void: rule_move_requested.emit(peer_id, 1))
		row.add_child(down)
		panel.add_child(row)
	var route := _routing_for(rule.trigger)
	var mode := OptionButton.new()
	mode.add_item("All matching rules", TriggerRoutingData.Mode.MULTI_MATCH)
	mode.add_item("First eligible rule", TriggerRoutingData.Mode.FIRST_MATCH)
	mode.select(mode.get_item_index(route.mode))
	mode.disabled = _read_only
	panel.add_child(mode)
	var fallback := OptionButton.new()
	fallback.tooltip_text = "Try this rule only if no other rule for the trigger passes its guards."
	fallback.add_item("No fallback", 0)
	for peer: RuleData in peers:
		fallback.add_item("Fallback: %s" % peer.id, peers.find(peer) + 1)
	fallback.select(0)
	for i in range(1, fallback.item_count):
		if peers[fallback.get_item_id(i) - 1].id == route.fallback_rule_id:
			fallback.select(i)
	fallback.disabled = _read_only or route.mode != TriggerRoutingData.Mode.FIRST_MATCH
	panel.add_child(fallback)
	mode.item_selected.connect(func(_index: int) -> void:
		fallback.disabled = _read_only or mode.get_selected_id() != TriggerRoutingData.Mode.FIRST_MATCH
		trigger_routing_edited.emit(rule.trigger, mode.get_selected_id(), _fallback_id(peers, fallback)))
	fallback.item_selected.connect(func(_index: int) -> void:
		trigger_routing_edited.emit(rule.trigger, mode.get_selected_id(), _fallback_id(peers, fallback)))
	return panel

func _routing_for(trigger: StringName) -> TriggerRoutingData:
	for route: TriggerRoutingData in _data.trigger_routing:
		if route.trigger == trigger:
			return route
	var route := TriggerRoutingData.new()
	route.trigger = trigger
	return route

func _fallback_id(peers: Array[RuleData], option: OptionButton) -> StringName:
	var item_id := option.get_selected_id()
	return peers[item_id - 1].id if item_id > 0 and item_id <= peers.size() else &""

func _title(text: String) -> void:
	_box.add_child(Style.label(text, Style.EVENT, 13))

func _name_label(text: String) -> Label:
	var l := Style.label(text, Style.MUTED, 13)
	l.custom_minimum_size.x = 92 * (get_theme_default_base_scale() if is_inside_tree() else 1.0)
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.tooltip_text = text
	return l

func _line(label: String, value: String, on_commit: Callable) -> void:
	var row := HBoxContainer.new()
	row.add_child(_name_label(label))
	var e := LineEdit.new()
	e.text = value
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var apply := func(_t := "") -> void:
		var text := e.text.strip_edges()
		if text != e.get_meta("committed", value):
			e.set_meta("committed", text)
			on_commit.call(text)
	e.text_submitted.connect(apply)
	e.focus_exited.connect(apply)
	row.add_child(e)
	_box.add_child(row)

func _set_id(t: String) -> void:
	if t == _rule.id:
		return
	if t == "" or AuthoredData.rule_ids(_data).has(t) or not t.is_valid_identifier():
		_rebuild_later()   # reject: restore the old text
		return
	if _rule.state_key.is_empty():
		_rule.state_key = _rule.id
	_rule.id = t
	changed.emit(t)

func _set_trigger(t: String) -> void:
	if t == _rule.trigger:
		return
	for route: TriggerRoutingData in _data.trigger_routing:
		if route.fallback_rule_id == _rule.id:
			route.fallback_rule_id = &""
	_rule.trigger = t
	changed.emit(_rule.id)
	_rebuild_later()

## Declared external events plus every relay some rule emits.
func _trigger_options() -> Array:
	var out := _data.external_calls.duplicate()
	if not out.has("on_change"):
		out.append("on_change")
	for rd in _data.rules:
		for relay in RuleGraphView.output_relays(rd, _data):
			if relay != "" and not out.has("relay:" + relay):
				out.append("relay:" + relay)
	return out

func _payload_schema_panel() -> Control:
	var section := VBoxContainer.new()
	section.add_child(Style.label("Payload fields for %s" % _rule.trigger, Style.RELAY, 12))
	var fields: Array[PayloadFieldData] = []
	for field: PayloadFieldData in _data.payload_fields:
		if field.event_id == StringName(_rule.trigger):
			fields.append(field)
	if fields.is_empty():
		var empty_text := "Built-in fields: key, previous, value, scope, writer. The transition values retain the Blackboard key's type." if _rule.trigger == &"on_change" else "No fields declared. Calls can still pass payload dictionaries; guards are checked at runtime."
		var empty := Style.label(empty_text, Style.MUTED, 11)
		empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		section.add_child(empty)
	var referenced := {}
	for guard in _rule.requires + _rule.forbids + _rule.cancel_if:
		for field_key in GuardExpression.referenced_payload_fields(guard):
			referenced[field_key] = true
	var reference_names: Array[String] = []
	for field_key in referenced:
		reference_names.append(String(field_key))
	reference_names.sort()
	var refs_text := "Guard payload references: " + (", ".join(reference_names) if not reference_names.is_empty() else "None")
	var refs := Style.label(refs_text, Style.MUTED, 11)
	refs.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	section.add_child(refs)
	for field in fields:
		var row := HBoxContainer.new()
		var name_edit := LineEdit.new()
		name_edit.text = String(field.key)
		name_edit.placeholder_text = "field_name"
		name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var committed := [name_edit.text]
		var apply_name := func(_value := "") -> void:
			var new_key := name_edit.text.strip_edges()
			if new_key == committed[0]: return
			if not new_key.is_valid_identifier() or new_key in ["payload", "_callboard"] or _data.payload_fields.any(func(other: PayloadFieldData) -> bool:
				return other != field and other.event_id == field.event_id and other.key == StringName(new_key)):
				name_edit.text = committed[0]
				return
			field.key = StringName(new_key)
			committed[0] = new_key
			changed.emit(_rule.id)
		name_edit.text_submitted.connect(apply_name)
		name_edit.focus_exited.connect(apply_name)
		row.add_child(name_edit)
		var type_picker := OptionButton.new()
		for type_name in ["bool", "int", "float", "String"]:
			type_picker.add_item(type_name)
		type_picker.select(["bool", "int", "float", "String"].find(field.type_name))
		type_picker.item_selected.connect(func(index: int) -> void:
			field.type_name = ["bool", "int", "float", "String"][index]
			changed.emit(_rule.id))
		row.add_child(type_picker)
		var remove := Button.new()
		remove.text = "×"
		remove.tooltip_text = "Remove payload field"
		remove.pressed.connect(func() -> void:
			_data.payload_fields.erase(field)
			changed.emit(_rule.id)
			_rebuild_later())
		row.add_child(remove)
		section.add_child(row)
	var add := Button.new()
	add.text = "+ Payload field"
	add.disabled = _read_only or _rule.trigger == &"on_change"
	if _rule.trigger == &"on_change":
		add.tooltip_text = "The built-in Blackboard change payload has a fixed field list."
	add.pressed.connect(func() -> void:
		var field := PayloadFieldData.new()
		field.event_id = StringName(_rule.trigger)
		field.key = &"new_field"
		var suffix := 2
		while _data.payload_fields.any(func(other: PayloadFieldData) -> bool: return other.event_id == field.event_id and other.key == field.key):
			field.key = StringName("new_field_%d" % suffix)
			suffix += 1
		_data.payload_fields.append(field)
		changed.emit(_rule.id)
		_rebuild_later())
	section.add_child(add)
	return section

func _guard_menu(field: String) -> Control:
	var mb := MenuButton.new()
	mb.flat = false
	mb.alignment = HORIZONTAL_ALIGNMENT_LEFT
	mb.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var popup := mb.get_popup()
	popup.hide_on_checkable_item_selection = false
	var keys: Array = _data.variables.map(func(v: VariableData) -> String: return String(v.key))
	var initial_guards: PackedStringArray = _rule.get(field)
	for k in initial_guards:   # keep dangling keys visible so they can be unchecked
		if not keys.has(k):
			keys.append(k)
	var refresh_text := func() -> void:
		var guards: PackedStringArray = _rule.get(field)
		mb.text = "%s: %s" % [field.capitalize(), ", ".join(guards) if not guards.is_empty() else "None"]
		mb.tooltip_text = mb.text
	for i in keys.size():
		popup.add_check_item(keys[i])
		popup.set_item_checked(i, initial_guards.has(keys[i]))
	popup.index_pressed.connect(func(i: int) -> void:
		var guards: PackedStringArray = _rule.get(field)
		var on := not popup.is_item_checked(i)
		popup.set_item_checked(i, on)
		if on and not guards.has(keys[i]):
			guards.append(keys[i])
		elif not on:
			var index := guards.find(keys[i])
			if index >= 0:
				guards.remove_at(index)
		_rule.set(field, guards)
		refresh_text.call()
		changed.emit(_rule.id))
	refresh_text.call()
	var section := VBoxContainer.new()
	section.add_child(mb)
	var comparison_row := HBoxContainer.new()
	var comparison_edit := LineEdit.new()
	comparison_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	comparison_edit.placeholder_text = "any(sensor_active, override_enabled) or count >= required"
	comparison_edit.tooltip_text = "Use parentheses, and/or, any(...), comparisons, and has(payload.name) / missing(payload.name). String and StringName keys support == and !=."
	comparison_edit.editable = not _read_only
	comparison_row.add_child(comparison_edit)
	var add_comparison := Button.new()
	add_comparison.text = "Add"
	add_comparison.disabled = _read_only
	add_comparison.pressed.connect(func() -> void:
		var parsed := GuardExpression.parse(comparison_edit.text)
		if not parsed["ok"]:
			comparison_edit.tooltip_text = "Enter a valid guard expression using terms, any(...), and/or, or parentheses."
			return
		var issue := _guard_expression_issue(comparison_edit.text)
		if not issue.is_empty():
			comparison_edit.tooltip_text = issue
			return
		var expression := comparison_edit.text.strip_edges()
		var guards: PackedStringArray = _rule.get(field)
		if not guards.has(expression):
			guards.append(expression)
			_rule.set(field, guards)
			keys.append(expression)
			popup.add_check_item(expression)
			popup.set_item_checked(keys.size() - 1, true)
		refresh_text.call()
		comparison_edit.clear()
		comparison_edit.tooltip_text = "Add a guard using comparisons, any(...), and/or, or parentheses."
		changed.emit(_rule.id))
	comparison_row.add_child(add_comparison)
	section.add_child(comparison_row)
	return section

func _guard_expression_issue(expression: String) -> String:
	var has_payload_schema := _data.payload_fields.any(func(field: PayloadFieldData) -> bool:
		return field.event_id == StringName(_rule.trigger))
	var payload_types := {}
	for field: PayloadFieldData in _data.payload_fields:
		if field.event_id == StringName(_rule.trigger):
			payload_types[field.key] = field.value_type()
	for term: Dictionary in GuardExpression.terms(expression):
		var left_type: int = TYPE_NIL
		if term.get("payload", false):
			if has_payload_schema and not payload_types.has(term["key"]):
				return "Payload field '%s' is not declared for '%s'." % [term["key"], _rule.trigger]
			left_type = payload_types.get(term["key"], TYPE_NIL)
		else:
			left_type = _guard_blackboard_type(term["key"])
		if not term.get("comparison", false):
			continue
		var right_type: int = TYPE_NIL
		if term.has("rhs_key"):
			if term.get("rhs_payload", false):
				if has_payload_schema and not payload_types.has(term["rhs_key"]):
					return "Payload field '%s' is not declared for '%s'." % [term["rhs_key"], _rule.trigger]
				right_type = payload_types.get(term["rhs_key"], TYPE_NIL)
			else:
				right_type = _guard_blackboard_type(term["rhs_key"])
		else:
			right_type = term.get("value_type", TYPE_NIL)
		if not RuleValidator._operand_types_compatible(left_type, right_type, term["operator"]):
			return "This comparison has incompatible operand types or uses an ordering operator on non-numeric values."
	return ""

func _guard_blackboard_type(key: StringName) -> int:
	for variable: VariableData in _data.variables:
		if variable.key == key or variable.aliases.has(key):
			return typeof(variable.default_value) if variable.default_value != null else TYPE_NIL
	return TYPE_NIL

# --- Steps ------------------------------------------------------------------------

func _step_panel(idx: int) -> Control:
	return _step_panel_in(_rule.steps, idx, 0)

func _step_panel_in(steps: Array, idx: int, depth: int) -> Control:
	var step: StepData = steps[idx]
	var verb := VerbCatalog.find(_data.catalog, step.verb)
	var params: Array = verb.get("args", []) if not verb.is_empty() else []
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	var panel := Style.entry(vb)

	var head := HBoxContainer.new()
	var num := Style.label("%02d" % (idx + 1), Style.EVENT, 12)
	head.add_child(num)
	var ob := OptionButton.new()
	var names: Array = _data.catalog.map(func(v: Dictionary) -> String: return v["name"])
	names.append("Parallel group")
	var displayed_verb := String(step.verb)
	if step.verb == &"parallel":
		displayed_verb = "Parallel group"
	elif step.verb == &"conditional":
		displayed_verb = "Conditional branches"
	elif step.verb == &"random":
		displayed_verb = "Random choice"
	names.append("Conditional branches")
	names.append("Random choice")
	if not names.has(displayed_verb):
		names.append(displayed_verb)
	for n in names:
		ob.add_item(n)
	ob.select(names.find(displayed_verb))
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ob.fit_to_longest_item = false
	ob.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	ob.item_selected.connect(func(i: int) -> void:
		var fresh := _new_step_data(names[i])
		step.verb = fresh.verb
		step.args = fresh.args
		step.parallel_branches = fresh.parallel_branches
		step.join_parallel = fresh.join_parallel
		step.branch_conditions = fresh.branch_conditions
		step.default_branch_index = fresh.default_branch_index
		step.group_id = fresh.group_id
		step.random_selection = fresh.random_selection
		step.random_seed = fresh.random_seed
		step.branch_weights = fresh.branch_weights
		changed.emit(_rule.id)
		_rebuild_later())
	head.add_child(ob)
	for offset in [-1, 1]:
		var b := Button.new()
		Style.button_icon(b, &"MoveUp" if offset < 0 else &"MoveDown", "↑" if offset < 0 else "↓")
		b.tooltip_text = "Move step up" if offset < 0 else "Move step down"
		b.accessibility_name = b.tooltip_text
		b.disabled = idx + offset < 0 or idx + offset >= steps.size()
		b.pressed.connect(func() -> void:
			steps.remove_at(idx)
			steps.insert(idx + offset, step)
			changed.emit(_rule.id)
			_rebuild_later())
		head.add_child(b)
	var rm := Button.new()
	Style.button_icon(rm, &"Remove", "✕")
	rm.tooltip_text = "Remove step"
	rm.accessibility_name = rm.tooltip_text
	rm.pressed.connect(func() -> void:
		steps.remove_at(idx)
		changed.emit(_rule.id)
		_rebuild_later())
	head.add_child(rm)
	vb.add_child(head)
	if step.verb == &"parallel":
		vb.add_child(_parallel_panel(step, depth + 1))
	elif step.verb == &"conditional":
		vb.add_child(_conditional_panel(step, depth + 1))
	elif step.verb == &"random":
		vb.add_child(_random_panel(step, depth + 1))

	for j in params.size():
		var row := HBoxContainer.new()
		row.add_child(_name_label(params[j]["name"]))
		var w := _arg_widget(step, j, params[j])
		w.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(w)
		var runtime_sources := _runtime_input_options(step, j, params[j])
		if not runtime_sources.is_empty():
			var source_button := Button.new()
			source_button.text = "Dyn"
			source_button.tooltip_text = "Choose a typed payload or Blackboard input"
			source_button.accessibility_name = "Choose a runtime input for %s" % params[j]["name"]
			row.add_child(source_button)
			var popup := PopupMenu.new()
			for source_index in runtime_sources.size():
				popup.add_item(runtime_sources[source_index]["label"], source_index)
			popup.id_pressed.connect(func(source_index: int) -> void:
				if source_index >= 0 and source_index < runtime_sources.size():
					_set_arg(step, j, runtime_sources[source_index]["expression"])
					_rebuild_later())
			source_button.add_child(popup)
			source_button.pressed.connect(func() -> void:
				popup.position = Vector2i(source_button.get_screen_position()) + Vector2i(0, source_button.size.y)
				popup.popup())
		vb.add_child(row)

	var delay_row := HBoxContainer.new()
	delay_row.add_child(_name_label("Delay (s)"))
	var sp := SpinBox.new()
	sp.min_value = 0.0
	sp.max_value = 60.0
	sp.step = 0.05
	sp.value = step.delay.to_float()
	sp.value_changed.connect(func(v: float) -> void:
		step.delay = "" if v <= 0.0 else str(snappedf(v, 0.01))
		numeric_changed.emit(_rule.id, sp))
	delay_row.add_child(sp)
	vb.add_child(delay_row)
	return panel

func _parallel_panel(step: StepData, depth: int) -> Control:
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 5)
	var join := CheckBox.new()
	join.text = "Wait for every branch"
	join.tooltip_text = "When off, branch work continues under this rule run while the parent sequence advances."
	join.button_pressed = step.join_parallel
	join.toggled.connect(func(value: bool) -> void:
		step.join_parallel = value
		changed.emit(_rule.id))
	container.add_child(join)
	for branch_index in step.parallel_branches.size():
		var branch: Array = step.parallel_branches[branch_index]
		var contents := VBoxContainer.new()
		contents.add_theme_constant_override("separation", 4)
		var header := HBoxContainer.new()
		header.add_child(Style.label("Branch %d" % (branch_index + 1), Style.EVENT, 11))
		for offset in [-1, 1]:
			var move := Button.new()
			move.text = "↑" if offset < 0 else "↓"
			move.tooltip_text = "Move branch up" if offset < 0 else "Move branch down"
			move.disabled = branch_index + offset < 0 or branch_index + offset >= step.parallel_branches.size()
			move.pressed.connect(func() -> void:
				step.parallel_branches.remove_at(branch_index)
				step.parallel_branches.insert(branch_index + offset, branch)
				changed.emit(_rule.id)
				_rebuild_later())
			header.add_child(move)
		var remove := Button.new()
		remove.text = "Remove"
		remove.tooltip_text = "Remove this branch and its steps"
		remove.pressed.connect(func() -> void:
			step.parallel_branches.remove_at(branch_index)
			changed.emit(_rule.id)
			_rebuild_later())
		header.add_child(remove)
		contents.add_child(header)
		for child_index in branch.size():
			contents.add_child(_step_panel_in(branch, child_index, depth))
		contents.add_child(_add_branch_step_menu(branch))
		container.add_child(Style.entry(contents))
	var add_branch := Button.new()
	add_branch.text = "+ Add branch"
	add_branch.pressed.connect(func() -> void:
		step.parallel_branches.append([])
		changed.emit(_rule.id)
		_rebuild_later())
	container.add_child(add_branch)
	return container

func _conditional_panel(step: StepData, depth: int) -> Control:
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 5)
	for branch_index in step.parallel_branches.size():
		var branch: Array = step.parallel_branches[branch_index]
		var branch_contents := VBoxContainer.new()
		branch_contents.add_theme_constant_override("separation", 5)
		var header := HBoxContainer.new()
		header.add_child(Style.label("Branch %d" % (branch_index + 1), Style.EVENT, 11))
		var otherwise := CheckBox.new()
		otherwise.text = "Otherwise"
		otherwise.button_pressed = branch_index == step.default_branch_index
		otherwise.toggled.connect(func(enabled: bool) -> void:
			if enabled:
				step.default_branch_index = branch_index
				while step.branch_conditions.size() < step.parallel_branches.size():
					step.branch_conditions.append(&"")
				step.branch_conditions[branch_index] = &""
			elif step.default_branch_index == branch_index:
				step.default_branch_index = -1
			changed.emit(_rule.id)
			_rebuild_later())
		header.add_child(otherwise)
		var guard := LineEdit.new()
		guard.placeholder_text = "Guard expression"
		guard.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		guard.text = String(step.branch_conditions[branch_index]) if branch_index < step.branch_conditions.size() else ""
		guard.editable = branch_index != step.default_branch_index
		var apply_guard := func(_submitted := "") -> void:
			if branch_index == step.default_branch_index:
				return
			while step.branch_conditions.size() < step.parallel_branches.size():
				step.branch_conditions.append(&"")
			step.branch_conditions[branch_index] = StringName(guard.text.strip_edges())
			changed.emit(_rule.id)
		guard.text_submitted.connect(apply_guard)
		guard.focus_exited.connect(apply_guard)
		header.add_child(guard)
		for offset in [-1, 1]:
			var move := Button.new()
			move.text = "↑" if offset < 0 else "↓"
			move.tooltip_text = "Move branch up" if offset < 0 else "Move branch down"
			move.disabled = branch_index + offset < 0 or branch_index + offset >= step.parallel_branches.size()
			move.pressed.connect(func() -> void:
				_move_conditional_branch(step, branch_index, branch_index + offset)
				changed.emit(_rule.id)
				_rebuild_later())
			header.add_child(move)
		var remove := Button.new()
		remove.text = "Remove"
		remove.tooltip_text = "Remove this branch and its steps"
		remove.pressed.connect(func() -> void:
			step.parallel_branches.remove_at(branch_index)
			if branch_index < step.branch_conditions.size():
				step.branch_conditions.remove_at(branch_index)
			if step.default_branch_index == branch_index:
				step.default_branch_index = -1
			elif step.default_branch_index > branch_index:
				step.default_branch_index -= 1
			changed.emit(_rule.id)
			_rebuild_later())
		header.add_child(remove)
		branch_contents.add_child(header)
		for child_index in branch.size():
			branch_contents.add_child(_step_panel_in(branch, child_index, depth))
		branch_contents.add_child(_add_branch_step_menu(branch))
		container.add_child(Style.entry(branch_contents))
	var add_branch := Button.new()
	add_branch.text = "+ Add condition"
	add_branch.tooltip_text = "Add a guarded branch before the Otherwise branch."
	add_branch.pressed.connect(func() -> void:
		var insert_at := step.default_branch_index if step.default_branch_index >= 0 else step.parallel_branches.size()
		step.parallel_branches.insert(insert_at, [])
		step.branch_conditions.insert(insert_at, &"")
		if step.default_branch_index >= insert_at:
			step.default_branch_index += 1
		changed.emit(_rule.id)
		_rebuild_later())
	container.add_child(add_branch)
	return container

func _random_panel(step: StepData, depth: int) -> Control:
	var container := VBoxContainer.new()
	container.add_theme_constant_override("separation", 5)
	var settings := HBoxContainer.new()
	settings.add_child(Style.label("Selection", Style.EVENT, 11))
	var mode := OptionButton.new()
	mode.add_item("Uniform", 0)
	mode.add_item("Weighted", 1)
	mode.select(step.random_selection)
	mode.item_selected.connect(func(index: int) -> void:
		step.random_selection = index
		while step.branch_weights.size() < step.parallel_branches.size():
			step.branch_weights.append(1.0)
		changed.emit(_rule.id)
		_rebuild_later())
	settings.add_child(mode)
	settings.add_child(Style.label("Seed", Style.EVENT, 11))
	var seed := SpinBox.new()
	seed.min_value = -2147483648.0
	seed.max_value = 2147483647.0
	seed.step = 1.0
	seed.value = step.random_seed
	seed.value_changed.connect(func(value: float) -> void:
		step.random_seed = int(value)
		changed.emit(_rule.id))
	settings.add_child(seed)
	container.add_child(settings)
	container.add_child(Style.label("A seeded choice is repeatable. Managed Stages save each group's random stream across reloads.", Style.MUTED, 10))
	for branch_index in step.parallel_branches.size():
		var branch: Array = step.parallel_branches[branch_index]
		var contents := VBoxContainer.new()
		contents.add_theme_constant_override("separation", 4)
		var header := HBoxContainer.new()
		header.add_child(Style.label("Branch %d" % (branch_index + 1), Style.EVENT, 11))
		if step.random_selection == 1:
			while step.branch_weights.size() <= branch_index:
				step.branch_weights.append(1.0)
			var weight := SpinBox.new()
			weight.min_value = 0.0
			weight.max_value = 1000000.0
			weight.step = 0.1
			weight.value = step.branch_weights[branch_index]
			weight.tooltip_text = "Relative chance for this branch; zero disables it."
			weight.value_changed.connect(func(value: float) -> void:
				step.branch_weights[branch_index] = value
				changed.emit(_rule.id))
			header.add_child(Style.label("Weight", Style.MUTED, 10))
			header.add_child(weight)
		for offset in [-1, 1]:
			var move := Button.new()
			move.text = "↑" if offset < 0 else "↓"
			move.tooltip_text = "Move branch up" if offset < 0 else "Move branch down"
			move.disabled = branch_index + offset < 0 or branch_index + offset >= step.parallel_branches.size()
			move.pressed.connect(func() -> void:
				var moved: Array = step.parallel_branches[branch_index]
				step.parallel_branches.remove_at(branch_index)
				step.parallel_branches.insert(branch_index + offset, moved)
				if branch_index < step.branch_weights.size():
					var moved_weight := step.branch_weights[branch_index]
					step.branch_weights.remove_at(branch_index)
					step.branch_weights.insert(branch_index + offset, moved_weight)
				changed.emit(_rule.id)
				_rebuild_later())
			header.add_child(move)
		var remove := Button.new()
		remove.text = "Remove"
		remove.pressed.connect(func() -> void:
			step.parallel_branches.remove_at(branch_index)
			if branch_index < step.branch_weights.size():
				step.branch_weights.remove_at(branch_index)
			changed.emit(_rule.id)
			_rebuild_later())
		header.add_child(remove)
		contents.add_child(header)
		for child_index in branch.size():
			contents.add_child(_step_panel_in(branch, child_index, depth))
		contents.add_child(_add_branch_step_menu(branch))
		container.add_child(Style.entry(contents))
	var add_branch := Button.new()
	add_branch.text = "+ Add branch"
	add_branch.pressed.connect(func() -> void:
		step.parallel_branches.append([])
		step.branch_weights.append(1.0)
		changed.emit(_rule.id)
		_rebuild_later())
	container.add_child(add_branch)
	return container

func _move_conditional_branch(step: StepData, from: int, to: int) -> void:
	var branch: Array = step.parallel_branches[from]
	step.parallel_branches.remove_at(from)
	step.parallel_branches.insert(to, branch)
	while step.branch_conditions.size() < step.parallel_branches.size():
		step.branch_conditions.append(&"")
	var condition: StringName = step.branch_conditions[from]
	step.branch_conditions.remove_at(from)
	step.branch_conditions.insert(to, condition)
	if step.default_branch_index == from:
		step.default_branch_index = to
	elif from < step.default_branch_index and to >= step.default_branch_index:
		step.default_branch_index -= 1
	elif from > step.default_branch_index and to <= step.default_branch_index:
		step.default_branch_index += 1

func _add_branch_step_menu(steps: Array) -> Control:
	var add := MenuButton.new()
	add.text = "+ Add branch step"
	add.flat = false
	var verbs: Array = _data.catalog.map(func(v: Dictionary) -> String: return v["name"])
	verbs.append("Parallel group")
	verbs.append("Conditional branches")
	verbs.append("Random choice")
	for verb_name in verbs:
		add.get_popup().add_item(verb_name)
	add.get_popup().index_pressed.connect(func(index: int) -> void:
		steps.append(_new_step_data(verbs[index]))
		changed.emit(_rule.id)
		_rebuild_later())
	return add

func _new_step_data(verb_name: String) -> StepData:
	if verb_name == "Parallel group":
		var step := StepData.new()
		step.verb = &"parallel"
		return step
	if verb_name == "Conditional branches":
		var step := StepData.new()
		step.verb = &"conditional"
		step.parallel_branches = [[]]
		step.branch_conditions = [&""]
		step.default_branch_index = 0
		return step
	if verb_name == "Random choice":
		var step := StepData.new()
		step.verb = &"random"
		step.group_id = StringName(str(ResourceUID.create_id()))
		step.parallel_branches = [[], []]
		step.branch_weights = PackedFloat32Array([1.0, 1.0])
		return step
	return VerbCatalog.new_step(_data, verb_name)

func _current(step: StepData, i: int, param: Dictionary) -> String:
	if i < step.args.size():
		return step.args[i]
	return param["default"] if param["default"] != "" else VerbCatalog.fallback(param, _data)

## Writes `expr` into argument i, filling any skipped earlier optional arguments with defaults.
func _set_arg(step: StepData, i: int, expr: String, spin: SpinBox = null) -> void:
	VerbCatalog.set_arg(_data, step, i, expr)
	if spin:
		numeric_changed.emit(_rule.id, spin)
	else:
		changed.emit(_rule.id)

func _selected_add_var_target(step: StepData) -> VariableData:
	if step.args.is_empty():
		return null
	var target_literal := ExprText.parse_literal(step.args[0])
	if not target_literal["ok"] or typeof(target_literal["value"]) != TYPE_STRING_NAME:
		return null
	for variable: VariableData in _data.variables:
		if variable.key == target_literal["value"]:
			return variable
	return null

func _arg_widget(step: StepData, i: int, param: Dictionary) -> Control:
	var cur := _current(step, i, param)
	var lit := ExprText.parse_literal(cur)
	match param["type"]:
		TYPE_OBJECT:
			var ob := OptionButton.new()
			var names: Array = []
			for p in _data.props:
				if VerbCatalog.prop_fits(p["class"], param["class"]):
					names.append(p["name"])
			if not names.has(cur):
				names.append(cur)   # unknown / unset: stays visible, and is flagged by the validator
			for n in names:
				ob.add_item(n)
			ob.select(names.find(cur))
			ob.item_selected.connect(func(k: int) -> void: _set_arg(step, i, names[k]))
			return ob
		TYPE_BOOL:
			if lit["ok"] and typeof(lit["value"]) == TYPE_BOOL:
				var c := CheckBox.new()
				c.button_pressed = lit["value"]
				c.toggled.connect(func(on: bool) -> void: _set_arg(step, i, "true" if on else "false"))
				return c
		TYPE_INT, TYPE_FLOAT:
			if lit["ok"] and typeof(lit["value"]) in [TYPE_INT, TYPE_FLOAT]:
				var s := SpinBox.new()
				s.allow_greater = true
				s.allow_lesser = true
				var integer_delta: bool = param["type"] == TYPE_INT
				if step.verb == &"add_var" and param["name"] == "delta":
					var target := _selected_add_var_target(step)
					integer_delta = target != null and typeof(target.default_value) == TYPE_INT
				s.step = 1.0 if integer_delta else 0.05
				s.value = float(lit["value"])
				s.value_changed.connect(func(v: float) -> void:
					_set_arg(step, i, str(int(v)) if integer_delta else ExprText.format_literal(snappedf(v, 0.001)), s))
				return s
		TYPE_STRING:
			if lit["ok"] and typeof(lit["value"]) == TYPE_STRING:
				return _text_arg(step, i, String(lit["value"]), func(t: String) -> String: return ExprText.format_literal(t))
		TYPE_STRING_NAME:
			if param["name"] == "key":
				var ob := OptionButton.new()
				var keys: Array[String] = []
				for variable: VariableData in _data.variables:
					if step.verb == &"add_var" and typeof(variable.default_value) not in [TYPE_INT, TYPE_FLOAT]:
						continue
					if step.verb == &"toggle_var" and typeof(variable.default_value) != TYPE_BOOL:
						continue
					keys.append(String(variable.key))
				var cur_key: String = String(lit["value"]) if lit["ok"] else ""
				if not keys.has(cur_key):
					keys.append(cur_key)
				for k in keys:
					ob.add_item(k)
				ob.select(keys.find(cur_key))
				ob.item_selected.connect(func(k: int) -> void: _set_arg(step, i, '&"%s"' % keys[k]))
				return ob
			if lit["ok"]:
				return _text_arg(step, i, String(lit["value"]), func(t: String) -> String: return ExprText.format_literal(StringName(t)))
	# Anything else (Vector3, constants, expressions): edit the raw GDScript expression.
	var raw := LineEdit.new()
	raw.text = cur
	if step.verb == &"emit_relay" and param["name"] == "field_map":
		raw.tooltip_text = "Dictionary mapping output fields to input fields, e.g. {\"result\": \"action\"}. Use {} to forward the full payload."
	else:
		raw.tooltip_text = "GDScript expression, e.g. a constant or Vector3(0, 1, 0)"
	var shown := [cur]
	var apply := func(_t := "") -> void:
		var expr := raw.text.strip_edges()
		if expr != shown[0]:
			shown[0] = expr
			_set_arg(step, i, expr)
	raw.text_submitted.connect(apply)
	raw.focus_exited.connect(apply)
	return raw

func _runtime_input_options(step: StepData, index: int, param: Dictionary) -> Array[Dictionary]:
	var options: Array[Dictionary] = []
	var supported := ((step.verb in [&"set_var", &"add_var", &"say"] and index == 1)
		or (step.verb == &"say_key" and index in [1, 2])
		or (step.verb == &"score" and index == 0)
		or (step.verb in [&"gameplay_event", &"emit_relay"] and index == 1))
	if not supported:
		return options
	var sources: Array[Dictionary] = []
	for field: PayloadFieldData in _data.payload_fields:
		if field.event_id == _rule.trigger:
			sources.append({"label": "payload.%s" % field.key, "key": field.key,
				"type": field.value_type(), "source": "payload"})
	for variable: VariableData in _data.variables:
		sources.append({"label": "Blackboard.%s" % variable.key, "key": variable.key,
			"type": typeof(variable.default_value), "source": "blackboard"})
	for writer: BlackboardWriterData in _data.external_writers:
		var writer_type := _writer_value_type(writer.value_type)
		if writer_type != TYPE_NIL:
			sources.append({"label": "Blackboard.%s" % writer.key, "key": writer.key,
				"type": writer_type, "source": "blackboard"})
	if param["type"] == TYPE_DICTIONARY:
		if step.verb in [&"gameplay_event", &"say_key"] and index == (1 if step.verb == &"gameplay_event" else 2):
			for source: Dictionary in sources:
				if source["type"] == TYPE_DICTIONARY:
					_add_runtime_input_option(options, source["label"], source, param["type"])
				elif source["type"] != TYPE_NIL:
					var key := String(source["key"])
					var expression := "{\"%s\": %s(&\"%s\")}" % [key,
						"callboard_payload" if source["source"] == "payload" else "callboard_blackboard", key]
					options.append({"label": "Request field %s" % source["label"], "expression": expression})
		elif step.verb == &"emit_relay" and index == 1:
			var relay_name := ""
			if not step.args.is_empty():
				var parsed_relay := ExprText.parse_literal(step.args[0])
				if parsed_relay.ok:
					relay_name = String(parsed_relay.value)
			var outputs: Array[PayloadFieldData] = []
			for field: PayloadFieldData in _data.payload_fields:
				if field.event_id == StringName("relay:" + relay_name):
					outputs.append(field)
			for output: PayloadFieldData in outputs:
				for source: Dictionary in sources:
					if _input_types_compatible(source["type"], output.value_type()):
						var expression := "{\"%s\": %s(&\"%s\")}" % [output.key,
						"callboard_payload" if source["source"] == "payload" else "callboard_blackboard", source["key"]]
						options.append({"label": "%s <- %s" % [output.key, source["label"]], "expression": expression})
		return options
	var expected_type: int = param["type"]
	if step.verb == &"set_var" and index == 1 and not step.args.is_empty():
		var target := ExprText.parse_literal(step.args[0])
		if target.ok and target.value is StringName:
			expected_type = _blackboard_type(target.value)
	if step.verb == &"add_var" and index == 1:
		expected_type = TYPE_INT if not step.args.is_empty() and _blackboard_type_from_arg(step.args[0]) == TYPE_INT else TYPE_FLOAT
	for source: Dictionary in sources:
		if _input_types_compatible(source["type"], expected_type):
			_add_runtime_input_option(options, source["label"], source, expected_type)
	return options

func _add_runtime_input_option(options: Array[Dictionary], label: String,
		source: Dictionary, _expected_type: int) -> void:
	var helper := "callboard_payload" if source["source"] == "payload" else "callboard_blackboard"
	options.append({"label": label, "expression": "%s(&\"%s\")" % [helper, source["key"]]})

func _input_types_compatible(source_type: int, target_type: int) -> bool:
	return (target_type == TYPE_NIL or source_type == target_type
		or (target_type == TYPE_FLOAT and source_type == TYPE_INT))

func _blackboard_type(key: StringName) -> int:
	for variable: VariableData in _data.variables:
		if variable.key == key or variable.aliases.has(key):
			return typeof(variable.default_value)
	for writer: BlackboardWriterData in _data.external_writers:
		if writer.key == key:
			return _writer_value_type(writer.value_type)
	return TYPE_NIL

func _blackboard_type_from_arg(expression: String) -> int:
	var key := ExprText.parse_literal(expression)
	return _blackboard_type(key.value) if key.ok and key.value is StringName else TYPE_NIL

func _writer_value_type(type_name: String) -> int:
	match type_name:
		"bool": return TYPE_BOOL
		"int": return TYPE_INT
		"float": return TYPE_FLOAT
		"String": return TYPE_STRING
		"StringName": return TYPE_STRING_NAME
		_: return TYPE_NIL

func _text_arg(step: StepData, i: int, text: String, to_expr: Callable) -> Control:
	var e := LineEdit.new()
	e.text = text
	var shown := [to_expr.call(text)]
	var apply := func(_t := "") -> void:
		var expr: String = to_expr.call(e.text)
		if expr != shown[0]:
			shown[0] = expr
			_set_arg(step, i, expr)
	e.text_submitted.connect(apply)
	e.focus_exited.connect(apply)
	return e

func _rename_group(edit: LineEdit) -> void:
	var new_name := edit.text.strip_edges()
	if new_name == _group.name:
		return
	var taken: bool = _data.groups.any(func(g: GroupData) -> bool: return g.name == new_name)
	if new_name == "" or taken or '"' in new_name:
		edit.text = _group.name
		return
	for rd in _data.rules:
		if rd.group == _group.name:
			rd.group = new_name
	_group.name = new_name
	group_edited.emit(new_name)

func _lock(node: Node) -> void:
	for c in node.get_children():
		if c is BaseButton:
			(c as BaseButton).disabled = true
		elif c is LineEdit:
			(c as LineEdit).editable = false
		elif c is SpinBox:
			(c as SpinBox).editable = false
		elif c is MenuButton:
			(c as MenuButton).disabled = true
		_lock(c)
