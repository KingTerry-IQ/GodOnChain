## The key vault UI: unlock, just-in-time RPC/signer prompts, and the KEYS screen.
##
## These used to live in the wrapper repo's .env file in plaintext. Now they
## are held in an encrypted vault under user://, opened with a master password
## the user chooses, and handed to the sidecar process at spawn.
##
## Startup does not ask for any of this. The first on-chain read asks for RPC
## URLs (and the password, if a vault already exists). The first write asks for
## that chain's signing key. KEYS still lets someone fill everything in ahead
## of time. Screens are full-screen Panel overlays built in code, matching the
## prompts already in browser_ui.tscn, so they pick up iq_theme.tres from the
## root Control and the main scene does not have to carry them.

class_name IQSettings
extends Node

## Keys were saved. The sidecar reads them at spawn, so it needs a restart.
signal settings_saved
## The unlock screen was resolved, either way.
signal unlock_finished(unlocked: bool)
## The just-in-time RPC prompt was resolved. True if the user continued.
signal rpcs_finished(saved: bool)
## The just-in-time signer prompt was resolved. True if a key was saved.
signal signer_finished(saved: bool)

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
			{
				"key": "ROBINHOOD_RPC_URL",
				"label": "RH RPC URL:",
				"hint": "blank = rpc.mainnet.chain.robinhood.com",
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
			{
				"key": "RH_SIGNER_PRIVATE_KEY",
				"label": "RH signer key:",
				"hint": "0x-prefixed hex — Robinhood Chain, fees in ETH",
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

const CHAIN_TITLES := {
	"sol": "SOL",
	"mon": "MON",
	"rh": "RH",
}

var host: IQHost

var _keys_panel: Panel
var _unlock_panel: Panel
var _rpc_panel: Panel
var _signer_panel: Panel
var _inputs: Dictionary = {}
var _reveal: CheckBox
var _keys_status: Label
var _master_input: LineEdit
var _confirm_input: LineEdit
var _master_row_label: Label
var _unlock_input: LineEdit
var _unlock_status: Label
var _unlock_note: Label
var _skip_button: Button
var _unlock_required: bool = false
var _open_button: Button
var _rpc_inputs: Dictionary = {}
var _rpc_status: Label
var _signer_input: LineEdit
var _signer_row_label: Label
var _signer_note: Label
var _signer_master: LineEdit
var _signer_confirm: LineEdit
var _signer_master_label: Label
var _signer_status: Label
var _signer_reveal: CheckBox
var _signer_chain: String = "sol"
## Same summons as a read request: the password now arrives mid-read or
## mid-write, and the window in front of the user may not be this one.
var _chime: IQChime
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
	_chime = IQChime.new()
	_chime.name = "IQChime"
	add_child(_chime)
	_build_keys_panel(root)
	_build_unlock_panel(root)
	_build_rpc_panel(root)
	_build_signer_panel(root)
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
	_open_button.custom_minimum_size = Vector2(88, 48)
	_open_button.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_open_button.pressed.connect(open)
	# Sit in the header to the left of BUY $IQ rather than floating over it.
	var header := root.get_node_or_null("Panel/MarginContainer/MainVBox/Header/HBox")
	var buy := header.get_node_or_null("BuyIQButton") if header else null
	if header:
		header.add_child(_open_button)
		if buy:
			header.move_child(_open_button, buy.get_index())
	else:
		_open_button.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		_open_button.offset_left = -104
		_open_button.offset_top = 8
		_open_button.offset_right = -12
		_open_button.offset_bottom = 34
		root.add_child(_open_button)


## Shows the keys screen, prefilled with whatever is currently unlocked.
## Offers the password first when a vault exists, so the fields can be filled
## from it; skipping still lets the user replace everything they type.
func open() -> void:
	if host.vault_exists() and not host.is_unlocked:
		await prompt_unlock(false)

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
	_unlock_note = IQOverlay.note("")
	box.add_child(_unlock_note)
	box.add_child(HSeparator.new())

	_unlock_input = IQOverlay.row(box, "Master password:", "")
	_unlock_input.text_submitted.connect(func(_t: String) -> void: _on_unlock_pressed())

	_unlock_status = Label.new()
	_unlock_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_unlock_status)

	var strip := IQOverlay.buttons(box)
	IQOverlay.button(strip, "Unlock", _on_unlock_pressed)
	_skip_button = IQOverlay.button(strip, "Skip", _on_skip_pressed)


## Shows the unlock screen and returns once the user has resolved it.
## `required` hides Skip: a write cannot proceed without the vault.
func prompt_unlock(required: bool = false) -> bool:
	if _unlock_panel == null:
		return false
	_unlock_required = required
	_skip_button.visible = not required
	if required:
		_unlock_note.text = (
			"Your signing keys are encrypted on this machine. "
			+ "Unlock them to inscribe, or to open a message addressed to you."
		)
	else:
		_unlock_note.text = (
			"Your signing keys and endpoints are encrypted on this machine. "
			+ "Unlock them to use what you saved. Skip uses the public RPCs."
		)
	_unlock_input.text = ""
	_unlock_status.text = ""
	_unlock_panel.show()
	_unlock_input.grab_focus()
	_ring()
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
	if _unlock_required:
		return
	_unlock_input.text = ""
	_unlock_panel.hide()
	unlock_finished.emit(false)

#endregion


#region RPC prompt

func _build_rpc_panel(root: Control) -> void:
	var box := IQOverlay.make(root, UNLOCK_WIDTH)
	_rpc_panel = box.get_meta("panel")

	box.add_child(IQOverlay.title("— ENDPOINTS —"))
	box.add_child(
		IQOverlay.note(
			(
				"A read talks to the chain through these URLs. Leave any blank "
				+ "to use the public default. A free Helius or Alchemy tier is "
				+ "plenty if the shared ones stall. You can change them later in KEYS."
			)
		)
	)
	box.add_child(HSeparator.new())

	for field: Dictionary in FIELD_GROUPS[0]["fields"]:
		_rpc_inputs[str(field["key"])] = IQOverlay.row(
			box, str(field["label"]), str(field["hint"]), false
		)

	_rpc_status = Label.new()
	_rpc_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_rpc_status)

	var strip := IQOverlay.buttons(box)
	IQOverlay.button(strip, "Continue", _on_rpcs_continue)
	IQOverlay.button(strip, "Cancel", _on_rpcs_cancel)


