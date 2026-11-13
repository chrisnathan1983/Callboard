@tool
extends RefCounted

const SURFACE := Color("#171f2b")
const BORDER := Color("#324256")
const TEXT := Color("#e2ebf5")
const MUTED := Color("#a5b6ca")
const EVENT := Color("#79d9eb")
const RELAY := Color("#f1bd7e")
const SUCCESS := Color("#9adab5")
const WARNING := Color("#ffc888")
const ERROR := Color("#f1a4aa")
const LIST_WIDTH := 260
const ENTRY_GAP := 10
const EDITOR_COLORS := {
	TEXT: &"font_color",
	MUTED: &"font_disabled_color",
	EVENT: &"accent_color",
	RELAY: &"warning_color",
	SUCCESS: &"success_color",
	WARNING: &"warning_color",
	ERROR: &"error_color",
}

static func resolve_color(control: Control, fallback: Color) -> Color:
	var role: StringName = EDITOR_COLORS.get(fallback, &"")
	if Engine.is_editor_hint() and role != &"" and control.has_theme_color(role, &"Editor"):
		return control.get_theme_color(role, &"Editor")
	return fallback

static func tint(control: Control, fallback: Color) -> void:
	if Engine.is_editor_hint() and not control.has_meta(&"_board_tint"):
		control.theme_changed.connect(_refresh_tint_from_ref.bind(weakref(control)), CONNECT_DEFERRED)
	control.set_meta(&"_board_tint", fallback)
	_refresh_tint(control)

static func _refresh_tint_from_ref(control_ref: WeakRef) -> void:
	var control := control_ref.get_ref() as Control
	if control != null:
		_refresh_tint(control)

static func button_icon(button: Button, icon_name: StringName, fallback: String, keep_text := false) -> void:
	if not keep_text:
		button.text = fallback
	if not Engine.is_editor_hint():
		return
	var refresh := _refresh_button_icon.bind(weakref(button), icon_name, fallback, keep_text)
	button.ready.connect(refresh)
	button.theme_changed.connect(refresh, CONNECT_DEFERRED)

static func _refresh_button_icon(button_ref: WeakRef, icon_name: StringName, fallback: String, keep_text: bool) -> void:
	var button := button_ref.get_ref() as Button
	if button == null:
		return
	button.icon = button.get_theme_icon(icon_name, &"EditorIcons") if button.has_theme_icon(icon_name, &"EditorIcons") else null
	if not keep_text:
		button.text = "" if button.icon != null else fallback

static func _refresh_tint(control: Control) -> void:
	var color := resolve_color(control, control.get_meta(&"_board_tint"))
	if control.get_theme_color(&"font_color") != color:
		control.add_theme_color_override(&"font_color", color)

static func fallback_font_size(control: Control, font_size: int) -> void:
	if not Engine.is_editor_hint():
		control.add_theme_font_size_override(&"font_size", font_size)

static func surface(fill: Color, border: Color, padding := Vector2(12, 8), radius := 8) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = padding.x
	style.content_margin_right = padding.x
	style.content_margin_top = padding.y
	style.content_margin_bottom = padding.y
	return style

static func label(text: String, color := TEXT, font_size := 14) -> Label:
	var control := Label.new()
	control.text = text
	tint(control, color)
	fallback_font_size(control, font_size)
	return control

static func panel(content: Control, fill := SURFACE, padding := Vector2(12, 10), opaque := false) -> PanelContainer:
	var control := PanelContainer.new()
	var control_ref := weakref(control)
	var refresh := _refresh_panel_from_ref.bind(control_ref, opaque, padding)
	control.theme_changed.connect(refresh, CONNECT_DEFERRED)
	control.ready.connect(refresh)
	control.add_child(content)
	return control

static func entry(content: Control) -> PanelContainer:
	var control := PanelContainer.new()
	control.add_child(content)
	var control_ref := weakref(control)
	var refresh := _refresh_entry_from_ref.bind(control_ref)
	control.theme_changed.connect(refresh, CONNECT_DEFERRED)
	control.ready.connect(refresh)
	return control

static func _refresh_entry_from_ref(control_ref: WeakRef) -> void:
	var control := control_ref.get_ref() as PanelContainer
	if control != null:
		_refresh_entry(control)

static func _refresh_panel_from_ref(control_ref: WeakRef, opaque: bool, padding: Vector2) -> void:
	var control := control_ref.get_ref() as PanelContainer
	if control != null:
		_refresh_panel(control, opaque, padding)

static func _refresh_entry(control: PanelContainer) -> void:
	var fill := SURFACE
	var toolbar := control.get_theme_stylebox(&"menu_panel", &"GraphEdit") as StyleBoxFlat
	if toolbar != null:
		fill = toolbar.bg_color
	fill.a = 1.0
	var text := resolve_color(control, TEXT)
	var border := fill.lerp(text, 0.26)
	fill = fill.lerp(text, 0.08)
	var scale := control.get_theme_default_base_scale()
	var current := control.get_theme_stylebox(&"panel") as StyleBoxFlat
	if current != null and current.bg_color == fill and current.border_color == border and current.content_margin_left == 9 * scale:
		return
	control.add_theme_stylebox_override(&"panel", surface(fill, border, Vector2(9, 8) * scale, roundi(6 * scale)))

static func _refresh_panel(control: PanelContainer, opaque: bool, padding: Vector2) -> void:
	# Use the same native surface family as Godot's floating graph toolbar in both
	# the editor and the live game view.
	var panel_style := control.get_theme_stylebox(&"menu_panel", &"GraphEdit")
	if not opaque:
		if control.get_theme_stylebox(&"panel") != panel_style:
			control.add_theme_stylebox_override(&"panel", panel_style)
		return
	var native_flat := panel_style as StyleBoxFlat
	var fill := SURFACE
	if native_flat != null:
		fill = native_flat.bg_color
	elif Engine.is_editor_hint() and control.has_theme_color(&"base_color", &"Editor"):
		fill = control.get_theme_color(&"base_color", &"Editor")
	fill.a = 1.0
	var current := control.get_theme_stylebox(&"panel") as StyleBoxFlat
	if current == null or current.bg_color != fill or not control.has_meta(&"_board_panel_source") or control.get_meta(&"_board_panel_source") != panel_style:
		var solid := native_flat.duplicate() as StyleBoxFlat if native_flat != null else surface(fill, BORDER, padding)
		solid.bg_color = fill
		solid.draw_center = true
		control.set_meta(&"_board_panel_source", panel_style)
		control.add_theme_stylebox_override(&"panel", solid)
