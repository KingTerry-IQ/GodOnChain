## Client for the IQ Labs on-chain SDK, as hosted by GodOnChain.
##
## Drop this file into any Godot project. It is plain GDScript over HTTPRequest
## with no GDExtension and no addons, so it runs under whatever stock Godot
## binary GodOnChain launched you with.
##
## It finds its host in one of two ways:
##
##   1. Environment variables, set by GodOnChain when it launched this app.
##      You get your own token, labelled with your app name, so approval
##      prompts can tell the user who is asking.
##   2. A discovery file written by a running GodOnChain, for apps started on
##      their own. That token is read-only and anonymous.
##
## Reads are free and always allowed. Writes spend real funds, so the host asks
## the user first: expect write_code_in() to block while that prompt is open,
## and to fail if they decline.
##
## Usage:
##     var iq := IQClient.new()
##     add_child(iq)
##     if not await iq.discover():
##         push_error(iq.last_error)
##         return
##     var doc = await iq.read_code_in(signature, "sol")
##     print(doc.data)

class_name IQClient
extends Node

## Emitted once a reachable host has been confirmed.
signal host_found(url: String)
## Emitted when no host could be found, or it stopped answering.
signal host_missing(reason: String)

const DISCOVERY_FILENAME := "host.json"
const DISCOVERY_DIR := "GodOnChain"
## Bumped only if the discovery file's shape changes incompatibly.
const DISCOVERY_VERSION := 1

const ENV_URL := "GODONCHAIN_IQ_URL"
const ENV_TOKEN := "GODONCHAIN_IQ_TOKEN"
const ENV_APP := "GODONCHAIN_IQ_APP"

## Seconds between /progress polls. Matches the host's own cadence.
const POLL_INTERVAL := 0.5

var base_url: String = ""
var token: String = ""
## How this app identifies itself in approval prompts, when the host told us.
var app_label: String = ""
## Populated whenever a call returns null / empty. Safe to show to a user.
var last_error: String = ""

var _available: bool = false


#region Discovery

## Absolute path of the discovery file a running GodOnChain publishes.
static func discovery_path() -> String:
	var dir := ""
	if OS.has_feature("windows"):
		dir = OS.get_environment("APPDATA")
	elif OS.has_feature("macos"):
		var home_mac := OS.get_environment("HOME")
		if not home_mac.is_empty():
			dir = home_mac + "/Library/Application Support"
	else:
		dir = OS.get_environment("XDG_DATA_HOME")
		if dir.is_empty():
			var home := OS.get_environment("HOME")
			if not home.is_empty():
				dir = home + "/.local/share"

	if dir.is_empty():
		# Last resort: our own user:// directory, which at least exists.
		return OS.get_user_data_dir().replace("\\", "/") + "/" + DISCOVERY_FILENAME

	return dir.replace("\\", "/") + "/" + DISCOVERY_DIR + "/" + DISCOVERY_FILENAME


## Locates a host and confirms it is answering. Returns false and sets
## last_error if there is nothing to talk to.
func discover() -> bool:
	_available = false
	last_error = ""

	var env_url := OS.get_environment(ENV_URL)
	var env_token := OS.get_environment(ENV_TOKEN)
	if not env_url.is_empty() and not env_token.is_empty():
		base_url = env_url.rstrip("/")
		token = env_token
		app_label = OS.get_environment(ENV_APP)
		if await _confirm_health():
			return true
		# Stale env from a host that has since exited; fall through to the file.

	if _load_discovery_file():
		if await _confirm_health():
			return true

	if last_error.is_empty():
		last_error = (
			"No GodOnChain host found. Launch this app from GodOnChain, "
			+ "or start GodOnChain alongside it."
		)
	host_missing.emit(last_error)
	return false


func is_available() -> bool:
	return _available


func _load_discovery_file() -> bool:
	var path := discovery_path()
	if not FileAccess.file_exists(path):
		last_error = "No host running (no discovery file at %s)." % path
		return false

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		last_error = "Could not read the discovery file at %s." % path
		return false
	var text := file.get_as_text()
	file.close()

	var parsed: Variant = JSON.parse_string(text)
	if not parsed is Dictionary:
		last_error = "The discovery file at %s is malformed." % path
		return false

	var data: Dictionary = parsed
	if int(data.get("version", 0)) != DISCOVERY_VERSION:
		last_error = "The running GodOnChain publishes an incompatible host file."
		return false

	base_url = str(data.get("url", "")).rstrip("/")
	token = str(data.get("token", ""))
	app_label = ""
	if base_url.is_empty() or token.is_empty():
		last_error = "The discovery file at %s is missing url or token." % path
		return false
	return true


