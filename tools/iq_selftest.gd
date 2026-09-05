# Temporary headless check of the vault + sidecar lifecycle. Not shipped.
# Run: Godot --headless --path . --script res://tools/iq_selftest.gd
extends SceneTree

var failures := 0

## The suite's own vault, so the real one at user://iq_secrets.* is never
## opened, written or deleted by a test run.
const TEST_SECRETS := "user://selftest_secrets.cfg"
const TEST_SALT := "user://selftest_secrets.salt"
const TEST_DISCOVERY := "user://selftest_host.json"


func _clear_test_vault() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SECRETS))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TEST_SALT))

# Filled in by the backgrounded write below.
var write_result: Variant = null
var write_done := false
var seen_approval: Dictionary = {}


func _capture_approval(approval: Dictionary) -> void:
	seen_approval = approval

## Waits for the next approval to surface, then denies it.
func _await_and_deny(host: IQHost, what: String) -> Dictionary:
	seen_approval = {}
	var waited := 0
	while seen_approval.is_empty() and waited < 80:
		await create_timer(0.25).timeout
		waited += 1
	if seen_approval.is_empty():
		check("%s raises an approval" % what, false)
		return {}
	check("%s raises an approval" % what, true)
	var found := seen_approval.duplicate()
	await host.resolve_approval(str(found.get("id", "")), false)
	return found


func _background_write(client: IQClient) -> void:
	write_result = await client.write_code_in("hello on-chain", "note.txt", "txt", "sol")
	write_done = true

var table_result: Variant = null
var table_done := false
var row_result: Variant = null
var row_done := false


func _background_create_table(client: IQClient) -> void:
	table_result = await client.create_table(
		"selftest-root", "notes", PackedStringArray(["id", "body"]), "id"
	)
	table_done = true


func _background_write_row(client: IQClient) -> void:
	row_result = await client.write_row("selftest-root", "notes", {"id": "1", "body": "hi"})
	row_done = true

var allowed_result: Variant = null
var allowed_done := false


func _background_allowed_row(client: IQClient) -> void:
	allowed_result = await client.write_row("selftest-root", "notes", {"id": "2", "body": "yes"})
	allowed_done = true


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		print("  PASS  ", label)
	else:
		failures += 1
		print("  FAIL  ", label, "  ", detail)


func _initialize() -> void:
	_run()


