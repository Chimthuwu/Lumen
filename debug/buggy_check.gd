extends SceneTree

# Headless audit for the dune buggy: model parts, fixed-step driving, a full-speed
# impact against a canyon wall, enter/exit handoff and the chase camera.

var main: Node
var failures := 0


func _initialize() -> void:
	main = load("res://scenes/world/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _check(condition: bool, label: String, detail := "") -> void:
	if not condition:
		failures += 1
		push_error("BUGGY CHECK FAIL: %s %s" % [label, detail])
		return
	print("BUGGY CHECK PASS: %s %s" % [label, detail])


func _run() -> void:
	var world: VoxelWorld = main.world
	var player: VoxelPlayer = main.player
	while not world.is_generated or not player.spawned:
		await process_frame
	while not main.buggy.parked_ready:
		await process_frame
	var buggy: DuneBuggy = main.buggy

	_check(buggy.model != null, "procedural buggy model exists")
	_check(buggy.wheel_pivots.size() == 4, "four wheels are rigged", "count=%d" % buggy.wheel_pivots.size())
	_check(buggy.model.get_node_or_null("CageFront") != null, "roll cage is present")
	_check(buggy.model.get_node_or_null("SeatBase") != null, "driver seat is present")
	_check(buggy.model.get_node_or_null("Nose") != null, "raised nose is present")
	_check(buggy.model.get_node_or_null("Headlight") != null, "headlights are present")
	_check(buggy.camera != null, "chase camera exists")

	var parked_position := buggy.global_position
	_check(not WorldGenerator.is_canyon_floor(floori(parked_position.x), floori(parked_position.z)), "buggy is parked on open ground", str(parked_position))

	# Enter: player hands over control and the chase camera takes over.
	player.position = parked_position + Vector3(2.0, 0.0, 0.0)
	var entered: bool = buggy.enter_vehicle()
	_check(entered, "E enters the buggy")
	_check(player.driving, "player control is transferred")
	_check(not player.visible, "player model is hidden while driving")
	_check(buggy.camera.current, "chase camera becomes current")
	await process_frame
	await process_frame
	var camera_distance := buggy.camera.global_position.distance_to(buggy.global_position)
	_check(camera_distance > 1.5 and camera_distance < 11.0, "chase camera sits behind the buggy", "distance=%.2f" % camera_distance)

	# Drive under the same fixed-step path used by the game.
	buggy.test_mode = true
	buggy.test_throttle = 1.0
	buggy.test_steer = 0.0
	buggy.test_handbrake = false
	var start_position := buggy.global_position
	var peak_height := start_position.y
	for step in range(180):
		buggy._simulate_step(1.0 / 120.0, 1.0, 0.0, false)
		peak_height = maxf(peak_height, buggy.position.y)
	var driven_distance := buggy.global_position.distance_to(start_position)
	_check(driven_distance > 3.0, "throttle drives the buggy", "distance=%.2f" % driven_distance)
	# Reverse-direction motion used to trip the ledge step-up every step and launch the chassis.
	_check(peak_height - start_position.y < 6.0, "throttle keeps the buggy on the ground", "climb=%.2f" % (peak_height - start_position.y))
	buggy._update_wheel_visuals(1.0 / 120.0)
	_check(absf(buggy.spin) > 1.0 and absf(buggy.wheel_spins[0].rotation.x - buggy.spin) < 0.001, "wheels spin with travel", "spin=%.2f" % buggy.spin)

	# Exit: control returns to the player and the buggy stays in the world.
	buggy.test_throttle = 0.0
	buggy.velocity = Vector3.ZERO
	buggy.exit_vehicle()
	_check(not player.driving, "E exits the buggy")
	_check(player.visible, "player model is visible again")
	_check(is_instance_valid(main.get_node("Buggy")), "buggy remains in the world after exit")
	var feet_cell := Vector3i(floori(player.position.x), floori(player.position.y + 0.2), floori(player.position.z))
	_check(not world.is_solid(feet_cell), "player exits into clear space", str(feet_cell))
	await create_timer(0.6).timeout
	_check(player.camera.current and not buggy.camera.current, "camera returns to the player")

	# Find a natural canyon wall with a flat six-block approach.
	var wall := _find_canyon_wall(world)
	_check(not wall.is_empty(), "found a canyon wall to crash into", str(wall))
	if wall.is_empty():
		_finish()
		return
	var approach_x: int = wall["x"]
	var approach_z: int = wall["z"]
	var floor_y: int = wall["floor_y"]
	var wall_x: int = wall["wall_x"]
	buggy.test_mode = true
	buggy.position = Vector3(float(approach_x) + 0.5, float(floor_y + 1), float(approach_z) + 0.5)
	buggy.yaw = -PI * 0.5
	buggy.rotation = Vector3(0.0, buggy.yaw, 0.0)
	buggy.velocity = Vector3(22.0, 0.0, 0.0)
	buggy.pitch = 0.0
	buggy.roll = 0.0
	for step in range(180):
		buggy._simulate_step(1.0 / 120.0, 1.0, 0.0, false)
	var stop_x := buggy.position.x
	_check(stop_x < float(wall_x) - 0.5, "full-speed impact stops at the canyon wall", "stopped_x=%.2f wall_x=%.2f" % [stop_x, float(wall_x)])
	_check(buggy.velocity.x < 2.0, "wall impact kills forward speed", "velocity_x=%.2f" % buggy.velocity.x)
	var chassis_center := buggy.position + Vector3(0.0, 0.55, 0.0)
	var front_cell := Vector3i(floori(chassis_center.x + 1.05), floori(chassis_center.y), floori(chassis_center.z))
	_check(not world.is_solid(front_cell), "chassis does not clip into the wall", str(front_cell))

	_finish()


func _find_canyon_wall(world: VoxelWorld) -> Dictionary:
	for z in range(4, 124):
		for x in range(4, 120):
			if not world.is_canyon_floor(x, z):
				continue
			var floor_y: int = world.get_surface_height(x, z)
			if floor_y > 17:
				continue
			var flat := true
			for offset in range(1, 5):
				if world.get_surface_height(x + offset, z) != floor_y or not world.is_canyon_floor(x + offset, z):
					flat = false
					break
			if not flat:
				continue
			var wall_x := x + 6
			if world.get_surface_height(wall_x, z) < floor_y + 4:
				continue
			var clear := true
			for offset in range(1, 5):
				for level in range(1, 3):
					if world.get_block_id(Vector3i(x + offset, floor_y + level, z)) != world.air_id:
						clear = false
						break
				if not clear:
					break
			if not clear:
				continue
			return {"x": x, "z": z, "floor_y": floor_y, "wall_x": wall_x}
	return {}


func _finish() -> void:
	if failures > 0:
		quit(1)
		return
	print("DUNE BUGGY CHECK PASS: driving, camera, wall impact and enter/exit verified")
	quit(0)
