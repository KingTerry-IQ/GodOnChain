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

const PANEL_WIDTH := 820

var host: IQHost

var _panel: Panel
var _title: Label
var _heading: Label
var _detail: Label
var _warning: Label
## Relabelled per prompt, so "always" names the kind being granted rather than
## implying the app was trusted with everything.
var _always_button: Button
var _never_button: Button
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
	# "Never" is offered alongside it because a refusal has to be as durable as
	# a grant: an app told no mid-refresh fires its remaining reads anyway, and
	# without it the same question arrives once per read.
	IQOverlay.button(strip, "Deny", _on_denied)
	_never_button = IQOverlay.button(strip, "Never", _on_deny_always)
	IQOverlay.button(strip, "Allow once", _on_allow_once)
	_always_button = IQOverlay.button(strip, "Always allow", _on_allow_always)


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

	# Each kind is a different question, so each gets its own words. Saying
	# "this spends from your wallet" over a read would train people to ignore
	# the sentence, and then it is not there when a spend actually arrives.
	var scope := str(approval.get("scope", "write"))
	match scope:
		"read":
			_title.text = "— READ REQUEST —"
			_warning.text = (
				"This costs nothing and changes nothing. It does say what you are "
				+ "looking at and whose records, to whoever is asking."
			)
		"reveal":
			_title.text = "— ACCESS REQUEST —"
			_warning.text = (
				"This opens something addressed to you, using your wallet's "
				+ "identity key. Only allow apps you trust."
			)
		_:
			_title.text = "— WRITE REQUEST —"
			_warning.text = (
				"This spends from the wallet configured in GodOnChain. "
				+ "Only allow apps you trust."
			)

	# Naming the kind on the button matters: "always allow this app" over a read
	# reads like a grant of everything, and reads are the one people will wave
	# through. Reads and writes are remembered separately.
	var kind := "spends"
	if scope == "read":
		kind = "reads"
	elif scope == "reveal":
		kind = "openings"
	if _always_button != null:
		_always_button.text = "Always allow %s" % kind
	if _never_button != null:
		_never_button.text = "Never allow %s" % kind

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


## Refuses this kind for the rest of the session, so a burst of requests does
## not become a burst of identical prompts.
func _on_deny_always() -> void:
	await _resolve(false, true)


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

## What to call the app asking.
##
## A name GodOnChain assigned when it launched something is a fact. A name the
## app chose for itself is a claim, and an app can claim anything — so the two
## must not read alike, or a self-chosen "GodOnChain" would borrow the trust of
## the real one.
func _who(approval: Dictionary) -> String:
	var label := str(approval.get("label", "An unidentified app"))
	if bool(approval.get("declared", false)):
		return "%s (self-named)" % label
	return label


## One line naming who wants what. The user is being asked to spend real
## money, so this leads with the app and the action, not with "allow?".
func _summarise(approval: Dictionary) -> String:
	var label := _who(approval)
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
		"readCodeIn":
			return "%s wants to read an inscription from %s." % [label, chain]
		"readMetadata":
			return "%s wants to read what an inscription says about itself, on %s." % [
				label, chain
			]
		"readTableRows":
			return (
				"%s wants to read the table '%s' on %s."
				% [label, str(details.get("tableName", "?")), chain]
			)
		"listTables":
			return (
				"%s wants to list the tables under '%s' on %s."
				% [label, str(details.get("dbRootId", "?")), chain]
			)
		"readWallet":
			return "%s wants to see your wallet addresses and balances." % label
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

	var scope := str(approval.get("scope", "write"))
	match scope:
		"reveal":
			var recipients := int(details.get("recipients", 0))
			if recipients > 0:
				lines.append("Addressed to:     %d key(s), one of them yours" % recipients)
			lines.append("Cost:             nothing. This spends no funds.")
		"read":
			var signature := str(details.get("signature", ""))
			if not signature.is_empty():
				lines.append("Inscription:      %s" % signature)
			# An estimated cost over a read would be a lie, and a cost line the
			# user learns to skip is one they skip over a spend too.
			lines.append("Cost:             nothing. Reading the chain is free.")
		_:
			lines.append("Estimated cost:   %s" % IQCosts.format(chain, bytes))
	return "\n".join(lines)


#endregion