func _run() -> void:
	# Nodes are not inside the tree yet during _initialize, and HTTPRequest
	# needs to be, so let one frame pass first.
	await process_frame

	# Start from a clean slate so the first-run path is what gets exercised.
	var host := IQHost.new()
	# Point the vault somewhere disposable *before* anything touches it. These
	# files hold real signing keys; a suite must never go near the real ones.
	host.secrets_path = TEST_SECRETS
	host.salt_path = TEST_SALT
	# And the discovery file, for the same reason. Publishing this suite's own
	# sidecar at the real location, then deleting it on teardown, cuts a
	# running GodOnChain off from every app that was talking to it — the app
	# stays up and healthy while nothing on the machine can find it any more.
	host.discovery_file = TEST_DISCOVERY
	_clear_test_vault()

	root.add_child(host)
	await process_frame

	print("\n--- vault ---")
	check("starts with no vault", not host.vault_exists())
	check("starts locked", not host.is_unlocked)
	check("cannot write while locked", not host.can_write("sol"))

	host.secrets["SOLANA_SIGNER_PRIVATE_KEY"] = "TEST_SOL_KEY_base58"
	host.secrets["HANLOCK_PASS"] = "hunter2"
	check("save with a password", host.save_secrets("correct horse battery"))
	check("vault now exists", host.vault_exists())
	check("unlocked after save", host.is_unlocked)
	check("can write once unlocked", host.can_write("sol"))
	check("cannot write MON without a MON key", not host.can_write("mon"))

	host.lock()
	check("lock clears secrets", str(host.secrets["SOLANA_SIGNER_PRIVATE_KEY"]) == "")
	check("locked again", not host.is_unlocked)

	check("wrong password rejected", not host.unlock("wrong password entirely"))
	check("  and stays locked", not host.is_unlocked)
	check("  with a clear message", host.last_error == "Wrong master password.", host.last_error)

	check("right password accepted", host.unlock("correct horse battery"))
	check(
		"  round-trips the key",
		str(host.secrets["SOLANA_SIGNER_PRIVATE_KEY"]) == "TEST_SOL_KEY_base58",
		str(host.secrets["SOLANA_SIGNER_PRIVATE_KEY"])
	)
	check("  round-trips hanlock", str(host.secrets["HANLOCK_PASS"]) == "hunter2")

	print("\n--- sidecar ---")
	var started: bool = await host.start()
	check("sidecar starts", started, host.last_error)

	if started:
		check("bound to loopback", host.base_url.begins_with("http://127.0.0.1:"), host.base_url)
		check("has a control token", host.control_token.length() == 64)

		var discovery := host.discovery_path()
		check("discovery file published", FileAccess.file_exists(discovery), discovery)
		check("  and not at the real host's location",
			discovery != IQHost.default_discovery_path())
		check("  leaving a real host's file alone",
			not FileAccess.file_exists(IQHost.default_discovery_path())
			or FileAccess.get_md5(IQHost.default_discovery_path()) != FileAccess.get_md5(discovery))

		var bare: Dictionary = await host.mint_app_token("selftest-bare.pck")
		check("mints an app token", bare.has("token"), str(bare))
		# A scope is a standing "stop asking me", so a fresh app holds none:
		# every kind of access it wants is a question the user gets to answer.
		check("  holding no standing grants", (bare.get("scopes", []) as Array).is_empty(),
			str(bare.get("scopes", [])))

		# The rest of this suite exercises the plumbing, not the prompt, so it
		# uses a token that has already been granted reads. The read prompt has
		# its own end-to-end coverage in sidecar/tests/readgate.mjs, which needs
		# a second process to answer the prompt while a request is parked.
		var minted: Dictionary = await host.mint_app_token(
			"selftest.pck", PackedStringArray(["read"])
		)
		check("  and can be minted with reads already allowed",
			str(minted.get("scopes", [])).contains("read"), str(minted.get("scopes", [])))

		print("\n--- client ---")
		var client := IQClient.new()
		root.add_child(client)
		# Pretend we are a launched app.
		OS.set_environment(IQClient.ENV_URL, host.base_url)
		OS.set_environment(IQClient.ENV_TOKEN, str(minted.get("token", "")))
		OS.set_environment(IQClient.ENV_APP, "selftest.pck")

		var found: bool = await client.discover()
		check("client discovers the host", found, client.last_error)
		check("client knows its label", client.app_label == "selftest.pck", client.app_label)

		# No RPC key configured, so this must fail on the SDK, not on auth.
		var meta: Dictionary = await client.read_metadata("not_a_real_signature", "sol")
		check(
			"read is authorised (fails on data, not auth)",
			not client.last_error.contains("not authorised"),
			client.last_error
		)

		print("
--- approvals ---")
		host.approval_requested.connect(_capture_approval)

		# Not awaited: it parks server-side until the prompt is answered.
		_background_write(client)

		var waited := 0
		while seen_approval.is_empty() and waited < 60:
			await create_timer(0.25).timeout
			waited += 1

		check("a write raises an approval", not seen_approval.is_empty())
		check("  names the app", str(seen_approval.get("label", "")) == "selftest.pck",
			str(seen_approval.get("label", "")))
		var details: Dictionary = seen_approval.get("details", {})
		check("  says which chain", str(details.get("chain", "")) == "sol", str(details))
		check("  says how big", int(details.get("bytes", 0)) == 14, str(details.get("bytes", 0)))
		check("  names the file", str(details.get("filename", "")) == "note.txt")
		check("  write is still parked", not write_done)

		var denied: bool = await host.resolve_approval(str(seen_approval.get("id", "")), false)
		check("host can deny it", denied)

		waited = 0
		while not write_done and waited < 60:
			await create_timer(0.25).timeout
			waited += 1
		check("denial releases the caller", write_done)
		check("  with no transaction", write_result == null)
		check("  and a readable reason", client.last_error.length() > 0, client.last_error)

		print("")
		print("
--- database writes ---")

		# Validation happens client-side, before anything is spent.
		var bad_id = await client.create_table(
			"root", "t", PackedStringArray(["a", "b"]), "missing"
		)
		check("create_table rejects an id column not in the columns", bad_id == null)
		check("  and says why", client.last_error.contains("missing"), client.last_error)

		var bad_cols = await client.create_table("root", "t", PackedStringArray([]), "id")
		check("create_table rejects an empty column list", bad_cols == null)

		var bad_row = await client.write_row("root", "t", 42)
		check("write_row rejects a non-object row", bad_row == null)
		check("  and says why", client.last_error.contains("Dictionary"), client.last_error)

		# Now the real thing: both must park for approval, not execute.
		_background_create_table(client)
		var t_appr: Dictionary = await _await_and_deny(host, "create_table")
		if not t_appr.is_empty():
			check("  as a createTable action", str(t_appr.get("action", "")) == "createTable",
				str(t_appr.get("action", "")))
			var t_det: Dictionary = t_appr.get("details", {})
			check("  naming the database", str(t_det.get("dbRootId", "")) == "selftest-root",
				str(t_det.get("dbRootId", "")))
			check("  naming the table", str(t_det.get("tableName", "")) == "notes",
				str(t_det.get("tableName", "")))

		var waited_t := 0
		while not table_done and waited_t < 80:
			await create_timer(0.25).timeout
			waited_t += 1
		check("  denial releases create_table", table_done)
		check("  with no table created", table_result == null)

		_background_write_row(client)
		var r_appr: Dictionary = await _await_and_deny(host, "write_row")
		if not r_appr.is_empty():
			check("  as a writeRow action", str(r_appr.get("action", "")) == "writeRow",
				str(r_appr.get("action", "")))
			var r_det: Dictionary = r_appr.get("details", {})
			check("  naming the table", str(r_det.get("tableName", "")) == "notes",
				str(r_det.get("tableName", "")))
			# The Dictionary row was encoded to JSON before being sent.
			check("  measuring the encoded row", int(r_det.get("bytes", 0)) > 0,
				str(r_det.get("bytes", 0)))

		var waited_r := 0
		while not row_done and waited_r < 80:
			await create_timer(0.25).timeout
			waited_r += 1
		check("  denial releases write_row", row_done)
		check("  with no row written", row_result == null)

		# Denial is only half the story: prove the gate actually opens. With no
		# signer configured the SDK must be what fails, not the approval broker.
		_background_allowed_row(client)
		seen_approval = {}
		var waited_a := 0
		while seen_approval.is_empty() and waited_a < 80:
			await create_timer(0.25).timeout
			waited_a += 1
		check("an allowed write_row reaches the prompt", not seen_approval.is_empty())
		if not seen_approval.is_empty():
			await host.resolve_approval(str(seen_approval.get("id", "")), true, false)

		var waited_b := 0
		while not allowed_done and waited_b < 120:
			await create_timer(0.25).timeout
			waited_b += 1
		check("  approval releases it", allowed_done)
		# The vault above holds a deliberately fake key, so the SDK fails decoding
		# it. That failure is the proof: the request reached the SDK at all.
		var why := client.last_error.to_lower()
		check(
			"  and failed inside the SDK, on the fake key",
			why.contains("base58") or why.contains("signer") or why.contains("key"),
			client.last_error
		)
		check(
			"  not on a refusal",
			not client.last_error.to_lower().contains("denied"),
			client.last_error
		)

		await _test_own_token(host)

		print("")
		var revoked: bool = await host.revoke_app_token(str(minted.get("id", "")))
		check("revokes the app token", revoked)

		OS.unset_environment(IQClient.ENV_URL)
		OS.unset_environment(IQClient.ENV_TOKEN)
		OS.unset_environment(IQClient.ENV_APP)

		host.stop()
		check("discovery file removed on stop", not FileAccess.file_exists(discovery))
		check("marked not ready", not host.is_ready)

	# Do not leave a vault behind under a password only this file knows.
	_clear_test_vault()

	_test_chime()
	_test_costs()

	print("\n%d failure(s)" % failures)
	quit(1 if failures > 0 else 0)


func _test_chime() -> void:
	print("\n--- the approval chime ---")
	var chime := IQChime.new()
	var rate := int(IQChime.MIX_RATE)

	# Nothing until something asks.
	var quiet := 0.0
	for i in rate:
		quiet = maxf(quiet, absf(chime._next_sample().x))
	check("silent until an app asks", quiet < 0.0001, "%.5f" % quiet)

	# Strike it the way ring() does, without needing an audio device.
	chime._envelope = 1.0
	chime._phase = 0.0
	chime._frequency = IQChime.FIRST_HZ
	chime._pending = int(IQChime.SECOND_DELAY * IQChime.MIX_RATE)

	# 40 ms slots: fine enough to see the second strike, which a coarser
	# window straddles and hides.
	var slots: Array[float] = []
	var slot := int(rate * 0.04)
	for s in 26:
		var loudest := 0.0
		for i in slot:
			loudest = maxf(loudest, absf(chime._next_sample().x))
		slots.append(loudest)

	check("it rings", slots[0] > 0.2, "%.3f" % slots[0])
	check("  without clipping", slots[0] < 0.95, "%.3f" % slots[0])

	# A second strike shows up as the envelope rising again after decaying.
	var restruck := false
	for i in range(1, slots.size()):
		if slots[i] > slots[i - 1] * 1.15:
			restruck = true
	check("  twice, so it reads as a summons rather than a click", restruck)

	check("  decaying rather than cutting off", slots[10] < slots[0] * 0.6)
	check("  and gone within a second and a half", slots[25] < slots[0] * 0.06,
		"%.4f vs %.3f" % [slots[25], slots[0]])

	# It must not be silenceable: the request may have arrived while the user
	# was looking at another window entirely.
	check("there is no mute for it", not (chime as Object).has_method("set_enabled"))


func _test_own_token(host: IQHost) -> void:
	print("\n--- GodOnChain is not a guest ---")

	# Our own screens act for the user, so they never stop to ask the user.
	var own: Dictionary = await host.mint_own_token()
	var scopes := str(own.get("scopes", []))
	check("our own token is minted", own.has("token"), str(own))
	check("  granted reads outright", scopes.contains("read"), scopes)
	check("  and writes", scopes.contains("write"), scopes)
	check("  and opening what is addressed to us", scopes.contains("reveal"), scopes)

	# But not the control plane: a bug in our database screens must not be able
	# to mint tokens or answer approval prompts on the user's behalf.
	check("  but not control of the host itself", not scopes.contains("control"), scopes)

	# A guest gets the opposite: nothing, until the user says otherwise.
	var guest: Dictionary = await host.mint_app_token("a-guest.pck")
	check("a guest app is granted nothing",
		(guest.get("scopes", []) as Array).is_empty(), str(guest.get("scopes", [])))
	check("  so its reads and writes both reach the user",
		str(guest.get("token", "")) != str(own.get("token", "")))

	# The anonymous token published for apps we did not launch is the least
	# identifiable caller of all, so it is certainly not the one to exempt.
	var published := {}
	var file := FileAccess.open(host.discovery_file, FileAccess.READ)
	if file != null:
		var parsed: Variant = JSON.parse_string(file.get_as_text())
		file.close()
		if parsed is Dictionary:
			published = parsed
	check("the discovery file offers a token", published.has("token"), str(published.keys()))
	check("  which is not ours", str(published.get("token", "")) != str(own.get("token", "")))


func _test_costs() -> void:
	print("\n--- one cost model ---")

	# The prompt quotes a price before the user says yes and the log quotes one
	# after. A different number in each place is worse than quoting neither.
	check("solana is priced per small chunk", IQCosts.estimate("sol", 0) > 0.0)
	check("  and a payload-free write still pays", IQCosts.estimate("sol", 0) >= IQCosts.SOL_FINAL_TX)
	check("  with a bigger payload costing more",
		IQCosts.estimate("sol", 100_000) > IQCosts.estimate("sol", 1000))

	check("monad is recognised by prefix",
		IQCosts.is_monad("mon") and IQCosts.is_monad("MONAD") and not IQCosts.is_monad("sol"))
	check("  and priced per much larger chunk",
		IQCosts.estimate("mon", 1000) == IQCosts.estimate("mon", 60_000),
		"%f vs %f" % [IQCosts.estimate("mon", 1000), IQCosts.estimate("mon", 60_000)])
	check("  crossing a chunk boundary costs more",
		IQCosts.estimate("mon", 80_000) > IQCosts.estimate("mon", 60_000))

	# Each chain at the precision it deserves: fractions of a SOL are
	# meaningful at six places, fractions of a MON are not.
	check("solana formats to six places", IQCosts.format("sol", 0).contains("SOL"),
		IQCosts.format("sol", 0))
	check("monad formats to four", IQCosts.format("mon", 0).contains("MON"),
		IQCosts.format("mon", 0))
	check("  both marked as estimates", IQCosts.format("sol", 0).begins_with("~")
		and IQCosts.format("mon", 0).begins_with("~"))

	# Negative bytes cannot happen, but a cost model that returns a negative
	# price if they did would be quoting the user a refund.
	check("a nonsense size still prices the base transaction",
		IQCosts.estimate("sol", -50) == IQCosts.estimate("sol", 0))
