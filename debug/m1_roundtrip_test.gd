extends SceneTree

const WorldScript = preload("res://scripts/world/world.gd")
const SaveSystem = preload("res://scripts/save/save_manager.gd")
const WORLD_SEED := 139732
const EXPECTED_PATH := "user://m2_roundtrip_expected.json"


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		push_error("Usage: m1_roundtrip_test.gd save|load")
		quit(2)
		return
	if args[0] == "save":
		await _save_phase()
	elif args[0] == "load":
		await _load_phase()
	else:
		push_error("Unknown round-trip phase: %s" % args[0])
		quit(2)


func _save_phase() -> void:
	var world = WorldScript.new()
	world.world_seed = WORLD_SEED
	root.add_child(world)
	var frames := 0
	while not world.is_generated and frames < 4000:
		await process_frame
		frames += 1
	if not world.is_generated:
		push_error("M2 round-trip save phase timed out waiting for the spawn area")
		quit(1)
		return
	var journal := BlockEditJournal.new()
	var samples: Array = []
	for sample_index in range(20):
		var x := 3 + sample_index * 5
		var y := 2 + (sample_index * 7) % 55
		var z := 24 + (sample_index % 5) * 9
		var block_id: int = world.block_ids[&"iron_ore"] if sample_index % 2 == 0 else world.block_ids[&"air"]
		if not world.set_block(Vector3i(x, y, z), block_id):
			continue
		journal.on_block_edited(Vector3i(x, y, z), block_id)
		samples.append({"x": x, "y": y, "z": z, "id": block_id})
	if samples.size() < 10:
		push_error("M2 round-trip save phase could only edit %d sample cells" % samples.size())
		quit(1)
		return
	if not SaveSystem.save_world(world, journal, Vector3(64.5, 30.0, 64.5)):
		push_error("M2 round-trip save phase failed to write save files")
		quit(1)
		return
	var expected_file := FileAccess.open(EXPECTED_PATH, FileAccess.WRITE)
	expected_file.store_string(JSON.stringify({"samples": samples}))
	expected_file.close()
	print("M2 ROUNDTRIP SAVE PHASE PASS: %d edited cells journaled." % samples.size())
	quit(0)


func _load_phase() -> void:
	var expected_file := FileAccess.open(EXPECTED_PATH, FileAccess.READ)
	if expected_file == null:
		push_error("M2 round-trip expected data missing; run save phase first")
		quit(1)
		return
	var expected_parser := JSON.new()
	var expected_error := expected_parser.parse(expected_file.get_as_text())
	expected_file.close()
	if expected_error != OK:
		push_error("M2 round-trip expected data is invalid")
		quit(1)
		return
	var world = WorldScript.new()
	world.world_seed = WORLD_SEED
	root.add_child(world)
	await process_frame
	var loaded := SaveSystem.load_world(WORLD_SEED, world)
	if loaded.is_empty():
		push_error("M2 round-trip load phase failed")
		quit(1)
		return
	var edits: Dictionary = loaded["edits"]
	var samples: Array = expected_parser.data["samples"]
	var passed := true
	for sample in samples:
		var cell := Vector3i(int(sample["x"]), int(sample["y"]), int(sample["z"]))
		var coords := Vector3i(floori(cell.x / 16.0), floori(cell.y / 16.0), floori(cell.z / 16.0))
		var chunk: PackedByteArray = edits.get(coords, PackedByteArray())
		var local := (cell.x - coords.x * 16) + (cell.y - coords.y * 16) * 16 + (cell.z - coords.z * 16) * 256
		var actual := int(chunk[local]) if chunk.size() == 4096 else -1
		var expected := int(sample["id"])
		print("M2 round-trip sample (%d,%d,%d) expected=%d actual=%d %s" % [cell.x, cell.y, cell.z, expected, actual, "PASS" if actual == expected else "FAIL"])
		if actual != expected:
			passed = false
	print("M2 ROUNDTRIP %s: %d edited cells survived a fresh process." % ["PASS" if passed else "FAIL", samples.size()])
	quit(0 if passed else 1)
