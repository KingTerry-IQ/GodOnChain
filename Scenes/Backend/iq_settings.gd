## The key vault UI: an unlock screen and a keys screen.
##
## These used to live in the wrapper repo's .env file in plaintext. Now they
## are held in an encrypted vault under user://, opened with a master password
## the user chooses, and handed to the sidecar process at spawn.
##
## Both screens are full-screen Panel overlays built in code, matching the
## prompts already in browser_ui.tscn, so they pick up iq_theme.tres from the
## root Control and the main scene does not have to carry them.

class_name IQSettings
extends Node

## Keys were saved. The sidecar reads them at spawn, so it needs a restart.
signal settings_saved
## The unlock screen was resolved, either way.
signal unlock_finished(unlocked: bool)

const FIELDS := [
	{
		"key": "SOLANA_RPC_URL",
		"label": "SOL RPC URL:",
		"hint": "blank = https://api.mainnet-beta.solana.com",
	},
	{
		"key": "SOLANA_SIGNER_PRIVATE_KEY",
		"label": "SOL signer key:",
		"hint": "base58. Needed only to inscribe on SOL.",
	},
	{
		"key": "MONAD_RPC_URL",
		"label": "MON RPC URL:",
		"hint": "blank = https://rpc.monad.xyz",
	},
	{
		"key": "MON_SIGNER_PRIVATE_KEY",
		"label": "MON signer key:",
		"hint": "0x-prefixed hex. Needed only to inscribe on MON.",
	},
	{
		"key": "HANLOCK_PASS",
		"label": "HanLock pass:",
		"hint": "Used by the HanLock encryption option.",
	},
]

const LABEL_WIDTH := 260
const PANEL_WIDTH := 1000
const UNLOCK_WIDTH := 720

var host: IQHost

var _keys_panel: Panel
var _unlock_panel: Panel
var _inputs: Dictionary = {}
var _reveal: CheckBox
var _keys_status: Label
var _master_input: LineEdit
var _confirm_input: LineEdit
var _master_row_label: Label
var _unlock_input: LineEdit
var _unlock_status: Label
var _open_button: Button
## Remembered only so "leave blank to keep your password" can re-encrypt.
var _session_password: String = ""


func _init(iq_host: IQHost = null) -> void:
	host = iq_host


## Builds the overlays and the button that opens them. `root` is the themed
## Control they live under, so everything inherits iq_theme.tres.
func attach(root: Control) -> void:
	if host == null:
		push_error("IQSettings needs an IQHost.")
		return
	_build_keys_panel(root)
	_build_unlock_panel(root)
	_build_open_button(root)


## True when a vault exists but has not been opened this session.
func needs_unlock() -> bool:
	return host.vault_exists() and not host.is_unlocked


## True when no keys have ever been saved on this machine.
func is_unconfigured() -> bool:
	return not host.vault_exists()


#region Shared construction

## Full-screen overlay matching the AddBookmark / FolderPrompt prompts.
func _make_overlay(root: Control, width: int) -> VBoxContainer:
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
		margin.add_theme_constant_override("margin_" + side, 10)
	panel.add_child(margin)

	var center := CenterContainer.new()
	margin.add_child(center)

	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(width, 0)
	box.add_theme_constant_override("separation", 20)
	center.add_child(box)

	root.add_child(panel)
	# Remembered on the container so callers can show/hide the whole overlay.
	box.set_meta("panel", panel)
	return box


func _make_title(text: String) -> Label:
	var title := Label.new()
	title.text = text
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return title


func _make_note(text: String) -> Label:
	var note := Label.new()
	note.text = text
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.modulate = Color(0, 1, 0, 0.6)
	return note


## Label + masked LineEdit on one row, as elsewhere in the app.
func _make_row(parent: VBoxContainer, label_text: String, placeholder: String) -> LineEdit:
	var row := HBoxContainer.new()

	var label := Label.new()
	label.text = label_text
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	row.add_child(label)

	var input := LineEdit.new()
	input.secret = true
	input.placeholder_text = placeholder
	input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(input)

	parent.add_child(row)
	return input

#endregion


#region Keys screen

func _build_keys_panel(root: Control) -> void:
	var box := _make_overlay(root, PANEL_WIDTH)
	_keys_panel = box.get_meta("panel")

	box.add_child(_make_title("— KEYS —"))
	box.add_child(
		_make_note(
			(
				"Held by GodOnChain and passed to the local on-chain service. "
				+ "Stored encrypted on this machine, never sent anywhere else. "
				+ "Apps you launch never see them: they ask, and you approve."
			)
		)
	)
	box.add_child(HSeparator.new())

	for field: Dictionary in FIELDS:
		_inputs[str(field["key"])] = _make_row(
			box, str(field["label"]), str(field["hint"])
		)

	box.add_child(HSeparator.new())

	_master_row_label = _make_note("")
	box.add_child(_master_row_label)
	_master_input = _make_row(box, "Master password:", "unlocks these keys")
	_confirm_input = _make_row(box, "Confirm password:", "type it again")

	_keys_status = Label.new()
	_keys_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_keys_status)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)

	_reveal = CheckBox.new()
	_reveal.text = "Reveal"
	_reveal.toggled.connect(_on_reveal_toggled)
	buttons.add_child(_reveal)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(spacer)

	var save := Button.new()
	save.text = "Save"
	save.pressed.connect(_on_save_pressed)
	buttons.add_child(save)

	var cancel := Button.new()
	cancel.text = "Cancel"
	cancel.pressed.connect(_on_cancel_pressed)
	buttons.add_child(cancel)

	box.add_child(buttons)