func _confirm_health() -> bool:
	var response: Dictionary = await _request("GET", "/health", {}, null, false)
	if not response.get("ok", false):
		last_error = "Host at %s is not answering." % base_url
		return false
	_available = true
	host_found.emit(base_url)
	return true

#endregion


#region Reads

## Fetches an inscription. Returns {metadata, data}, or null on failure.
## progress_callback receives a float from 0 to 100.
func read_code_in(
	signature: String, chain: String = "sol", progress_callback: Callable = Callable()
) -> Variant:
	if signature.is_empty():
		last_error = "Signature cannot be empty."
		return null
	var started: Dictionary = await _request(
		"GET", "/read", {"signature": signature, "chain": _normalize_chain(chain)}
	)
	return await _follow_job(started, progress_callback)


## Metadata only, with no chunk reconstruction, so this is cheap.
## Returns {} on failure.
func read_metadata(signature: String, chain: String = "sol") -> Dictionary:
	if signature.is_empty():
		last_error = "Signature cannot be empty."
		return {}
	var response: Dictionary = await _request(
		"GET", "/metadata", {"signature": signature, "chain": _normalize_chain(chain)}
	)
	if not response.get("ok", false):
		return {}
	var data: Variant = response.get("data")
	return data if data is Dictionary else {}


## Lists the tables under a dbRootId. Returns {} on failure.
func get_db_table_list(
	db_root_id: String, chain: String = "sol", progress_callback: Callable = Callable()
) -> Dictionary:
	if db_root_id.is_empty():
		last_error = "dbRootId cannot be empty."
		return {}
	var started: Dictionary = await _request(
		"GET",
		"/db/getTablelistFromRoot",
		{"dbRootId": db_root_id, "chain": _normalize_chain(chain)}
	)
	var result: Variant = await _follow_job(started, progress_callback)
	return result if result is Dictionary else {}


## Reads rows from a table. On SOL pass table_pda; on MON pass db_root_id plus
## table_name. Returns {} on failure.
func read_db_table_rows(
	table_pda: String = "",
	db_root_id: String = "",
	table_name: String = "",
	chain: String = "sol",
	limit: int = 20,
	before: String = "",
	progress_callback: Callable = Callable()
) -> Dictionary:
	var normalized := _normalize_chain(chain)
	var query := {"chain": normalized}

	if normalized == "mon":
		if db_root_id.is_empty() or table_name.is_empty():
			last_error = "MON row reads need both dbRootId and tableName."
			return {}
		query["dbRootId"] = db_root_id
		query["tableName"] = table_name
	else:
		if table_pda.is_empty():
			last_error = "SOL row reads need a tablePda."
			return {}
		query["tablePda"] = table_pda

	if limit > 0:
		query["limit"] = str(limit)
	if not before.is_empty():
		query["before"] = before

	var started: Dictionary = await _request("GET", "/db/readTableRows", query)
	var result: Variant = await _follow_job(started, progress_callback)
	return result if result is Dictionary else {}


## HanLock encode, using the passphrase the host holds. Returns "" on failure.
func han_encrypt(text: String) -> String:
	return await _han("/han_encrypt", text)


## HanLock decode. Returns "" on failure.
func han_decrypt(text: String) -> String:
	return await _han("/han_decrypt", text)


func _han(path: String, text: String) -> String:
	if text.is_empty():
		last_error = "Nothing to encode."
		return ""
	var response: Dictionary = await _request("POST", path, {}, {"data": text})
	if not response.get("ok", false):
		return ""
	return str(response.get("text", ""))

#endregion


#region Writes

## Inscribes data on-chain. This spends real funds, so unless the host has
## already granted this app write access it blocks while GodOnChain asks the
## user, and returns null if they decline.
##
## Returns the transaction signature (SOL) or hash (MON), or null.
func write_code_in(
	data: String,
	filename: String = "",
	filetype: String = "",
	chain: String = "sol",
	progress_callback: Callable = Callable()
) -> Variant:
	var payload := data.strip_edges()
	if payload.is_empty():
		last_error = "Cannot inscribe empty data."
		return null

	var started: Dictionary = await _request(
		"POST",
		"/write",
		{},
		{
			"data": payload,
			"filename": filename.strip_edges(),
			"filetype": filetype.strip_edges(),
			"chain": _normalize_chain(chain),
		}
	)
	return await _follow_job(started, progress_callback)


