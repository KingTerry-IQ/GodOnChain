## Surfaces write-approval prompts raised by apps talking to the IQ sidecar.
##
## GodOnChain launches arbitrary downloaded .pck apps and hands them access to
## a service holding funded signers. Reads are free, so those are silent. A
## spend is not: the sidecar parks it, this node asks the user, and the app's
## request only proceeds on a yes.
##
## The screen is a full-screen Panel overlay built through IQOverlay, matching
## the prompts already in browser_ui.tscn.

class_name IQApprovals
extends Node

## Roughly what an inscription costs, mirroring IQ_SDK's own estimators.
const SOL_CHUNK_BYTES := 850
const SOL_INITIAL_TX := 0.0001
const SOL_PER_CHUNK := 0.000005
const SOL_FINAL_TX := 0.005005

## Monad is charged per much larger chunk.
const MON_CHUNK_BYTES := 70656
const MON_PER_CHUNK := 0.415971708
const MON_FINAL_TX := 6.51834143

const PANEL_WIDTH := 820

var host: IQHost

var _panel: Panel
var _title: Label
var _heading: Label
var _detail: Label
var _warning: Label
var _queue: Array[Dictionary] = []
## Rings when a prompt appears. Lives here rather than in any app, because the
## request may well arrive while the user is looking at that app's window.
var _chime: IQChime
var _showing: String = ""


func _init(iq_host: IQHost = null) -> void:
	host = iq_host


## Builds the overlay under `root`, the themed Control it lives in.
func attach(root: Control) -> void:
	if host == null:
		push_error("IQApprovals needs an IQHost.")
		return

	host.approval_requested.connect(_on_approval_requested)
	host.approval_withdrawn.connect(_on_approval_withdrawn)

	_chime = IQChime.new()
	_chime.name = "IQChime"
	add_child(_chime)

	var box := IQOverlay.make(root, PANEL_WIDTH)
	_panel = box.get_meta("panel")

	_title = IQOverlay.title("— WRITE REQUEST —")
	box.add_child(_title)

	_heading = IQOverlay.body()
	box.add_child(_heading)

	box.add_child(HSeparator.new())

	_detail = IQOverlay.body()
	box.add_child(_detail)

	_warning = IQOverlay.note(
		(
			"This spends from the wallet configured in GodOnChain. "
			+ "Only allow apps you trust."
		)
	)
	box.add_child(_warning)

	var strip := IQOverlay.buttons(box)
	# Deny is listed first so the safe choice is the one nearest the text.
	IQOverlay.button(strip, "Deny", _on_denied)
	IQOverlay.button(strip, "Allow once", _on_allow_once)
	IQOverlay.button(strip, "Always allow this app", _on_allow_always)


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
		_panel.hide()
		_show_next()


func _show_next() -> void:
	if _showing != "" or _queue.is_empty() or _panel == null:
		return
	var approval: Dictionary = _queue.pop_front()
	_showing = str(approval.get("id", ""))

	# A decrypt costs nothing but exposes something private, so it is framed as
	# access rather than expense. Saying "this spends from your wallet" over a
	# decrypt would train people to ignore the words.
	var revealing := str(approval.get("scope", "write")) == "reveal"
	_title.text = "— ACCESS REQUEST —" if revealing else "— WRITE REQUEST —"
	_warning.text = (
		"This opens something addressed to you, using your wallet's identity key. "
		+ "Only allow apps you trust."
		if revealing
		else "This spends from the wallet configured in GodOnChain. "
		+ "Only allow apps you trust."
	)

	_heading.text = _summarise(approval)
	_detail.text = _details(approval)
	_panel.show()

	# The app that asked may not be the window in front of the user.
	if _chime != null:
		_chime.ring()

#endregion


#region Answers

func _on_allow_once() -> void:
	await _resolve(true, false)


func _on_allow_always() -> void:
	await _resolve(true, true)


func _on_denied() -> void:
	await _resolve(false, false)


func _resolve(allow: bool, remember: bool) -> void:
	var id := _showing
	if id.is_empty():
		return
	_showing = ""
	_panel.hide()
	await host.resolve_approval(id, allow, remember)
	_show_next()

#endregion


#region Description

## One line naming who wants what. The user is being asked to spend real
## money, so this leads with the app and the action, not with "allow?".
func _summarise(approval: Dictionary) -> String:
	var label := str(approval.get("label", "An unidentified app"))
	var action := str(approval.get("action", "write"))
	var details: Dictionary = approval.get("details", {})
	var chain := str(details.get("chain", "sol")).to_upper()

	match action:
		"codeIn":
			return "%s wants to inscribe data on %s." % [label, chain]
		"createTable":
			return (
				"%s wants to create the database table '%s' on %s."
				% [label, str(details.get("tableName", "?")), chain]
			)
		"writeRow":
			return (
				"%s wants to write a row to '%s' on %s."
				% [label, str(details.get("tableName", "?")), chain]
			)
		"decrypt":
			return "%s wants to open a sealed message addressed to you." % label
		_:
			return "%s wants to write to %s." % [label, chain]


## What is being written, how big it is, and what it will cost. Every write
## pays the base transaction even when it carries almost no payload, so a cost
## is always shown rather than only when a byte count happens to arrive.
func _details(approval: Dictionary) -> String:
	var details: Dictionary = approval.get("details", {})
	var chain := str(details.get("chain", "sol")).to_upper()
	var bytes := int(details.get("bytes", 0))

	var lines: PackedStringArray = []

	var database := str(details.get("dbRootId", ""))
	if not database.is_empty():
		lines.append("Database:         %s" % database)

	var table := str(details.get("tableName", ""))
	if not table.is_empty():
		lines.append("Table:            %s" % table)

	var filename := str(details.get("filename", ""))
	if not filename.is_empty():
		lines.append("File:             %s" % filename)

	if bytes > 0:
		lines.append("Size:             %s" % String.humanize_size(bytes))

	if str(approval.get("scope", "write")) == "reveal":
		var recipients := int(details.get("recipients", 0))
		if recipients > 0:
			lines.append("Addressed to:     %d key(s), one of them yours" % recipients)
		lines.append("Cost:             nothing. This spends no funds.")
	else:
		lines.append("Estimated cost:   %s" % _estimate_cost(chain, bytes))
	return "\n".join(lines)


func _estimate_cost(chain: String, bytes: int) -> String:
	# Deliberately no early return for 0: a payload-free write still pays the
	# base transaction, which is exactly what the formula yields.
	var payload: int = maxi(bytes, 0)

	if chain.to_lower().begins_with("mon"):
		@warning_ignore("integer_division")
		var mon_chunks: int = (payload + MON_CHUNK_BYTES - 1) / MON_CHUNK_BYTES
		return "~%.4f MON" % (MON_FINAL_TX + mon_chunks * MON_PER_CHUNK)

	@warning_ignore("integer_division")
	var sol_chunks: int = (payload + SOL_CHUNK_BYTES - 1) / SOL_CHUNK_BYTES
	return "~%.6f SOL" % (SOL_INITIAL_TX + sol_chunks * SOL_PER_CHUNK + SOL_FINAL_TX)

#endregion
