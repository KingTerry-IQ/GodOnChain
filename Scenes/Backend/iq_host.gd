## Owns the bundled IQ sidecar process.
##
## GodOnChain ships the IQ Labs SDK as a single-file executable under
## res://sidecar/bin/ and runs it itself, so there is no second project to
## clone, install or start. The sidecar is the shared service: this app talks
## to it, and so do the .pck apps launched from PckExecutor, which is why it
## stays an HTTP service rather than becoming in-process GDScript.
##
## Responsibilities:
##   - extract the bundled binary to user:// and spawn it on loopback
##   - hold the control token and mint scoped tokens for launched apps
##   - publish a discovery file so apps started outside GodOnChain can connect
##   - surface write-approval prompts raised by those apps
##   - reap the process on exit
##
## Everything spends from one signer, so no app but this one gets `write`
## without the user agreeing to it first. See Scenes/Backend/iq_approvals.gd.

class_name IQHost
extends Node

## The sidecar is up and answering at this URL.
signal sidecar_ready(url: String)
## The sidecar could not be started. `reason` is safe to show to the user.
signal sidecar_failed(reason: String)
## Sidecar exited or stopped answering after having been ready.
signal sidecar_lost(reason: String)
## An app is asking to spend. See iq_approvals.gd for the prompt.
signal approval_requested(approval: Dictionary)
## A pending approval went away without us answering (timed out, or the
## requesting app quit). Lets the UI dismiss a prompt that no longer matters.
signal approval_withdrawn(approval_id: String)

## Where the built binary lives inside the export.
const SIDECAR_DIR := "res://sidecar/bin/"
## Development fallback: the plain bundle, run through a local Node.
const DEV_BUNDLE := "res://sidecar/build/sidecar.cjs"
## Extraction target. Binaries cannot be executed from inside a .pck.
const RUNTIME_DIR := "user://bin/"

const SECRETS_PATH := "user://iq_secrets.cfg"
const SALT_PATH := "user://iq_secrets.salt"
const SALT_BYTES := 16
## Cost of turning the master password into a key. Matches the work factor
## data_handler.gd already uses, and is paid once per unlock.
const PBKDF2_ITERATIONS := 100_000
## Marker proving a decrypt actually used the right password.
const VAULT_SENTINEL := "__iq_vault"
const VAULT_VERSION := 1

## Matches IQClient.DISCOVERY_VERSION.
const DISCOVERY_VERSION := 1

const HEALTH_TIMEOUT_SECONDS := 20.0
const HEALTH_INTERVAL := 0.25
const APPROVAL_POLL_INTERVAL := 0.5

var base_url: String = ""
var control_token: String = ""
var is_ready: bool = false
var last_error: String = ""

## Keys and RPC endpoints. Loaded from the vault, edited in the settings UI.
var secrets: Dictionary = {
	"SOLANA_RPC_URL": "",
	"SOLANA_SIGNER_PRIVATE_KEY": "",
	"MONAD_RPC_URL": "",
	"MON_SIGNER_PRIVATE_KEY": "",
	"HANLOCK_PASS": "",
}

## Where the vault lives. Overridable so a test can point somewhere harmless:
## these files hold real signing keys, and a suite that deletes them destroys
## something the user cannot get back by re-running anything.
var secrets_path: String = SECRETS_PATH
var salt_path: String = SALT_PATH

var _pid: int = -1
var _port: int = 0
## Anonymous read-only token handed out through the discovery file.
var _discovery_token: String = ""
var _approval_timer: Timer
## Approval ids we have already announced, so we only emit once each.
var _seen_approvals: Dictionary = {}


func _ready() -> void:
	# Nothing is decrypted until the user supplies their master password.
	pass


func _notification(what: int) -> void:
	# Reap the sidecar however the window goes away. It holds signing keys, so
	# leaving it running after the UI is gone would be the worst outcome.
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		stop()


#region Lifecycle