## Creates a database table. Spends, so this blocks on the user's approval the
## same way write_code_in() does, and returns null if they decline.
##
## The two chains disagree about table identity, and this smooths over what it
## honestly can:
##   - Solana derives the table address from `table_seed` and needs a
##     `table_hint`. Both default to `table_name`, so pass them explicitly only
##     when they need to differ.
##   - Monad uses `table_name` alone, and supports `is_private`.
##
## Returns the host's result, which carries `dbRootId`, `tableName`, the chain,
## and a `signature` (aliased from Monad's `txHash` so callers need not branch).
func create_table(
	db_root_id: String,
	table_name: String,
	columns: PackedStringArray,
	id_col: String,
	chain: String = "sol",
	options: Dictionary = {},
	progress_callback: Callable = Callable()
) -> Variant:
	if db_root_id.strip_edges().is_empty():
		last_error = "dbRootId cannot be empty."
		return null
	if table_name.strip_edges().is_empty():
		last_error = "Table name cannot be empty."
		return null
	if columns.is_empty():
		last_error = "A table needs at least one column."
		return null
	if id_col.strip_edges().is_empty():
		last_error = "Specify which column is the id."
		return null
	if not columns.has(id_col):
		last_error = "The id column '%s' is not among the columns." % id_col
		return null

	var normalized := _normalize_chain(chain)
	var body := {
		"chain": normalized,
		"dbRootId": db_root_id.strip_edges(),
		"tableName": table_name.strip_edges(),
		"idCol": id_col.strip_edges(),
		"extKeys": options.get("ext_keys", []),
		"writers": options.get("writers", []),
	}

	if normalized == "mon":
		body["columns"] = columns
		body["isPrivate"] = bool(options.get("is_private", false))
	else:
		body["columnNames"] = columns
		body["tableSeed"] = str(options.get("table_seed", table_name)).strip_edges()
		body["tableHint"] = str(options.get("table_hint", table_name)).strip_edges()

	if options.has("gate"):
		body["gate"] = options["gate"]

	var started: Dictionary = await _request("POST", "/db/createTable", {}, body)
	return _with_signature(await _follow_job(started, progress_callback))


## Appends a row to a table. Spends, so this blocks on the user's approval and
## returns null if they decline.
##
## `row` may be a Dictionary, which is encoded for you, or an already-encoded
## JSON String. On Solana the table is addressed by its seed, which defaults to
## `table_name`; pass `table_seed` in `options` if you set a different one when
## the table was created.
func write_row(
	db_root_id: String,
	table_name: String,
	row: Variant,
	chain: String = "sol",
	options: Dictionary = {},
	progress_callback: Callable = Callable()
) -> Variant:
	if db_root_id.strip_edges().is_empty():
		last_error = "dbRootId cannot be empty."
		return null
	if table_name.strip_edges().is_empty():
		last_error = "Table name cannot be empty."
		return null

	var row_json := ""
	if row is String:
		row_json = row
	elif row is Dictionary or row is Array:
		row_json = JSON.stringify(row)
	else:
		last_error = "A row must be a Dictionary or a JSON string."
		return null

	if row_json.strip_edges().is_empty():
		last_error = "Cannot write an empty row."
		return null

	var normalized := _normalize_chain(chain)
	var body := {
		"chain": normalized,
		"dbRootId": db_root_id.strip_edges(),
		"rowJson": row_json,
	}

	if normalized == "mon":
		body["tableName"] = table_name.strip_edges()
	else:
		body["tableSeed"] = str(options.get("table_seed", table_name)).strip_edges()
		if options.has("skip_confirmation"):
			body["skipConfirmation"] = bool(options["skip_confirmation"])

	var started: Dictionary = await _request("POST", "/db/writeRow", {}, body)
	return _with_signature(await _follow_job(started, progress_callback))


## Monad reports a txHash where Solana reports a signature. Both are the same
## idea, so expose one name and leave the original key in place.
func _with_signature(result: Variant) -> Variant:
	if result is Dictionary:
		var dict: Dictionary = result
		if not dict.has("signature") and dict.has("txHash"):
			dict["signature"] = dict["txHash"]
		return dict
	return result

#endregion


#region Identity and encryption

## Which wallets the host is paying with, and what they hold.
##
## Returns {sol: {address, balance, unit, rpc}, mon: {...}}, with only the
## chains the host has a key for. A chain that could not be reached carries an
## "error" instead of a balance. Costs nothing and never prompts.
##
## Worth checking before a run of writes: an unfunded account and a genuine bug
## both surface as "transaction simulation failed", and this tells them apart.
func wallet_info() -> Dictionary:
	var response: Dictionary = await _request("GET", "/wallet")
	if not response.get("ok", false):
		return {}
	var data: Variant = response.get("data")
	return data if data is Dictionary else {}


