extends SceneTree

const MAIN_SCENE := "res://scenes/world/main.tscn"
const WALK_DISTANCE := 50.0
const FRAME_BUDGET_USEC := 20000


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed := load(MAIN_SCENE) as PackedScene
	if packed == null:
		push_error("M1 walk test could not load main scene")
		quit(1)
		return
	var main := packed.instantiate()
	root.add_child(main)
	var world: VoxelWorld = main.get_node("VoxelWorld")
	var player: VoxelPlayer = main.get_node("Player")
	var frames := 0
	while (not world.is_generated or not player.spawned) and frames < 12000:
		await process_frame
		frames += 1
	if not world.is_generated or not player.spawned:
		push_error("M1 walk test timed out waiting for the spawn area and player spawn")
		quit(1)
		return

	# The Ashen Flats are deliberately rugged, so carve a flat 51-column
	# corridor at spawn. This test measures traversal and streaming frame cost,
	# not whether a canyon wall happens to sit in the walking line.
	var lane_z := 64
	var start_cell_x := 64
	var base_y: int = world.get_surface_height(start_cell_x, lane_z)
	var stone_id := int(world.block_ids[&"stone"])
	for offset in range(51):
		var x := start_cell_x + offset
		for level in range(1, 11):
			var cell := Vector3i(x, base_y + level, lane_z)
			if world.get_block_id(cell) != world.air_id:
				world.set_block(cell, world.air_id)
		var floor_cell := Vector3i(x, base_y, lane_z)
		if not world.is_solid(floor_cell):
			world.set_block(floor_cell, stone_id)
	player.position = Vector3(Vector3(float(start_cell_x) + 0.5, float(base_y) + 1.0, float(lane_z) + 0.5).x, float(base_y) + 1.0, float(lane_z) + 0.5)
	player.rotation.y = 0.0
	player.velocity = Vector3.ZERO

	# Let the edited chunks re-light and re-mesh so the corridor has collision.
	for settle in range(40):
		await physics_frame

	var start_x: float = player.position.x
	var start_z: float = player.position.z
	var frame_count := 0
	var slow_count := 0
	var max_usec := 0
	Input.action_press("move_right")
	Input.action_press("sprint")
	while player.position.x - start_x < WALK_DISTANCE and frame_count < 1800:
		var frame_start := Time.get_ticks_usec()
		await process_frame
		var elapsed := Time.get_ticks_usec() - frame_start
		max_usec = maxi(max_usec, elapsed)
		if elapsed > FRAME_BUDGET_USEC:
			slow_count += 1
			print("M1 WALK frame %d: %d us (>20ms), position=%s" % [frame_count, elapsed, str(player.position)])
		frame_count += 1
	Input.action_release("move_right")
	Input.action_release("sprint")
	var distance: float = player.position.x - start_x
	print("M1 WALK distance=%.2f blocks frames=%d start_z=%.2f end_z=%.2f slow_frames=%d max_frame=%d us" % [distance, frame_count, start_z, player.position.z, slow_count, max_usec])
	if distance < WALK_DISTANCE:
		push_error("M1 WALK FAIL: only moved %.2f of %.2f blocks" % [distance, WALK_DISTANCE])
		quit(1)
		return
	print("M1 WALK PASS: completed 50-block traverse; >20ms frames logged above.")
	quit(0)