## Extracts, spawns and waits for the sidecar. Returns true once it answers.
func start() -> bool:
	if is_ready:
		return true

	var launch: Dictionary = _resolve_launch_command()
	if launch.is_empty():
		return _fail(last_error)

	_port = _pick_free_port()
	if _port <= 0:
		return _fail("Could not find a free local port for the on-chain service.")

	var crypto := Crypto.new()
	control_token = crypto.generate_random_bytes(32).hex_encode()
	_discovery_token = ""

	# The sidecar reads keys from its environment. Children of this process
	# inherit it, so scrub the values again as soon as it has spawned.
	for key: String in secrets:
		var value := str(secrets[key])
		if not value.is_empty():
			OS.set_environment(key, value)

	var args: PackedStringArray = launch["args"]
	args.append_array(
		PackedStringArray([
			"--port",
			str(_port),
			"--token",
			control_token,
			# So it exits on its own if we die without reaping it.
			"--parent-pid",
			str(OS.get_process_id()),
			# And clears the discovery file on its way out, so a later app does
			# not chase a dead port after a crash.
			"--discovery-file",
			discovery_path(),
		])
	)

	_pid = OS.create_process(launch["exe"], args, false)

	for key: String in secrets:
		OS.unset_environment(key)

	if _pid == -1:
		return _fail("Could not start the on-chain service (%s)." % launch["exe"])

	base_url = "http://127.0.0.1:%d" % _port

	if not await _await_health():
		stop()
		return _fail(
			"The on-chain service started but never answered. See the console for its output."
		)

	# Health is confirmed, so the control plane is usable. This has to be set
	# before publishing the discovery file, which mints a token through it.
	is_ready = true

	if not await _publish_discovery_file():
		# Non-fatal: this app works, only externally-launched apps lose out.
		push_warning("IQHost: " + last_error)

	_start_approval_polling()
	sidecar_ready.emit(base_url)
	return true


## Stops the sidecar and removes the discovery file. Safe to call repeatedly.
func stop() -> void:
	_stop_approval_polling()
	_remove_discovery_file()

	if _pid != -1:
		OS.kill(_pid)
		_pid = -1

	is_ready = false
	base_url = ""
	control_token = ""
	_discovery_token = ""
	_seen_approvals.clear()


## Decides what to execute: the bundled binary, or a dev bundle through Node.
## Returns {} and sets last_error if neither is usable.
func _resolve_launch_command() -> Dictionary:
	var exe_name := "iq-sidecar.exe" if OS.has_feature("windows") else "iq-sidecar"
	var packaged := SIDECAR_DIR + exe_name

	if ResourceLoader.exists(packaged) or FileAccess.file_exists(packaged):
		var extracted: String = _extract_binary(packaged, exe_name)
		if not extracted.is_empty():
			return {"exe": extracted, "args": PackedStringArray()}
		return {}

	# Running from the editor before anyone has run `node build.mjs`.
	if FileAccess.file_exists(DEV_BUNDLE):
		var bundle := ProjectSettings.globalize_path(DEV_BUNDLE)
		return {"exe": "node", "args": PackedStringArray([bundle])}

	last_error = (
		"The on-chain service is missing. Build it with:\n"
		+ "    cd sidecar && npm install && node build.mjs"
	)
	return {}


## Copies the binary out of res:// (it may be inside the .pck, where it cannot
## be executed) into user://bin/.
##
## The file is named after its own size, which sidesteps the real problem on
## Windows: a running .exe cannot be overwritten. A second instance of the app,
## or a sidecar that outlived its parent, used to make startup fail outright
## with a file error and no way forward. A new build simply gets a new name.
func _extract_binary(source: String, exe_name: String) -> String:
	DirAccess.make_dir_recursive_absolute(RUNTIME_DIR)

	var src := FileAccess.open(source, FileAccess.READ)
	if src == null:
		last_error = "Could not read the bundled on-chain service at %s." % source
		return ""
	var bytes := src.get_buffer(src.get_length())
	src.close()

	var stem := exe_name.get_basename()
	var suffix := exe_name.get_extension()
	var target := "%s%s-%d%s" % [
		RUNTIME_DIR, stem, bytes.size(), "." + suffix if not suffix.is_empty() else ""
	]

	# Already unpacked at this exact size: reuse it and never touch the file,
	# so a copy currently running is left alone.
	if FileAccess.file_exists(target):
		var existing := FileAccess.open(target, FileAccess.READ)
		if existing != null:
			var same := existing.get_length() == bytes.size()
			existing.close()
			if same:
				_make_executable(target)
				_sweep_old_binaries(stem, target)
				return ProjectSettings.globalize_path(target)

	var out := FileAccess.open(target, FileAccess.WRITE)
	if out == null:
		last_error = (
			"Could not unpack the on-chain service (error %d). Another copy of "
			% FileAccess.get_open_error()
			+ "GodOnChain may be running."
		)
		return ""
	out.store_buffer(bytes)
	out.close()

	_make_executable(target)
	_sweep_old_binaries(stem, target)
	return ProjectSettings.globalize_path(target)