## What one chain's wallet holds, or -1.0 if that is not knowable.
func balance_of(chain: String) -> float:
	var info: Dictionary = await wallet_info()
	var entry: Variant = info.get(_normalize_chain(chain), {})
	if not entry is Dictionary or (entry as Dictionary).has("error"):
		return -1.0
	return float((entry as Dictionary).get("balance", -1.0))


## This wallet's public encryption identity, as hex.
##
## Derived deterministically from the host's signing key, so it is the same
## every time and needs nothing stored. Publish it and others can encrypt
## things only this wallet can open. Returns "" on failure.
func crypto_identity() -> String:
	var response: Dictionary = await _request("GET", "/crypto/identity")
	if not response.get("ok", false):
		return ""
	var data: Variant = response.get("data")
	if data is Dictionary:
		return str((data as Dictionary).get("publicKey", ""))
	return ""


## Encrypts `text` so that any one of `recipients` can open it, and nobody else.
##
## Recipients are identity keys as returned by crypto_identity(). Costs nothing
## and needs no secret of ours, so it never prompts. Returns the envelope to
## store or inscribe, or {} on failure.
func encrypt_to(recipients: PackedStringArray, text: String) -> Dictionary:
	if recipients.is_empty():
		last_error = "No recipients given."
		return {}
	if text.is_empty():
		last_error = "Nothing to encrypt."
		return {}

	var response: Dictionary = await _request(
		"POST", "/crypto/encryptTo", {}, {"recipients": recipients, "data": text}
	)
	if not response.get("ok", false):
		return {}
	var data: Variant = response.get("data")
	return data if data is Dictionary else {}


## Opens an envelope addressed to this wallet.
##
## This uses the user's own identity key, so unless the app has already been
## granted it the call blocks while GodOnChain asks — exactly like a write —
## and returns "" if refused. Failing because the envelope is addressed to
## somebody else is an ordinary outcome, not an error.
func decrypt_envelope(envelope: Dictionary) -> String:
	if envelope.is_empty() or not envelope.has("recipients"):
		last_error = "That is not an envelope."
		return ""

	var response: Dictionary = await _request(
		"POST", "/crypto/decrypt", {}, {"envelope": envelope}
	)
	if not response.get("ok", false):
		return ""
	var data: Variant = response.get("data")
	if data is Dictionary:
		return str((data as Dictionary).get("data", ""))
	return ""

#endregion


#region Time locks

## How many sequential squarings this machine manages per second.
##
## Only meaningful as calibration: a faster machine solves the same puzzle
## sooner, so a duration built from this is a floor, never a deadline.
func timelock_rate() -> int:
	var response: Dictionary = await _request("GET", "/timelock/rate")
	if not response.get("ok", false):
		return 0
	var data: Variant = response.get("data")
	if data is Dictionary:
		return int((data as Dictionary).get("squaringsPerSecond", 0))
	return 0


## Seals `secret_hex` behind roughly `seconds` of sequential work.
##
## Instant, because whoever builds a puzzle holds the shortcut. The shortcut is
## destroyed before this returns; only the climb remains. Returns {} on failure.
func timelock_create(secret_hex: String, seconds: int) -> Dictionary:
	if secret_hex.is_empty():
		last_error = "Nothing to lock."
		return {}
	if seconds <= 0:
		last_error = "A time lock needs a positive duration."
		return {}

	var response: Dictionary = await _request(
		"POST", "/timelock/create", {}, {"secret": secret_hex, "seconds": seconds}
	)
	if not response.get("ok", false):
		return {}
	var data: Variant = response.get("data")
	return data if data is Dictionary else {}


## Does the work. There is no shortcut, so this takes as long as it takes —
## `progress_callback` receives 0-100 and is the only thing worth showing.
##
## Returns the secret as hex, or "" if it failed or the puzzle was tampered with.
func timelock_solve(puzzle: Dictionary, progress_callback: Callable = Callable()) -> String:
	if puzzle.is_empty() or not puzzle.has("n"):
		last_error = "That is not a time-lock puzzle."
		return ""

	var started: Dictionary = await _request(
		"POST", "/timelock/solve", {}, {"puzzle": puzzle}
	)
	var result: Variant = await _follow_job(started, progress_callback)
	if result == null:
		return ""
	if result is Dictionary:
		return str((result as Dictionary).get("secret", ""))
	return ""

