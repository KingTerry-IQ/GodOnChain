## A running log of what apps are asking the sidecar to do.
##
## This process holds funded signing keys and serves apps the user downloaded
## from a chain. The approval prompt covers the moment of consent, but consent
## is granted once and then spent repeatedly: after "always allow reads", an
## app can read all day and the user sees nothing at all. This is the part that
## makes that traffic visible.
##
## Deliberately a log rather than a dashboard. It answers "what has been
## happening, and who is doing it", which is a question you skim — not one you
## configure.
##
## Docks into the bottom of the main screen rather than living behind a button:
## a record nobody looks at is not accountability, and the whole value is being
## able to notice something odd without going to find it.

class_name IQActivity
extends Node

## How many lines to keep on screen. The sidecar holds more; this is what fits
## before scrolling stops being useful.
const VISIBLE_LINES := 200

## Wide enough for the longest label without pushing the subject off screen.
const W_APP := 22
const W_ACTION := 14

var host: IQHost

var _log: RichTextLabel
var _summary: Label
var _spent: Dictionary = {"sol": 0.0, "mon": 0.0, "rh": 0.0}
var _lines: int = 0


func _init(iq_host: IQHost = null) -> void:
	host = iq_host


## Builds the panel under the main screen's vertical box.
##
## Takes the container rather than finding it, so the caller decides where this
## belongs and this file does not carry a hard-coded scene path that breaks
## silently the next time the UI is rearranged.
func attach(column: BoxContainer) -> void:
	if host == null:
		push_error("IQActivity needs an IQHost.")
		return

	host.activity_logged.connect(_on_activity)

	var panel := PanelContainer.new()
	panel.name = "IQActivity"
	panel.custom_minimum_size = Vector2(0, 150)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 2)
	panel.add_child(box)

	var header := HBoxContainer.new()
	var title := Label.new()
	title.text = "ON-CHAIN ACTIVITY"
	title.add_theme_font_size_override("font_size", 12)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title)

	_summary = Label.new()
	_summary.add_theme_font_size_override("font_size", 12)
	_summary.text = "nothing yet"
	header.add_child(_summary)
	box.add_child(header)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.add_theme_font_size_override("normal_font_size", 12)
	box.add_child(_log)

	column.add_child(panel)


func _on_activity(entries: Array) -> void:
	for entry: Variant in entries:
		if entry is Dictionary:
			_append(entry as Dictionary)
	_repaint_summary()


func _append(entry: Dictionary) -> void:
	var scope := str(entry.get("scope", ""))
	var chain := str(entry.get("chain", ""))
	var bytes := int(entry.get("bytes", 0))
	var outcome := str(entry.get("outcome", ""))
	var spends := scope == "write" and outcome != "denied" and outcome != "blocked"

	# Only a write that actually went through costs anything. Quoting a price
	# beside a refused request would read as though it had been charged for.
	var cost := IQCosts.format(chain, bytes) if spends else ""
	if spends:
		var key := IQCosts.code(chain)
		_spent[key] = float(_spent[key]) + IQCosts.estimate(chain, bytes)

	var subject := str(entry.get("subject", ""))
	var line := "[color=#%s]%s  %s %s %s %s[/color]" % [
		_colour(scope, outcome).to_html(false),
		Time.get_time_string_from_system(),
		str(entry.get("label", "?")).substr(0, W_APP).rpad(W_APP),
		str(entry.get("action", "?")).substr(0, W_ACTION).rpad(W_ACTION),
		(chain.to_upper() if not chain.is_empty() else "  ").rpad(4),
		_tail(outcome, subject, cost),
	]

	_log.append_text(line + "\n")
	_lines += 1
	# RichTextLabel keeps everything appended to it, so an app polling in a
	# loop would grow this without bound. Trim from the top.
	if _lines > VISIBLE_LINES:
		var kept := _log.get_parsed_text().split("\n", false)
		_log.clear()
		for i in range(maxi(kept.size() - VISIBLE_LINES / 2, 0), kept.size()):
			_log.append_text(kept[i] + "\n")
		_lines = _log.get_parsed_text().split("\n", false).size()


func _tail(outcome: String, subject: String, cost: String) -> String:
	var parts: PackedStringArray = []
	if not subject.is_empty():
		parts.append(subject)
	if not cost.is_empty():
		parts.append(cost)
	# A refusal is the one outcome worth naming: the rest is the normal case,
	# and labelling every ordinary line "granted" would bury the exception.
	if outcome == "denied" or outcome == "blocked":
		parts.append("REFUSED")
	return "  ".join(parts)


static func _colour(scope: String, outcome: String) -> Color:
	if outcome == "denied" or outcome == "blocked":
		return Color("FF5555")
	if scope == "write":
		return Color("FFFF55")
	if scope == "reveal":
		return Color("FFAA55")
	return Color("AAAAAA")


func _repaint_summary() -> void:
	if _summary == null:
		return
	# One term per chain actually spent on, so a session that only touched one
	# reads as a single number rather than a row of zeroes.
	var parts: PackedStringArray = []
	for chain: String in _spent:
		var spent := float(_spent[chain])
		if spent > 0.0:
			parts.append(IQCosts.amount(chain, spent))

	if parts.is_empty():
		_summary.text = "no spends this session"
		return

	_summary.text = "this session: " + " + ".join(parts)