func _make_executable(path: String) -> void:
	if OS.has_feature("windows"):
		return
	# The copy loses the executable bit.
	OS.execute("chmod", ["+x", ProjectSettings.globalize_path(path)])


## Removes binaries left by earlier builds. Best effort only: one that is still
## running cannot be deleted, and that is fine — it will go on the next launch.
func _sweep_old_binaries(stem: String, keep: String) -> void:
	var dir := DirAccess.open(RUNTIME_DIR)
	if dir == null:
		return
	for file_name in dir.get_files():
		if not file_name.begins_with(stem):
			continue
		var path := RUNTIME_DIR + file_name
		if path == keep:
			continue
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


## Asks the OS for an unused port by binding one and immediately letting go.
func _pick_free_port() -> int:
	var probe := TCPServer.new()
	if probe.listen(0, "127.0.0.1") != OK:
		return 0
	var port := probe.get_local_port()
	probe.stop()
	return port


func _await_health() -> bool:
	var deadline := Time.get_ticks_msec() + int(HEALTH_TIMEOUT_SECONDS * 1000.0)
	while Time.get_ticks_msec() < deadline:
		# The process can die at startup (bad key, port taken); notice quickly.
		if _pid != -1 and not OS.is_process_running(_pid):
			last_error = "The on-chain service exited during startup."
			return false

		var response: Dictionary = await _control_request("GET", "/health", {}, null, false)
		if response.get("ok", false):
			return true

		await get_tree().create_timer(HEALTH_INTERVAL).timeout

	last_error = "Timed out waiting for the on-chain service."
	return false


func _fail(reason: String) -> bool:
	last_error = reason
	is_ready = false
	sidecar_failed.emit(reason)
	return false

#endregion


#region Tokens for launched apps

## Mints a token for an app about to be launched. Read-only by default: writes
## spend the user's funds, so they go through approval_requested instead.
## Returns {} on failure.
func mint_app_token(label: String, scopes: PackedStringArray = ["read"]) -> Dictionary:
	if not is_ready:
		last_error = "The on-chain service is not running."
		return {}

	var response: Dictionary = await _control_request(
		"POST", "/control/tokens", {}, {"label": label, "scopes": scopes}
	)
	if not response.get("ok", false):
		return {}
	var data: Variant = response.get("data")
	return data if data is Dictionary else {}


## Revokes a token, e.g. once a launched app has exited.
func revoke_app_token(token_id: String) -> bool:
	if not is_ready or token_id.is_empty():
		return false
	var response: Dictionary = await _control_request("DELETE", "/control/tokens/" + token_id)
	return response.get("ok", false)


## Environment an app should be launched with so IQClient can find us.
func launch_environment(label: String) -> Dictionary:
	var minted: Dictionary = await mint_app_token(label)
	if minted.is_empty():
		return {}
	return {
		"id": str(minted.get("id", "")),
		"env":
		{
			IQClient.ENV_URL: base_url,
			IQClient.ENV_TOKEN: str(minted.get("token", "")),
			IQClient.ENV_APP: label,
		},
	}

#endregion


#region Discovery file

static func discovery_path() -> String:
	return IQClient.discovery_path()


## Publishes url + an anonymous read-only token for apps we did not launch.
## Deliberately never carries write access: an app we cannot name is an app we
## cannot describe in an approval prompt.
func _publish_discovery_file() -> bool:
	var minted: Dictionary = await mint_app_token("Unidentified app (discovery)")
	if minted.is_empty():
		last_error = "Could not mint the discovery token; external apps will not connect."
		return false

	_discovery_token = str(minted.get("token", ""))

	var path := discovery_path()
	var dir := path.get_base_dir()
	var err := DirAccess.make_dir_recursive_absolute(dir)
	if err != OK and not DirAccess.dir_exists_absolute(dir):
		last_error = "Could not create %s for the discovery file." % dir
		return false

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		last_error = "Could not write the discovery file at %s." % path
		return false

	file.store_string(
		JSON.stringify(
			{
				"version": DISCOVERY_VERSION,
				"url": base_url,
				"token": _discovery_token,
				"pid": OS.get_process_id(),
			},
			"\t"
		)
	)
	file.close()
	return true