func _build_open_button(root: Control) -> void:
	_open_button = Button.new()
	_open_button.text = "KEYS"
	_open_button.tooltip_text = "Signing keys and RPC endpoints for the on-chain service"
	_open_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_open_button.offset_left = -104
	_open_button.offset_top = 8
	_open_button.offset_right = -12
	_open_button.offset_bottom = 34
	_open_button.pressed.connect(open)
	root.add_child(_open_button)


## Shows the keys screen, prefilled with whatever is currently unlocked.
func open() -> void:
	for key: String in _inputs:
		(_inputs[key] as LineEdit).text = str(host.secrets.get(key, ""))
	_master_input.text = ""
	_confirm_input.text = ""
	_keys_status.text = ""

	if host.vault_exists() and not host.is_unlocked:
		# Saving now would silently replace keys we cannot read.
		_master_row_label.text = (
			"The vault is locked. Enter your master password to replace the stored keys."
		)
	elif host.vault_exists():
		_master_row_label.text = "Leave blank to keep your current master password."
	else:
		_master_row_label.text = "Choose a master password. It encrypts these keys on disk."

	_reveal.button_pressed = false
	_on_reveal_toggled(false)
	_keys_panel.show()


func _on_reveal_toggled(pressed: bool) -> void:
	for key: String in _inputs:
		(_inputs[key] as LineEdit).secret = not pressed


func _on_cancel_pressed() -> void:
	_clear_inputs()
	_keys_panel.hide()


func _on_save_pressed() -> void:
	var password := _master_input.text
	var confirm := _confirm_input.text

	# Blank keeps the existing password, but only once we can prove we know it.
	if password.is_empty():
		if not host.vault_exists():
			_keys_status.text = "Choose a master password first."
			return
		if not host.is_unlocked:
			_keys_status.text = "Enter your master password to replace the stored keys."
			return
	elif password != confirm:
		_keys_status.text = "The two passwords do not match."
		return
	elif password.length() < 8:
		_keys_status.text = "Use at least 8 characters."
		return

	for key: String in _inputs:
		host.secrets[key] = (_inputs[key] as LineEdit).text.strip_edges()

	_keys_status.text = "Encrypting..."
	# Let the label paint before the key derivation blocks the frame.
	await get_tree().process_frame

	var effective := password
	if effective.is_empty():
		effective = _session_password

	if not host.save_secrets(effective):
		_keys_status.text = host.last_error
		return

	_session_password = effective
	_clear_inputs()
	_keys_panel.hide()
	settings_saved.emit()

#endregion


#region Unlock screen

func _build_unlock_panel(root: Control) -> void:
	var box := _make_overlay(root, UNLOCK_WIDTH)
	_unlock_panel = box.get_meta("panel")

	box.add_child(_make_title("— LOCKED —"))
	box.add_child(
		_make_note(
			(
				"Your signing keys are encrypted on this machine. "
				+ "Unlock them to inscribe. Reading on-chain data works either way."
			)
		)
	)
	box.add_child(HSeparator.new())

	_unlock_input = _make_row(box, "Master password:", "")
	_unlock_input.text_submitted.connect(func(_t: String) -> void: _on_unlock_pressed())

	_unlock_status = Label.new()
	_unlock_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_unlock_status)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.add_child(spacer)

	var unlock := Button.new()
	unlock.text = "Unlock"
	unlock.pressed.connect(_on_unlock_pressed)
	buttons.add_child(unlock)

	var skip := Button.new()
	skip.text = "Read-only"
	skip.pressed.connect(_on_skip_pressed)
	buttons.add_child(skip)

	box.add_child(buttons)


## Shows the unlock screen and returns once the user has resolved it.
func prompt_unlock() -> bool:
	_unlock_input.text = ""
	_unlock_status.text = ""
	_unlock_panel.show()
	_unlock_input.grab_focus()
	return await unlock_finished


func _on_unlock_pressed() -> void:
	_unlock_status.text = "Unlocking..."
	# Key derivation blocks the frame; let the label show first.
	await get_tree().process_frame

	if not host.unlock(_unlock_input.text):
		_unlock_status.text = host.last_error
		_unlock_input.text = ""
		_unlock_input.grab_focus()
		return

	_session_password = _unlock_input.text
	_unlock_input.text = ""
	_unlock_panel.hide()
	unlock_finished.emit(true)


func _on_skip_pressed() -> void:
	_unlock_input.text = ""
	_unlock_panel.hide()
	unlock_finished.emit(false)

#endregion


func _clear_inputs() -> void:
	for key: String in _inputs:
		(_inputs[key] as LineEdit).text = ""
	_master_input.text = ""
	_confirm_input.text = ""
