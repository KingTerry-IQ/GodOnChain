# Temporary headless check of the vault + sidecar lifecycle. Not shipped.
# Run: Godot --headless --path . --script res://tools/iq_selftest.gd
extends SceneTree

var failures := 0

# Filled in by the backgrounded write below.
var write_result: Variant = null
var write_done := false
var seen_approval: Dictionary = {}


func _capture_approval(approval: Dictionary) -> void:
	seen_approval = approval


func _background_write(client: IQClient) -> void:
	write_result = await client.write_code_in("hello on-chain", "note.txt", "txt", "sol")
	write_done = true


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
	DirAccess.remove_absolute(IQHost.SECRETS_PATH)
	DirAccess.remove_absolute(IQHost.SALT_PATH)

	var host := IQHost.new()
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

		var discovery := IQClient.discovery_path()
		check("discovery file published", FileAccess.file_exists(discovery), discovery)

		var minted: Dictionary = await host.mint_app_token("selftest.pck")
		check("mints an app token", minted.has("token"), str(minted))
		check("app token is read-only", str(minted.get("scopes", [])).contains("read"))

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
		var revoked: bool = await host.revoke_app_token(str(minted.get("id", "")))
		check("revokes the app token", revoked)

		OS.unset_environment(IQClient.ENV_URL)
		OS.unset_environment(IQClient.ENV_TOKEN)
		OS.unset_environment(IQClient.ENV_APP)

		host.stop()
		check("discovery file removed on stop", not FileAccess.file_exists(discovery))
		check("marked not ready", not host.is_ready)

	# Do not leave a vault behind under a password only this file knows.
	DirAccess.remove_absolute(IQHost.SECRETS_PATH)
	DirAccess.remove_absolute(IQHost.SALT_PATH)

	print("\n%d failure(s)" % failures)
	quit(1 if failures > 0 else 0)