#endregion


#region Job polling

## Takes a {jobId} response and polls it to completion.
func _follow_job(started: Dictionary, progress_callback: Callable) -> Variant:
	if not started.get("ok", false):
		return null
	var data: Variant = started.get("data")
	if not data is Dictionary or not (data as Dictionary).has("jobId"):
		last_error = "Host did not return a jobId."
		return null
	return await poll_job(str((data as Dictionary)["jobId"]), progress_callback)


## Polls a job until it completes or fails. Returns its result, or null.
func poll_job(job_id: String, progress_callback: Callable = Callable()) -> Variant:
	while true:
		var response: Dictionary = await _request("GET", "/progress", {"jobId": job_id})
		if not response.get("ok", false):
			return null

		var data: Variant = response.get("data")
		if not data is Dictionary:
			last_error = "Malformed progress response."
			return null
		var job: Dictionary = data

		if progress_callback.is_valid():
			progress_callback.call(float(job.get("progress", 0)))

		match str(job.get("status", "")):
			"completed":
				return job.get("result")
			"error":
				last_error = str(job.get("error", "The job failed."))
				return null

		await get_tree().create_timer(POLL_INTERVAL).timeout

	return null

#endregion


#region HTTP

func _normalize_chain(chain: String) -> String:
	var c := chain.strip_edges().to_lower()
	if c == "monad" or c == "mon":
		return "mon"
	return "sol"


## Issues one request, returning
## {ok: bool, code: int, data: Variant, text: String, error: String}.
## authenticated is only false for the /health probe.
func _request(
	method: String,
	path: String,
	query: Dictionary = {},
	body: Variant = null,
	authenticated: bool = true
) -> Dictionary:
	if base_url.is_empty():
		last_error = "No host configured; call discover() first."
		return {"ok": false, "code": 0, "error": last_error}

	var url := base_url + path
	if not query.is_empty():
		var parts: PackedStringArray = []
		for key: String in query:
			parts.append("%s=%s" % [key, str(query[key]).uri_encode()])
		url += "?" + "&".join(parts)

	var headers: PackedStringArray = []
	if authenticated:
		headers.append("Authorization: Bearer " + token)
	var body_text := ""
	if body != null:
		headers.append("Content-Type: application/json")
		body_text = JSON.stringify(body)

	var http := HTTPRequest.new()
	# A write can sit for minutes while the user decides, so never time out.
	http.timeout = 0
	add_child(http)

	var verb := HTTPClient.METHOD_GET if method == "GET" else HTTPClient.METHOD_POST
	var err := http.request(url, headers, verb, body_text)
	if err != OK:
		http.queue_free()
		last_error = "Could not reach the host (error %d)." % err
		return {"ok": false, "code": 0, "error": last_error}

	var result: Array = await http.request_completed
	http.queue_free()

	var request_result: int = result[0]
	var code: int = result[1]
	var raw: PackedByteArray = result[3]
	var text := raw.get_string_from_utf8()

	if request_result != HTTPRequest.RESULT_SUCCESS:
		_available = false
		last_error = "The host stopped responding (result %d)." % request_result
		host_missing.emit(last_error)
		return {"ok": false, "code": code, "error": last_error, "text": text}

	# Not every response is JSON, so only parse what looks like it. The HanLock
	# routes answer in plain text by design, and an unknown route answers with
	# an HTML error page — feeding either to the parser produced an engine-level
	# error with no useful message attached.
	var trimmed := text.strip_edges()
	var parsed: Variant = null
	if trimmed.begins_with("{") or trimmed.begins_with("["):
		parsed = JSON.parse_string(trimmed)

	if code < 200 or code >= 300:
		var message := trimmed
		if parsed is Dictionary and (parsed as Dictionary).has("error"):
			message = str((parsed as Dictionary)["error"])

		if code == 401:
			message = "This app is not authorised to use the on-chain host."
		elif code == 403 and message.is_empty():
			message = "The user declined this request."
		elif code == 404:
			# Almost always a version skew rather than a genuine missing thing:
			# the host predates the call this app is making.
			message = (
				"The host does not offer %s. It is probably older than this app "
				% path
				+ "— rebuild the sidecar with: cd sidecar && node build.mjs"
			)
		elif message.is_empty():
			message = "The host answered %d with nothing to say." % code

		last_error = message
		return {"ok": false, "code": code, "error": message, "data": parsed, "text": text}

	return {"ok": true, "code": code, "data": parsed, "text": text, "error": ""}

#endregion