func _remove_discovery_file() -> void:
	var path := discovery_path()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)

#endregion


#region Approvals

func _start_approval_polling() -> void:
	if _approval_timer != null:
		return
	_approval_timer = Timer.new()
	_approval_timer.wait_time = APPROVAL_POLL_INTERVAL
	_approval_timer.timeout.connect(_poll_approvals)
	add_child(_approval_timer)
	_approval_timer.start()


func _stop_approval_polling() -> void:
	if _approval_timer != null:
		_approval_timer.stop()
		_approval_timer.queue_free()
		_approval_timer = null


func _poll_approvals() -> void:
	if not is_ready:
		return

	var response: Dictionary = await _control_request("GET", "/control/approvals")
	if not response.get("ok", false):
		# One missed poll is not proof of death; a dead process is.
		if _pid != -1 and not OS.is_process_running(_pid):
			is_ready = false
			_stop_approval_polling()
			sidecar_lost.emit("The on-chain service stopped unexpectedly.")
		return

	var data: Variant = response.get("data")
	if not data is Dictionary:
		return

	var pending: Array = (data as Dictionary).get("approvals", [])
	var live := {}

	for entry: Variant in pending:
		if not entry is Dictionary:
			continue
		var approval: Dictionary = entry
		var id := str(approval.get("id", ""))
		if id.is_empty():
			continue
		live[id] = true
		if not _seen_approvals.has(id):
			_seen_approvals[id] = true
			approval_requested.emit(approval)

	for id: String in _seen_approvals.keys():
		if not live.has(id):
			_seen_approvals.erase(id)
			approval_withdrawn.emit(id)


## Answers a prompt. `remember` grants that app write access for the rest of
## this session, so a trusted app is not re-prompted on every inscription.
func resolve_approval(approval_id: String, allow: bool, remember: bool = false) -> bool:
	if not is_ready:
		return false
	var response: Dictionary = await _control_request(
		"POST",
		"/control/approvals/" + approval_id,
		{},
		{"decision": "allow" if allow else "deny", "remember": remember}
	)
	_seen_approvals.erase(approval_id)
	return response.get("ok", false)

#endregion


#region Secrets

## True once the vault has been opened, or newly created, this session.
## Reads never need it; only inscribing does.
var is_unlocked: bool = false


## Whether a usable vault exists. Both halves are required: a container
## without its salt cannot be opened, so it is treated as no vault at all and
## the user is asked to set keys up again. That also migrates vaults written
## by the older machine-id scheme, which had no salt file.
func vault_exists() -> bool:
	return FileAccess.file_exists(secrets_path) and FileAccess.file_exists(salt_path)


## Opens the vault. Returns false on the wrong password, leaving the app in a
## read-only state rather than failing hard.
func unlock(password: String) -> bool:
	if password.is_empty():
		last_error = "Enter your master password."
		return false
	if not vault_exists():
		last_error = "No keys have been saved yet."
		return false

	var salt := _load_salt()
	if salt.is_empty():
		last_error = "The key vault is missing its salt file and cannot be opened."
		return false

	var file := FileAccess.open_encrypted_with_pass(
		secrets_path, FileAccess.READ, _derive_key(password, salt)
	)
	if file == null:
		last_error = "Wrong master password."
		return false

	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	# The sentinel catches a password that happens to decrypt to valid-looking
	# bytes, which the container format alone does not always reject.
	if not parsed is Dictionary or not (parsed as Dictionary).has(VAULT_SENTINEL):
		last_error = "Wrong master password."
		return false

	for key: String in secrets:
		if (parsed as Dictionary).has(key):
			secrets[key] = str((parsed as Dictionary)[key])

	is_unlocked = true
	last_error = ""
	return true


## Writes the vault under the given password, creating it on first save.
func save_secrets(password: String) -> bool:
	if password.is_empty():
		last_error = "A master password is required to store keys."
		return false

	var salt := _load_salt()
	if salt.is_empty():
		salt = Crypto.new().generate_random_bytes(SALT_BYTES)
		if not _store_salt(salt):
			return false

	var file := FileAccess.open_encrypted_with_pass(
		secrets_path, FileAccess.WRITE, _derive_key(password, salt)
	)
	if file == null:
		last_error = "Could not save keys (error %d)." % FileAccess.get_open_error()
		return false

	var payload := secrets.duplicate()
	payload[VAULT_SENTINEL] = VAULT_VERSION
	file.store_string(JSON.stringify(payload))
	file.close()

	is_unlocked = true
	last_error = ""
	return true


