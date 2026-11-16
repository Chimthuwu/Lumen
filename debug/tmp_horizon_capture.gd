extends SceneTree

var main: Node


func _initialize() -> void:
	main = load("res://scenes/world/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _capture(path: String) -> void:
	paused = false
	var pause_overlay := main.get_node_or_null("HUD/PauseOverlay")
	if pause_overlay != null:
		pause_overlay.visible = false
	await process_frame
	await process_frame
	var image := root.get_texture().get_image()
	image.save_png("res://debug/evidence/" + path)
	print("CAPTURED %s" % path)


func _river_x(z: float) -> float:
	return 94.0 + sin(z * 0.07) * 13.0 + sin(z * 0.023 + 2.1) * 6.0


func _run() -> void:
	while not main.world.is_generated or not main.player.spawned:
		await process_frame
	for frame in range(420):
		await process_frame
	main.get_node("HUD/DebugReadout").visible = false
	var player: Node3D = main.player
	var camera: Camera3D = player.get_node("Camera3D")
	player.set_physics_process(false)
	var world: VoxelWorld = main.world
	print("VEGETATION trees=%d grass=%d reeds=%d" % [world.vegetation.tree_count, world.vegetation.grass_count, world.vegetation.reed_count])

	var vista_start := Vector3(52.0, 42.0, 91.0)
	camera.global_position = vista_start
	camera.look_at(Vector3(75.0, 28.0, 62.0), Vector3.UP)
	await _capture("phase3_vista.png")

	# Stand in the riverbed itself, low enough that the banks frame the channel.
	var z_near := 112
	var z_far := 92
	var x_near := _river_x(float(z_near))
	var ground_near := float(world.heights[int(x_near) + z_near * 128])
	var x_far := _river_x(float(z_far))
	var ground_far := float(world.heights[int(x_far) + z_far * 128])
	camera.global_position = Vector3(x_near, ground_near + 12.0, float(z_near + 4))
	camera.look_at(Vector3(x_far, ground_far + 2.0, float(z_far - 14)), Vector3.UP)
	print("RIVER CAM x=%.1f y=%.1f -> x=%.1f ground=%.1f" % [x_near, ground_near + 12.0, x_far, ground_far])
	var reed_multimesh: MultiMesh = world.vegetation.reed_instance.multimesh
	var reeds_near := 0
	var nearest := 9999.0
	var nearest_position := Vector3.ZERO
	for index in range(reed_multimesh.instance_count):
		var reed_position := reed_multimesh.get_instance_transform(index).origin
		var distance := reed_position.distance_to(camera.global_position)
		if distance < 25.0:
			reeds_near += 1
		if distance < nearest:
			nearest = distance
			nearest_position = reed_position
	print("REEDS total=%d near25=%d nearest=%.1f at %s" % [reed_multimesh.instance_count, reeds_near, nearest, nearest_position])
	print("REED MESH aabb=%s count=%d visible=%s range=%.1f" % [str(reed_multimesh.mesh.get_aabb()), reed_multimesh.visible_instance_count, str(world.vegetation.reed_instance.visible), world.vegetation.reed_instance.visibility_range_end])
	await _capture("phase3_river.png")

	var river_camera_position := camera.global_position
	var river_look_target := Vector3(x_far, ground_far + 1.6, float(z_far))

	var original_reed_material := world.vegetation.reed_instance.material_override
	var debug_reed_material := StandardMaterial3D.new()
	debug_reed_material.albedo_color = Color(1.0, 0.0, 1.0)
	debug_reed_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var original_reed_mesh := reed_multimesh.mesh
	world.vegetation.reed_instance.material_override = debug_reed_material
	world.vegetation.reed_instance.multimesh.mesh = world.vegetation.grass_instance.multimesh.mesh
	camera.global_position = nearest_position + Vector3(4.0, 3.0, 8.0)
	camera.look_at(nearest_position + Vector3(0.0, 1.0, 0.0), Vector3.UP)
	await _capture("phase3_reeds_debug.png")
	reed_multimesh.mesh = original_reed_mesh
	world.vegetation.reed_instance.material_override = original_reed_material
	camera.global_position = river_camera_position
	camera.look_at(river_look_target, Vector3.UP)

	# Diagnostic: straight down over the channel to check its shape and reeds.
	camera.global_position = Vector3(96.0, 72.0, 96.0)
	camera.look_at(Vector3(96.0, 0.0, 96.01), Vector3.UP)
	await _capture("phase3_channel_top.png")

	camera.global_position = nearest_position + Vector3(0.0, 18.0, 0.0)
	camera.look_at(nearest_position + Vector3(0.01, 0.0, 0.0), Vector3.UP)
	await _capture("phase3_reeds_top.png")

	# Diagnostic: eye-level close-up of one reed clump, viewed along the bed.
	camera.global_position = nearest_position + Vector3(0.0, 1.5, 7.0)
	camera.look_at(nearest_position + Vector3(0.0, 1.0, 0.0), Vector3.UP)
	await _capture("phase3_reed_close.png")
	camera.global_position = river_camera_position
	camera.look_at(river_look_target, Vector3.UP)

	# High western rim looking east across the whole basin and beyond.
	camera.global_position = Vector3(18.0, 43.0, 64.0)
	camera.look_at(Vector3(120.0, 30.0, 64.0), Vector3.UP)
	await _capture("phase3_horizon.png")

	# Ground-level look at the skyline from spawn, where ridges should layer.
	camera.global_position = Vector3(64.0, float(world.heights[64 + 64 * 128]) + 1.8, 64.0)
	camera.look_at(Vector3(118.0, 33.0, 96.0), Vector3.UP)
	await _capture("phase3_skyline.png")

	main.cycle.elapsed_seconds = 420.0 + 120.0 + 420.0
	main.cycle._update_phase()
	camera.global_position = vista_start
	camera.look_at(Vector3(75.0, 28.0, 62.0), Vector3.UP)
	await _capture("phase3_night.png")

	main.cycle.elapsed_seconds = 60.0
	main.cycle._update_phase()
	quit(0)
