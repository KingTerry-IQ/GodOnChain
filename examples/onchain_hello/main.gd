## A minimal app that uses the on-chain SDK through the GodOnChain host.
##
## The point of this example: it ships no keys, no GDExtension and no copy of
## the IQ SDK. It carries one file — addons/iq_client/iq_client.gd — and talks
## to whichever GodOnChain launched it.
##
## Reads happen silently. The write button deliberately does not: GodOnChain
## shows the user what this app wants to spend, and the call fails if they say
## no. That is the normal, expected path, not an error to shout about.
##
## Also runnable headlessly for testing:
##     Godot --headless --path . -- --read <signature>
##     Godot --headless --path . -- --write <text>

extends Control

@onready var status: Label = $Margin/Box/Status
@onready var signature_input: LineEdit = $Margin/Box/SigRow/Signature
@onready var read_button: Button = $Margin/Box/SigRow/Read
@onready var payload_input: LineEdit = $Margin/Box/WriteRow/Payload
@onready var write_button: Button = $Margin/Box/WriteRow/Write
@onready var output: RichTextLabel = $Margin/Box/Output

var iq: IQClient


func _ready() -> void:
	iq = IQClient.new()
	add_child(iq)

	read_button.pressed.connect(_on_read_pressed)
	write_button.pressed.connect(_on_write_pressed)
	_set_busy(true)

	if not await iq.discover():
		# No host is a normal way to be run. Say so and stay usable.
		status.text = "No on-chain host: " + iq.last_error
		_log("[color=gray]%s[/color]" % iq.last_error)
		_log("Launch this app from GodOnChain to give it chain access.")
		await _run_command_line()
		return

	var who := iq.app_label if not iq.app_label.is_empty() else "an unnamed app"
	status.text = "Connected to GodOnChain as %s." % who
	_log("Host: %s" % iq.base_url)
	_set_busy(false)

	await _run_command_line()


#region Actions

func _on_read_pressed() -> void:
	await _read(signature_input.text.strip_edges())


func _read(signature: String) -> bool:
	if signature.is_empty():
		_log("[color=orange]Enter a signature first.[/color]")
		return false

	_set_busy(true)
	status.text = "Reading %s..." % signature.substr(0, 16)

	var meta: Dictionary = await iq.read_metadata(signature)
	if meta.is_empty():
		_fail("Could not read that inscription", iq.last_error)
		return false

	_log("[b]Metadata[/b]\n%s" % JSON.stringify(meta, "  "))

	var doc = await iq.read_code_in(signature, "sol", _on_progress)
	if doc == null:
		_fail("Could not read the contents", iq.last_error)
		return false

	_log("[b]Data[/b]\n%s" % str(doc.data).substr(0, 2000))
	status.text = "Read complete."
	_set_busy(false)
	return true


func _on_write_pressed() -> void:
	await _write(payload_input.text)


func _write(payload: String) -> bool:
	if payload.strip_edges().is_empty():
		_log("[color=orange]Nothing to inscribe.[/color]")
		return false

	_set_busy(true)
	# This is the interesting part: the call blocks here while GodOnChain asks
	# the user to approve the spend. It can sit for as long as they take.
	status.text = "Waiting for you to approve this in GodOnChain..."

	var signature = await iq.write_code_in(payload, "hello.txt", "txt", "sol", _on_progress)
	if signature == null:
		# Declining is an ordinary outcome; report it plainly.
		_fail("Not inscribed", iq.last_error)
		return false

	_log("[b]Inscribed[/b]\n%s" % str(signature))
	status.text = "Inscribed."
	_set_busy(false)
	return true

#endregion


#region Headless driving

## Lets the integration test drive this app without a UI.
func _run_command_line() -> void:
	var args := OS.get_cmdline_user_args()
	var ok := true

	for i in args.size():
		match args[i]:
			"--read":
				if i + 1 < args.size():
					ok = await _read(args[i + 1]) and ok
			"--write":
				if i + 1 < args.size():
					ok = await _write(args[i + 1]) and ok

	# A result file lets an integration test in another process see how this
	# one got on, which stdout from OS.create_process cannot.
	for i in args.size():
		if args[i] == "--result-file" and i + 1 < args.size():
			var file := FileAccess.open(args[i + 1], FileAccess.WRITE)
			if file != null:
				file.store_string(
					JSON.stringify(
						{
							"ok": ok,
							"connected": iq.is_available(),
							"label": iq.app_label,
							"error": iq.last_error,
						}
					)
				)
				file.close()

	if args.has("--quit-when-done"):
		print("EXAMPLE_RESULT ", "ok" if ok else "failed")
		get_tree().quit(0 if ok else 1)

#endregion


#region Output

func _on_progress(percent: float) -> void:
	status.text = "Working... %d%%" % int(percent)


func _fail(headline: String, detail: String) -> void:
	status.text = headline
	_log("[color=orange]%s: %s[/color]" % [headline, detail])
	_set_busy(false)


func _log(message: String) -> void:
	output.append_text(message + "\n\n")
	# Mirrors to stdout so the app is legible when run headlessly.
	print(message)


func _set_busy(busy: bool) -> void:
	read_button.disabled = busy
	write_button.disabled = busy

#endregion