## Forgets the decrypted keys. The sidecar keeps whatever it was spawned with
## until it is restarted.
func lock() -> void:
	for key: String in secrets:
		secrets[key] = ""
	is_unlocked = false


## Stretches the master password into the key the container is encrypted with.
## Godot hashes a passphrase straight to an AES key, which is too weak for
## something a person types, so the work factor is added here.
func _derive_key(password: String, salt: PackedByteArray) -> String:
	var crypto := Crypto.new()
	var secret := password.to_utf8_buffer()

	var block_salt := salt.duplicate()
	block_salt.append_array([0, 0, 0, 1])

	var u := crypto.hmac_digest(HashingContext.HASH_SHA256, secret, block_salt)
	var t := u.duplicate()
	for _i in range(1, PBKDF2_ITERATIONS):
		u = crypto.hmac_digest(HashingContext.HASH_SHA256, secret, u)
		for j in range(t.size()):
			t[j] ^= u[j]

	return t.hex_encode()


## The salt is not secret; it only stops one rainbow table covering everyone.
func _load_salt() -> PackedByteArray:
	if not FileAccess.file_exists(salt_path):
		return PackedByteArray()
	var file := FileAccess.open(salt_path, FileAccess.READ)
	if file == null:
		return PackedByteArray()
	var salt := file.get_buffer(SALT_BYTES)
	file.close()
	return salt


func _store_salt(salt: PackedByteArray) -> bool:
	var file := FileAccess.open(salt_path, FileAccess.WRITE)
	if file == null:
		last_error = "Could not create the key vault (error %d)." % FileAccess.get_open_error()
		return false
	file.store_buffer(salt)
	file.close()
	return true


## True once there is a signer configured for the given chain.
func can_write(chain: String) -> bool:
	if not is_unlocked:
		return false
	var normalized := chain.strip_edges().to_lower()
	if normalized == "mon" or normalized == "monad":
		return not str(secrets["MON_SIGNER_PRIVATE_KEY"]).is_empty()
	return not str(secrets["SOLANA_SIGNER_PRIVATE_KEY"]).is_empty()

#endregion


#region HTTP

## Control-plane request, carrying the control token.
func _control_request(
	method: String,
	path: String,
	query: Dictionary = {},
	body: Variant = null,
	authenticated: bool = true
) -> Dictionary:
	if base_url.is_empty():
		return {"ok": false, "code": 0, "error": "No sidecar URL."}

	var url := base_url + path
	if not query.is_empty():
		var parts: PackedStringArray = []
		for key: String in query:
			parts.append("%s=%s" % [key, str(query[key]).uri_encode()])
		url += "?" + "&".join(parts)

	var headers: PackedStringArray = []
	if authenticated:
		headers.append("Authorization: Bearer " + control_token)
	var body_text := ""
	if body != null:
		headers.append("Content-Type: application/json")
		body_text = JSON.stringify(body)

	var verb := HTTPClient.METHOD_GET
	match method:
		"POST":
			verb = HTTPClient.METHOD_POST
		"DELETE":
			verb = HTTPClient.METHOD_DELETE

	var http := HTTPRequest.new()
	http.timeout = 0
	add_child(http)

	var err := http.request(url, headers, verb, body_text)
	if err != OK:
		http.queue_free()
		return {"ok": false, "code": 0, "error": "Request failed (%d)." % err}

	var result: Array = await http.request_completed
	http.queue_free()

	var code: int = result[1]
	var text: String = (result[3] as PackedByteArray).get_string_from_utf8()
	if result[0] != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "code": code, "error": "No response.", "text": text}

	var parsed: Variant = JSON.parse_string(text)
	if code < 200 or code >= 300:
		var message := text
		if parsed is Dictionary and (parsed as Dictionary).has("error"):
			message = str((parsed as Dictionary)["error"])
		return {"ok": false, "code": code, "error": message, "data": parsed}

	return {"ok": true, "code": code, "data": parsed, "text": text, "error": ""}

#endregion