## Asks for RPC URLs on the first on-chain read. Cancel aborts the read.
func prompt_rpcs() -> bool:
	if _rpc_panel == null:
		return true
	for key: String in _rpc_inputs:
		(_rpc_inputs[key] as LineEdit).text = str(host.secrets.get(key, ""))
	_rpc_status.text = ""
	_rpc_panel.show()
	if not _rpc_inputs.is_empty():
		(_rpc_inputs.values()[0] as LineEdit).grab_focus()
	return await rpcs_finished


func _on_rpcs_continue() -> void:
	for key: String in _rpc_inputs:
		host.secrets[key] = (_rpc_inputs[key] as LineEdit).text.strip_edges()
	if not host.save_endpoints():
		_rpc_status.text = host.last_error
		return
	_rpc_panel.hide()
	rpcs_finished.emit(true)


func _on_rpcs_cancel() -> void:
	_rpc_panel.hide()
	rpcs_finished.emit(false)

#endregion


#region Signer prompt

func _build_signer_panel(root: Control) -> void:
	var box := IQOverlay.make(root, UNLOCK_WIDTH)
	_signer_panel = box.get_meta("panel")

	box.add_child(IQOverlay.title("— SIGNING KEY —"))
	_signer_note = IQOverlay.note("")
	box.add_child(_signer_note)
	box.add_child(HSeparator.new())

	_signer_input = IQOverlay.row(box, "Signer key:", "")
	_signer_row_label = _signer_input.get_parent().get_child(0) as Label

	_signer_master_label = IQOverlay.note("")
	box.add_child(_signer_master_label)
	_signer_master = IQOverlay.row(box, "Master password:", "unlocks these keys")
	_signer_confirm = IQOverlay.row(box, "Confirm password:", "type it again")

	_signer_status = Label.new()
	_signer_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_signer_status)

	var strip := IQOverlay.buttons(box)
	_signer_reveal = CheckBox.new()
	_signer_reveal.text = "Reveal"
	_signer_reveal.toggled.connect(_on_signer_reveal_toggled)
	strip.add_child(_signer_reveal)
	strip.move_child(_signer_reveal, 0)
	IQOverlay.button(strip, "Save", _on_signer_save)
	IQOverlay.button(strip, "Cancel", _on_signer_cancel)


