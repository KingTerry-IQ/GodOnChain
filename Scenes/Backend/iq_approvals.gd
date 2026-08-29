## Surfaces write-approval prompts raised by apps talking to the IQ sidecar.
##
## GodOnChain launches arbitrary downloaded .pck apps and hands them access to
## a service holding funded signers. Reads are free, so those are silent. A
## spend is not: the sidecar parks it, this node asks the user, and the app's
## request only proceeds on a yes.
##
## The dialog is built in code so the main scene does not have to carry it.

class_name IQApprovals
extends Node

## Roughly what a Solana inscription costs, mirroring IQ_SDK's estimator.
const SOL_CHUNK_BYTES := 850
const SOL_INITIAL_TX := 0.0001
const SOL_PER_CHUNK := 0.000005
const SOL_FINAL_TX := 0.005005

## Monad is charged per much larger chunk.
const MON_CHUNK_BYTES := 70656
const MON_PER_CHUNK := 0.415971708
const MON_FINAL_TX := 6.51834143

var host: IQHost

var _dialog: AcceptDialog
var _queue: Array[Dictionary] = []
var _showing: String = ""


func _init(iq_host: IQHost = null) -> void:
	host = iq_host


func _ready() -> void:
	if host == null:
		push_error("IQApprovals needs an IQHost.")
		return
	host.approval_requested.connect(_on_approval_requested)
	host.approval_withdrawn.connect(_on_approval_withdrawn)
	_build_dialog()


func _build_dialog() -> void:
	_dialog = AcceptDialog.new()
	_dialog.title = "On-chain write request"
	_dialog.dialog_autowrap = true
	_dialog.min_size = Vector2i(520, 0)
	_dialog.exclusive = true

	# The default OK button is the safe choice here, not the permissive one.
	_dialog.ok_button_text = "Deny"
	_dialog.confirmed.connect(_on_denied)
	_dialog.canceled.connect(_on_denied)

	var allow_once := _dialog.add_button("Allow once", true, "allow_once")
	allow_once.pressed.connect(_on_allow.bind(false))
	var allow_always := _dialog.add_button("Always allow this app", true, "allow_always")
	allow_always.pressed.connect(_on_allow.bind(true))

	add_child(_dialog)


#region Queueing

func _on_approval_requested(approval: Dictionary) -> void:
	_queue.append(approval)
	_show_next()


func _on_approval_withdrawn(approval_id: String) -> void:
	var remaining: Array[Dictionary] = []
	for queued: Dictionary in _queue:
		if str(queued.get("id", "")) != approval_id:
			remaining.append(queued)
	_queue = remaining
	if _showing == approval_id:
		# The request went away on its own; nothing left to answer.
		_showing = ""
		_dialog.hide()
		_show_next()


func _show_next() -> void:
	if _showing != "" or _queue.is_empty():
		return
	var approval: Dictionary = _queue.pop_front()
	_showing = str(approval.get("id", ""))
	_dialog.dialog_text = _describe(approval)
	_dialog.popup_centered()

#endregion


#region Answers

func _on_allow(remember: bool) -> void:
	var id := _showing
	if id.is_empty():
		return
	_showing = ""
	_dialog.hide()
	await host.resolve_approval(id, true, remember)
	_show_next()


func _on_denied() -> void:
	var id := _showing
	if id.is_empty():
		return
	_showing = ""
	await host.resolve_approval(id, false, false)
	_show_next()

#endregion


#region Description

## Builds the prompt text. The user is being asked to spend real money, so this
## names the app, the chain, the size and an estimated cost rather than just
## asking whether to "allow a write".
func _describe(approval: Dictionary) -> String:
	var label := str(approval.get("label", "An unidentified app"))
	var action := str(approval.get("action", "write"))
	var details: Dictionary = approval.get("details", {})

	var chain := str(details.get("chain", "sol")).to_upper()
	var bytes := int(details.get("bytes", 0))

	var what := ""
	match action:
		"codeIn":
			what = "inscribe data on %s" % chain
		"createTable":
			what = "create the database table '%s' on %s" % [
				str(details.get("tableName", "?")), chain
			]
		"writeRow":
			what = "write a row to '%s' on %s" % [str(details.get("tableName", "?")), chain]
		_:
			what = "write to %s" % chain

	var lines: PackedStringArray = []
	lines.append("%s wants to %s." % [label, what])
	lines.append("")

	var filename := str(details.get("filename", ""))
	if not filename.is_empty():
		lines.append("File: %s" % filename)
	if bytes > 0:
		lines.append("Size: %s" % String.humanize_size(bytes))
		lines.append("Estimated cost: %s" % _estimate_cost(chain, bytes))

	lines.append("")
	lines.append("This spends from the wallet configured in GodOnChain.")
	lines.append("Only allow apps you trust.")

	return "\n".join(lines)


func _estimate_cost(chain: String, bytes: int) -> String:
	if bytes <= 0:
		return "unknown"

	if chain.to_lower().begins_with("mon"):
		@warning_ignore("integer_division")
		var mon_chunks: int = (bytes + MON_CHUNK_BYTES - 1) / MON_CHUNK_BYTES
		return "~%.4f MON" % (MON_FINAL_TX + mon_chunks * MON_PER_CHUNK)

	@warning_ignore("integer_division")
	var sol_chunks: int = (bytes + SOL_CHUNK_BYTES - 1) / SOL_CHUNK_BYTES
	return "~%.6f SOL" % (SOL_INITIAL_TX + sol_chunks * SOL_PER_CHUNK + SOL_FINAL_TX)

#endregion
