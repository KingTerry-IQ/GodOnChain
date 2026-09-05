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

## Grouped by what each is for, because the honest answer to "which of these do
## I need" is "it depends what you are doing" — and a flat list of five secrets
## makes that look like five requirements.
##
## The qualifier lives in the heading rather than a paragraph beneath it. Each
## group needs one sentence, and a separate note per group cost three more rows
## of a panel that has to fit on screen without scrolling.
const FIELD_GROUPS := [
	{
		"heading": (
			"ENDPOINTS — optional, but recommended. Blank uses shared public ones, "
			+ "which stall under load rather than failing outright. A free Helius "
			+ "or Alchemy tier is plenty."
		),
		"fields": [
			{
				"key": "SOLANA_RPC_URL",
				"label": "SOL RPC URL:",
				"hint": "blank = api.mainnet-beta.solana.com",
			},
			{
				"key": "MONAD_RPC_URL",
				"label": "MON RPC URL:",
				"hint": "blank = rpc.monad.xyz",
			},
		],
	},
	{
		"heading": "SIGNING KEYS — only needed to write, and only on the chain you write to.",
		"fields": [
			{
				"key": "SOLANA_SIGNER_PRIVATE_KEY",
				"label": "SOL signer key:",
				"hint": "base58 — also opens messages addressed to you",
			},
			{
				"key": "MON_SIGNER_PRIVATE_KEY",
				"label": "MON signer key:",
				"hint": "0x-prefixed hex",
			},
		],
	},
	{
		"heading": "HANLOCK — only for the HanLock encryption option.",
		"fields": [
			{
				"key": "HANLOCK_PASS",
				"label": "HanLock pass:",
				"hint": "optional",
			},
		],
	},
]

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




#region Keys screen

func _build_keys_panel(root: Control) -> void:
	var box := IQOverlay.make(root, PANEL_WIDTH)
	box.add_theme_constant_override("separation", 6)
	_keys_panel = box.get_meta("panel")

	box.add_child(IQOverlay.title("— KEYS —"))
	box.add_child(
		IQOverlay.note(
			"Encrypted on this machine and never sent anywhere. Apps never see "
			+ "them: they ask, and you approve."
		)
	)
	for group: Dictionary in FIELD_GROUPS:
		box.add_child(IQOverlay.section(str(group["heading"])))
		for field: Dictionary in group["fields"]:
			_inputs[str(field["key"])] = IQOverlay.row(
				box, str(field["label"]), str(field["hint"])
			)

	box.add_child(HSeparator.new())

	_master_row_label = IQOverlay.note("")
	box.add_child(_master_row_label)
	_master_input = IQOverlay.row(box, "Master password:", "unlocks these keys")
	_confirm_input = IQOverlay.row(box, "Confirm password:", "type it again")

	_keys_status = Label.new()
	_keys_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_keys_status)

	var strip := IQOverlay.buttons(box)

	# Sits left of the spacer, so it reads as a field toggle rather than an action.
	_reveal = CheckBox.new()
	_reveal.text = "Reveal"
	_reveal.toggled.connect(_on_reveal_toggled)
	strip.add_child(_reveal)
	strip.move_child(_reveal, 0)

	IQOverlay.button(strip, "Save", _on_save_pressed)
	IQOverlay.button(strip, "Cancel", _on_cancel_pressed)


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
	var box := IQOverlay.make(root, UNLOCK_WIDTH)
	_unlock_panel = box.get_meta("panel")

	box.add_child(IQOverlay.title("— LOCKED —"))
	box.add_child(
		IQOverlay.note(
			(
				"Your signing keys are encrypted on this machine. "
				+ "Unlock them to inscribe. Reading on-chain data works either way."
			)
		)
	)
	box.add_child(HSeparator.new())

	_unlock_input = IQOverlay.row(box, "Master password:", "")
	_unlock_input.text_submitted.connect(func(_t: String) -> void: _on_unlock_pressed())

	_unlock_status = Label.new()
	_unlock_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_unlock_status)

	var strip := IQOverlay.buttons(box)
	IQOverlay.button(strip, "Unlock", _on_unlock_pressed)
	IQOverlay.button(strip, "Read-only", _on_skip_pressed)


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
