## Builders for the full-screen prompt overlays used by the on-chain UI.
##
## browser_ui.tscn already prompts this way — AddBookmark, FolderPrompt,
## MovePrompt — so the screens added in code (keys, unlock, write approval)
## are assembled the same shape here rather than each rolling its own. They
## are plain Controls under the themed root, so iq_theme.tres applies without
## any per-node styling.

class_name IQOverlay
extends RefCounted

const MARGIN := 10
const SEPARATION := 20
const LABEL_WIDTH := 260


## Builds a hidden full-screen Panel under `root` and returns the VBox to fill.
## The Panel itself is on the returned box's "panel" meta, for show()/hide().
static func make(root: Control, width: int) -> VBoxContainer:
	var panel := Panel.new()
	panel.visible = false
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	panel.anchor_right = 1.0
	panel.anchor_bottom = 1.0
	panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	panel.grow_vertical = Control.GROW_DIRECTION_BOTH

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.anchor_right = 1.0
	margin.anchor_bottom = 1.0
	for side: String in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, MARGIN)
	panel.add_child(margin)

	var center := CenterContainer.new()
	margin.add_child(center)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(width, 0)
	box.add_theme_constant_override("separation", SEPARATION)
	center.add_child(box)

	root.add_child(panel)
	box.set_meta("panel", panel)
	return box


## Centred heading, in the "— VIEWER —" style the app already uses.
static func title(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return label


## Dimmed explanatory text.
static func note(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.modulate = Color(0, 1, 0, 0.6)
	return label


## Full-brightness body text, for things the user must actually read.
static func body(text: String = "") -> Label:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	return label


## Label + LineEdit on one row, matching the prompts in browser_ui.tscn.
static func row(
	parent: VBoxContainer, label_text: String, placeholder: String, masked: bool = true
) -> LineEdit:
	var line := HBoxContainer.new()

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	line.add_child(label)

	var input := LineEdit.new()
	input.secret = masked
	input.placeholder_text = placeholder
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(input)

	parent.add_child(line)
	return input


## Right-aligned button strip. Returns the row so extra controls can be
## prepended on the left.
static func buttons(parent: VBoxContainer) -> HBoxContainer:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 10)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.name = "Spacer"
	line.add_child(spacer)

	parent.add_child(line)
	return line


## Appends a button to a strip built by buttons().
static func button(strip: HBoxContainer, text: String, on_pressed: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(on_pressed)
	strip.add_child(b)
	return b