## Asks for the signing key of one chain, the first time that chain is written.
## Creates the vault (and a master password) if this machine has never had one.
func prompt_signer(chain: String) -> bool:
	if _signer_panel == null:
		return false
	_signer_chain = IQCosts.code(chain)
	if host.vault_exists() and not host.is_unlocked:
		if not await prompt_unlock(true):
			return false
		if host.can_write(_signer_chain):
			return true

	var field := _signer_field(_signer_chain)
	var title := str(CHAIN_TITLES.get(_signer_chain, _signer_chain.to_upper()))
	_signer_note.text = (
		"A %s signing key is needed to inscribe on this chain. "
		+ "Apps never see it: they ask, and you approve. "
		+ "Add the others later in KEYS if you want."
	) % title
	if _signer_row_label:
		_signer_row_label.text = str(field.get("label", "Signer key:"))
	_signer_input.placeholder_text = str(field.get("hint", ""))
	_signer_input.text = str(host.secrets.get(str(field.get("key", "")), ""))
	_signer_master.text = ""
	_signer_confirm.text = ""
	_signer_status.text = ""
	_signer_reveal.button_pressed = false
	_on_signer_reveal_toggled(false)

	if host.vault_exists():
		_signer_master_label.text = "Leave blank to keep your current master password."
	else:
		_signer_master_label.text = (
			"Choose a master password. It encrypts this key on disk."
		)

	_signer_panel.show()
	_signer_input.grab_focus()
	_ring()
	return await signer_finished


func _signer_field(chain: String) -> Dictionary:
	var env_key := host.signer_env_key(chain)
	for group: Dictionary in FIELD_GROUPS:
		for field: Dictionary in group["fields"]:
			if str(field["key"]) == env_key:
				return field
	return {"key": env_key, "label": "Signer key:", "hint": ""}


func _on_signer_reveal_toggled(pressed: bool) -> void:
	_signer_input.secret = not pressed


func _on_signer_save() -> void:
	var key_text := _signer_input.text.strip_edges()
	if key_text.is_empty():
		_signer_status.text = "Enter the signing key for this chain."
		return

	var password := _signer_master.text
	var confirm := _signer_confirm.text
	if password.is_empty():
		if not host.vault_exists():
			_signer_status.text = "Choose a master password first."
			return
		if not host.is_unlocked:
			_signer_status.text = "Enter your master password to save this key."
			return
	elif password != confirm:
		_signer_status.text = "The two passwords do not match."
		return
	elif password.length() < 8:
		_signer_status.text = "Use at least 8 characters."
		return

	var env_key := host.signer_env_key(_signer_chain)
	host.secrets[env_key] = key_text

	_signer_status.text = "Encrypting..."
	await get_tree().process_frame

	var effective := password
	if effective.is_empty():
		effective = _session_password
	if effective.is_empty():
		_signer_status.text = "Enter your master password to save this key."
		return

	if not host.save_secrets(effective):
		_signer_status.text = host.last_error
		return

	_session_password = effective
	_signer_input.text = ""
	_signer_master.text = ""
	_signer_confirm.text = ""
	_signer_panel.hide()
	signer_finished.emit(true)


func _on_signer_cancel() -> void:
	_signer_input.text = ""
	_signer_master.text = ""
	_signer_confirm.text = ""
	_signer_panel.hide()
	signer_finished.emit(false)

#endregion


func _clear_inputs() -> void:
	for key: String in _inputs:
		(_inputs[key] as LineEdit).text = ""
	_master_input.text = ""
	_confirm_input.text = ""


func _ring() -> void:
	if _chime != null:
		_chime.ring()
