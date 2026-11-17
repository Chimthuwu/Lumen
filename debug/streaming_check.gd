extends SceneTree

var main: Node
var failures := 0


func _check(condition: bool, label: String, detail := "") -> void:
	if not condition:
		failures += 1
		push_error("STREAM CHECK FAIL: %s %s" % [label, detail])
		return
	print("STREAM PASS: %s %s" % [label, detail])


func _initialize() -> void:
	main = load("res://scenes/world/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _wait_for_spawn(world: VoxelWorld, limit: int) -> int:
	var frames := 0
	while not world.is_generated and frames < limit:
		await process_frame
		frames += 1
	return frames


func _run() -> void:
	var world: VoxelWorld = main.world
	var frames := await _wait_for_spawn(world, 1800)
	_check(world.is_generated, "spawn area streams in", "frames=%d loaded=%d" % [frames, world.chunk_records.size()])
	if not world.is_generated:
		quit(1)
		return

	var spawn_coords := Vector3i(4, 1, 4)
	var spawn_record: Dictionary = world.chunk_records.get(spawn_coords, {})
	_check(not spawn_record.is_empty() and bool(spawn_record["mesh_installed"]), "spawn chunk is lit and meshed")
	var original_blocks: PackedByteArray = spawn_record["blocks"].duplicate() if not spawn_record.is_empty() else PackedByteArray()

	# The same coordinate must regenerate byte-identically in a worker.
	var first := WorldGenerator.generate_chunk(Vector3i(40, 1, 40), 139732, world.block_ids)
	var second := WorldGenerator.generate_chunk(Vector3i(40, 1, 40), 139732, world.block_ids)
	_check(first == second, "chunk generation is deterministic", "bytes=%d" % first.size())

	# Player edits must survive an unload/reload cycle through the modified store.
	var journal := BlockEditJournal.new()
	world.block_edited.connect(journal.on_block_edited)
	var edit_cell := Vector3i(70, world.get_surface_height(70, 90) + 3, 90)
	var edit_coords := world._chunk_of(edit_cell)
	var edit_applied := world.set_block(edit_cell, int(world.block_ids[&"lumen_crystal"]))
	var edited_id := world.get_block_id(edit_cell)
	_check(edit_applied and edited_id == int(world.block_ids[&"lumen_crystal"]), "block edits apply")
	_check(world.get_modified_chunks().has(edit_coords), "edited chunk is recorded for the save format")

	# Travel far enough that the spawn column falls outside the unload radius.
	main.player.position = Vector3(2600.0, 45.0, 2600.0)
	var travel_frames := 0
	while travel_frames < 900:
		await process_frame
		travel_frames += 1
		if not world.chunk_records.has(spawn_coords) and world.chunk_records.size() > 40:
			break
	_check(not world.chunk_records.has(spawn_coords), "old chunks unload while travelling", "loaded=%d frames=%d" % [world.chunk_records.size(), travel_frames])

	# Return and confirm the terrain regenerates the same blocks plus the edit.
	main.player.position = Vector3(64.5, 45.0, 64.5)
	var return_frames := 0
	while return_frames < 1200:
		await process_frame
		return_frames += 1
		var record: Dictionary = world.chunk_records.get(spawn_coords, {})
		if not record.is_empty() and bool(record["light_ready"]):
			break
	var reloaded: Dictionary = world.chunk_records.get(spawn_coords, {})
	_check(not reloaded.is_empty(), "unloaded chunk regenerates on return", "frames=%d" % return_frames)
	if not reloaded.is_empty():
		_check(reloaded["blocks"] == original_blocks, "regenerated terrain is byte-identical")
	var edit_record: Dictionary = world.chunk_records.get(edit_coords, {})
	_check(not edit_record.is_empty() and int(edit_record["blocks"][world._local_index(edit_cell, edit_coords)]) == int(world.block_ids[&"lumen_crystal"]), "player edits survive unload/reload")

	# Round-trip the sparse signal-journalled save format.
	var save_path := "user://worlds/%d" % 139732
	var torch_cell := Vector3i(71, world.get_surface_height(71, 90) + 4, 90)
	world.set_block(torch_cell, int(world.block_ids[&"torch"]))
	world.block_edited.disconnect(journal.on_block_edited)
	_check(journal.edits.get(edit_cell, -1) == int(world.block_ids[&"lumen_crystal"]) and journal.edits.get(torch_cell, -1) == int(world.block_ids[&"torch"]), "block_edited journals every sparse cell", "count=%d" % journal.count())
	var save_ok := WorldSave.save_world(world, journal, main.player.position, {})
	_check(save_ok, "sparse save writes")
	var size_probe := FileAccess.open(ProjectSettings.globalize_path(save_path.path_join("edits.bin")), FileAccess.READ)
	var raw_bytes := int(size_probe.get_length()) if size_probe != null else -1
	if size_probe != null:
		size_probe.close()
	_check(raw_bytes >= 0 and raw_bytes < 4096, "edits.bin stays small for a few edited cells", "%d bytes" % raw_bytes)
	var loaded_save := WorldSave.load_world(139732, world)
	_check(not loaded_save.is_empty(), "sparse save loads")
	if not loaded_save.is_empty():
		var loaded_edits: Dictionary = loaded_save["edits"]
		_check(loaded_edits.has(edit_coords), "saved edits survive the round trip")
		var dense_chunk: PackedByteArray = loaded_edits.get(edit_coords, PackedByteArray())
		_check(dense_chunk.size() == 4096 and int(dense_chunk[world._local_index(edit_cell, edit_coords)]) == int(world.block_ids[&"lumen_crystal"]), "expanded override chunk carries the edit")
		_check((loaded_save["edited_cells"] as Dictionary).get(edit_cell, -1) == int(world.block_ids[&"lumen_crystal"]), "sparse cell map re-seeds the journal")
	if DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(save_path)):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path.path_join("edits.bin")))
		DirAccess.remove_absolute(ProjectSettings.globalize_path(save_path.path_join("metadata.json")))

	if failures > 0:
		quit(1)
		return
	print("STREAMING CHECK PASS: spawn, determinism, unload/reload and chunk-delta saves verified")
	quit(0)
