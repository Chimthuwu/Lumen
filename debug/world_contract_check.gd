extends SceneTree

# Verifies the six gameplay-facing API endpoints the World Engine commits to:
# get_biome_at(cell), block_edited signal, is_chunk_ready(chunk_cell),
# set_generation_focus(cell), spawn_origin, and infinite-coordinate behaviour.

var main: Node
var failures := 0


func _check(condition: bool, label: String, detail := "") -> void:
	if not condition:
		failures += 1
		push_error("CONTRACT FAIL: %s %s" % [label, detail])
		return
	print("CONTRACT PASS: %s %s" % [label, detail])


func _initialize() -> void:
	main = load("res://scenes/world/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _wait_for(condition: Callable, limit: int) -> int:
	var frames := 0
	while not condition.call() and frames < limit:
		await process_frame
		frames += 1
	return frames


func _run() -> void:
	var world: VoxelWorld = main.world
	var frames := await _wait_for(func() -> bool: return world.is_generated, 1800)
	_check(world.is_generated, "spawn area streams in", "frames=%d" % frames)
	if not world.is_generated:
		quit(1)
		return

	# 1. get_biome_at(cell: Vector3i)
	BiomeManager.configure(world.world_seed)
	var spawn_cell := Vector3i(64, 30, 64)
	_check(world.get_biome_at(spawn_cell) == BiomeManager.ASHEN, "get_biome_at returns Vector3i contract value at spawn", "biome=%d" % world.get_biome_at(spawn_cell))
	var far := Vector3i(-940, 30, 733)
	_check(world.get_biome_at(far) == BiomeManager.dominant_biome(far.x, far.z), "get_biome_at works at negative coordinates")

	# 2. block_edited(cell, id) signal
	var signal_cells: Array = []
	var handler := func(cell: Vector3i, id: int) -> void:
		signal_cells.append([cell, id])
	world.block_edited.connect(handler)
	var edit_cell := Vector3i(70, world.get_surface_height(70, 62) + 3, 62)
	var torch_id := int(world.block_ids[&"torch"])
	var applied := world.set_block(edit_cell, torch_id)
	_check(applied and signal_cells.size() == 1 and signal_cells[0][0] == edit_cell and int(signal_cells[0][1]) == torch_id, "block_edited fires once with the edited cell and id", "count=%d" % signal_cells.size())
	world.set_block(edit_cell, torch_id)
	_check(signal_cells.size() == 1, "block_edited stays silent for no-op edits")
	world.set_block(edit_cell, world.air_id)
	world.block_edited.disconnect(handler)

	# 3. is_chunk_ready(chunk_cell) by CHUNK coordinate
	var spawn_chunk := world._chunk_of(Vector3i(64, 30, 64))
	var ready_chunk := Vector3i(9999, 1, 9999)
	_check(world.is_chunk_ready(spawn_chunk), "is_chunk_ready true for a loaded, lit, meshed chunk")
	_check(not world.is_chunk_ready(ready_chunk), "is_chunk_ready false for a distant chunk")

	# 4. set_generation_focus reorders the generation queue toward the buggy
	var camera_center := world._interest_position()
	var focus_column := Vector2i(12, 4)
	var near_camera := Vector3i(floori(camera_center.x / 16.0) + 2, 1, floori(camera_center.z / 16.0))
	var near_focus := Vector3i(focus_column.x - 1, 1, focus_column.y)
	world.generation_queue.clear()
	world.generation_set.clear()
	for coords in [near_camera, near_focus]:
		world.generation_set[coords] = true
		world.generation_queue.append(coords)
	world.set_generation_focus(Vector3i(focus_column.x * 16 + 8, 24, focus_column.y * 16 + 8))
	var picked: Vector3i = world._pop_nearest_generation()
	_check(picked == near_focus, "generation pops chase a fresh focus over the camera", "picked=%s" % str(picked))
	# Let the focus TTL lapse, then the queue must fall back to the camera.
	var expiry_start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - expiry_start < 700:
		await process_frame
	world.generation_queue.clear()
	world.generation_set.clear()
	for coords in [near_camera, near_focus]:
		world.generation_set[coords] = true
		world.generation_queue.append(coords)
	var stale := world._pop_nearest_generation()
	world.generation_queue.clear()
	world.generation_set.clear()
	_check(stale == near_camera, "queue order falls back toward the camera when the focus expires", "camera_pick=%s focus_pick=%s" % [str(stale), str(picked)])

	# 5. spawn_origin accessor
	_check(world.spawn_origin == Vector3i(BiomeManager.SPAWN_X, 0, BiomeManager.SPAWN_Z), "spawn_origin matches BiomeManager constants", "origin=%s" % str(world.spawn_origin))
	var height := world.spawn_height()
	_check(height == world.get_surface_height(BiomeManager.SPAWN_X, BiomeManager.SPAWN_Z) and height >= 4 and height < 58, "spawn_height matches the streamed surface", "y=%d" % height)

	# 6. Infinite/negative coordinates: travel to a far negative column and back.
	var target := Vector2i(-420, -380)
	var target_height := world.get_surface_height(target.x, target.y)
	main.player.position = Vector3(float(target.x) + 0.5, float(target_height + 2), float(target.y) + 0.5)
	var target_chunk := world._chunk_of(Vector3i(target.x, target_height, target.y))
	frames = await _wait_for(func() -> bool: return world.is_chunk_ready(target_chunk), 2400)
	_check(world.is_chunk_ready(target_chunk), "negative-coordinate terrain streams and meshes", "frames=%d" % frames)
	_check(world.is_solid(Vector3i(target.x, target_height, target.y)), "solid ground under the player at negative coords")
	_check(world.get_block_id(Vector3i(target.x, target_height + 20, target.y)) == world.air_id, "air above the surface at negative coords")
	var untouched_far := Vector3i(100000, 30, -100000)
	_check(world.get_block_id(untouched_far) == world.air_id and world.is_solid(untouched_far), "unloaded frontier reports air but blocks falls")

	# Biome fog modulation stays in a sane blended band wherever we ended up.
	_check(world.biome_fog_scale >= 0.9 and world.biome_fog_scale <= 2.7, "biome fog scale is blended", "scale=%.2f" % world.biome_fog_scale)

	if failures > 0:
		quit(1)
		return
	print("WORLD CONTRACT CHECK PASS: all six gameplay API endpoints verified")
	quit(0)
