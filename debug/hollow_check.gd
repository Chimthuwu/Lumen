extends SceneTree

const HollowScript = preload("res://scripts/enemies/hollow.gd")
const GloomlingScript = preload("res://scripts/enemies/gloomling.gd")
const Mesher = preload("res://scripts/world/chunk_mesher.gd")

var main: Node
var world: VoxelWorld
var player: VoxelPlayer
var director: EnemyDirector
var failures := 0


func _initialize() -> void:
	main = load("res://scenes/world/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _check(condition: bool, message: String) -> void:
	if condition:
		print("HOLLOW CHECK PASS: " + message)
	else:
		push_error("HOLLOW CHECK FAIL: " + message)
		failures += 1


func _wait_process(frames: int) -> void:
	for index in range(frames):
		await process_frame


func _wait_physics(frames: int) -> void:
	for index in range(frames):
		await physics_frame


func _run() -> void:
	while not main.world.is_generated or not main.player.spawned:
		await process_frame
	world = main.world
	player = main.player
	director = main.get_node("EnemyDirector")
	director.set_process(false)
	for existing in get_nodes_in_group("enemies"):
		existing.queue_free()
	await _wait_process(2)
	world.set_flashlight_enabled(false)
	director.debug_spawn_hollow()
	await _wait_process(2)
	var spawned: Hollow = null
	for enemy in get_nodes_in_group("enemies"):
		if enemy is Hollow:
			spawned = enemy
	_check(spawned != null and spawned.touch_damage == 50.0, "EnemyDirector spawns a configured Hollow")
	if spawned != null:
		spawned.queue_free()
	await _wait_process(2)

	_check_hushwoods()
	var lane := _pick_lane()
	if lane.is_empty():
		push_error("HOLLOW CHECK FAIL: no flat test lane found")
		quit(1)
		return
	player.position = lane["start"]
	player.velocity = Vector3.ZERO
	await _wait_physics(4)
	await _check_hollow_observation(lane)
	await _check_hollow_damage(lane)
	await _check_enemy_physics(lane)
	await _wait_process(2)

	print("HOLLOW CHECK SUMMARY: failures=%d" % failures)
	quit(1 if failures > 0 else 0)


func _check_hushwoods() -> void:
	var hush_columns := 0
	for value in world.biome_map:
		if value == 1:
			hush_columns += 1
	_check(hush_columns > 100, "Hushwoods biome columns=%d" % hush_columns)

	var pale_id := int(world.block_ids.get(&"pale_wood", -1))
	var soil_id := int(world.block_ids.get(&"hush_soil", -1))
	_check(pale_id >= 0 and soil_id >= 0, "pale_wood and hush_soil block definitions registered")
	var pale_blocks := 0
	var soil_blocks := 0
	for block_id in world.blocks:
		if block_id == pale_id:
			pale_blocks += 1
		elif block_id == soil_id:
			soil_blocks += 1
	_check(pale_blocks > 400, "Hushwoods pale wood blocks=%d" % pale_blocks)
	_check(soil_blocks > 1000, "Hushwoods dark soil blocks=%d" % soil_blocks)

	var hush_sites := 0
	for site in world.tree_sites:
		if world.biome_map[int(site["x"]) + int(site["z"]) * world.WORLD_X] == 1:
			hush_sites += 1
	_check(hush_sites == 0, "no brown MultiMesh tree sites inside Hushwoods (found %d)" % hush_sites)

	var hush_x := -1
	var hush_z := -1
	for z in range(3, 40):
		for x in range(3, 44):
			if world.biome_map[x + z * world.WORLD_X] != 1:
				continue
			var ground: int = world.heights[x + z * world.WORLD_X]
			if world.get_block_id(Vector3i(x, ground, z)) != soil_id:
				continue
			if world.get_block_id(Vector3i(x, ground + 1, z)) != world.air_id:
				continue
			hush_x = x
			hush_z = z
			break
		if hush_x >= 0:
			break
	_check(hush_x >= 0, "Hushwoods surface column uses hush_soil under open air")
	if hush_x < 0:
		return
	var ground: int = world.get_surface_height(hush_x, hush_z)
	var chunk_index: int = world._chunk_index(Vector3i(hush_x / 16, ground / 16, hush_z / 16))
	var snapshot: Dictionary = world._make_mesh_snapshot(chunk_index)
	var sky: PackedByteArray = snapshot["sky"]
	var local := Vector3i(hush_x % 16, ground % 16, hush_z % 16)
	var index := (local.x + 1) + (local.y + 1) * 18 + (local.z + 1) * 18 * 18
	_check(int(sky[index]) == 2, "Hushwoods surface snapshot is canopy-shaded (value=%d)" % int(sky[index]))
	var mesh: Dictionary = Mesher.build(snapshot["blocks"], snapshot["light"], sky, world.palette, world.air_id, world.fixture_ids, world.emissive_ids, [])
	var vertices: PackedVector3Array = mesh["vertices"]
	var uv2: PackedVector2Array = mesh["uv2"]
	var canopy_encoded := false
	for vertex_index in range(vertices.size()):
		var vertex := vertices[vertex_index]
		if absf(vertex.y - float(local.y + 1)) > 0.01:
			continue
		if absf(vertex.x - (float(local.x) + 0.5)) > 0.5 or absf(vertex.z - (float(local.z) + 0.5)) > 0.5:
			continue
		if uv2[vertex_index].x == 0.0 and absf(uv2[vertex_index].y - Mesher.HUSH_SUN_SHADE) < 0.001:
			canopy_encoded = true
			break
	_check(canopy_encoded, "Hushwoods geometry gets zero sky fill and dim sun")

	var open_x := 64
	var open_z := 64
	var open_ground: int = world.get_surface_height(open_x, open_z)
	var open_chunk: int = world._chunk_index(Vector3i(open_x / 16, open_ground / 16, open_z / 16))
	var open_snapshot: Dictionary = world._make_mesh_snapshot(open_chunk)
	var open_sky: PackedByteArray = open_snapshot["sky"]
	var open_local := Vector3i(open_x % 16, open_ground % 16, open_z % 16)
	var open_index := (open_local.x + 1) + (open_local.y + 1) * 18 + (open_local.z + 1) * 18 * 18
	_check(int(open_sky[open_index]) == 1, "open ground keeps normal sky exposure (value=%d)" % int(open_sky[open_index]))


func _pick_lane() -> Dictionary:
	for z in range(58, 71):
		for x in range(58, 66):
			var ground: int = world.heights[x + z * world.WORLD_X]
			var clear := true
			for offset in range(10):
				var cell_x := x + offset
				if cell_x >= world.WORLD_X - 1:
					clear = false
					break
				if world.heights[cell_x + z * world.WORLD_X] != ground:
					clear = false
					break
				for level in range(1, 4):
					if world.get_block_id(Vector3i(cell_x, ground + level, z)) != world.air_id:
						clear = false
						break
				if not clear:
					break
			if clear:
				return {
					"x": x,
					"z": z,
					"ground": ground,
					"start": Vector3(float(x) + 0.5, float(ground) + 1.02, float(z) + 0.5),
					"end": Vector3(float(x + 8) + 0.5, float(ground) + 1.0, float(z) + 0.5)
				}
	return {}


func _spawn_hollow(at: Vector3) -> Hollow:
	var hollow: Hollow = HollowScript.new()
	hollow.move_speed = 1.6
	hollow.max_health = 120.0
	hollow.touch_damage = 50.0
	hollow.attack_range = 1.8
	hollow.attack_interval = 2.0
	hollow.position = at
	main.add_child(hollow)
	return hollow


func _check_hollow_observation(lane: Dictionary) -> void:
	var hollow := _spawn_hollow(lane["end"])
	await _wait_physics(20)
	_check(hollow.on_floor, "Hollow lands under gravity")
	_check(absf(hollow.position.y - (float(lane["ground"]) + 1.0)) < 0.2, "Hollow rests on the surface (y=%.2f)" % hollow.position.y)

	var chest := hollow.global_position + Vector3.UP * 1.75
	player.camera.look_at(chest, Vector3.UP)
	await _wait_process(3)
	_check(hollow.observed, "Hollow is observed when the crosshair is on its body")
	_check(hollow.frozen, "observation freezes the Hollow")
	var frozen_position := hollow.global_position
	await _wait_physics(40)
	_check(hollow.global_position.distance_to(frozen_position) < 0.02, "frozen Hollow does not move")
	_check(hollow.on_floor, "frozen Hollow stays grounded")

	# Turn the camera 180 degrees: no crosshair and no flashlight.
	player.camera.rotate_y(PI)
	var before := hollow.global_position.distance_to(player.position)
	await _wait_physics(50)
	var after := hollow.global_position.distance_to(player.position)
	_check(not hollow.frozen, "Hollow unfreezes after being unobserved")
	_check(after < before - 0.1, "unobserved Hollow advances toward the player (%.2f -> %.2f)" % [before, after])

	# Flashlight-only: aim the crosshair beside the Hollow so only the wider
	# flashlight cone touches it.
	world.set_flashlight_enabled(true)
	hollow.position = lane["end"]
	hollow.velocity = Vector3.ZERO
	player.position = lane["start"]
	var side := player.camera.global_basis.x
	var flash_target := hollow.global_position + Vector3.UP * 1.75 + side * 1.4
	player.camera.look_at(flash_target, Vector3.UP)
	await _wait_process(3)
	_check(hollow.observed, "flashlight alone observes the Hollow (crosshair off-body)")
	_check(hollow.frozen, "flashlight freezes the Hollow")
	world.set_flashlight_enabled(false)

	# Wall between camera and Hollow: not observable through voxels.
	player.position = lane["start"]
	var wall_x: int = int(lane["x"]) + 4
	var wall_z: int = int(lane["z"])
	var ground: int = int(lane["ground"])
	var stone := int(world.block_ids[&"stone"])
	world.set_block(Vector3i(wall_x, ground + 1, wall_z), stone)
	world.set_block(Vector3i(wall_x, ground + 2, wall_z), stone)
	player.camera.look_at(hollow.global_position + Vector3.UP * 1.75, Vector3.UP)
	await _wait_process(20)
	_check(not hollow.observed, "solid wall blocks observation")
	world.set_block(Vector3i(wall_x, ground + 1, wall_z), world.air_id)
	world.set_block(Vector3i(wall_x, ground + 2, wall_z), world.air_id)
	hollow.queue_free()
	await _wait_process(2)


func _check_hollow_damage(lane: Dictionary) -> void:
	var hollow := _spawn_hollow(lane["end"])
	await _wait_physics(10)
	hollow.position = player.position + Vector3(0.0, 0.0, -1.2)
	hollow.velocity = Vector3.ZERO
	player.rotation = Vector3(0.0, PI, 0.0)
	player.camera.rotation = Vector3.ZERO
	player.health = 100.0
	player.damage_cooldown = 0.0
	hollow.frozen = false
	hollow.unobserve_timer = 1.0
	hollow.attack_cooldown = 0.0
	hollow._process(0.0)
	_check(absf(player.health - 50.0) < 0.01, "Hollow melee deals 50 damage (health=%.1f)" % player.health)
	hollow.queue_free()
	player.health = 100.0
	await _wait_process(2)


func _check_enemy_physics(lane: Dictionary) -> void:
	var ground: int = int(lane["ground"])
	var z: int = int(lane["z"])
	var start_x: int = int(lane["x"]) + 1
	var wall_x: int = int(lane["x"]) + 4
	var stone := int(world.block_ids[&"stone"])

	for level in range(1, 4):
		world.set_block(Vector3i(wall_x, ground + level, z), stone)

	var gloomling: Gloomling = GloomlingScript.new()
	gloomling.move_speed = 2.7
	gloomling.max_health = 100.0
	gloomling.dissolve_light_level = 16
	gloomling.position = Vector3(float(start_x) + 0.5, float(ground) + 2.5, float(z) + 0.5)
	main.add_child(gloomling)
	player.position = Vector3(float(wall_x) + 3.5, float(ground) + 1.05, float(z) + 0.5)
	player.velocity = Vector3.ZERO
	await _wait_physics(100)
	_check(gloomling.on_floor, "Gloomling falls and lands under gravity")
	_check(gloomling.global_position.x < float(wall_x) - 0.2, "Gloomling cannot pass through a voxel wall (x=%.2f wall=%d)" % [gloomling.global_position.x, wall_x])
	_check(gloomling.global_position.y < float(ground) + 1.3, "Gloomling is standing on the ground, not flying (y=%.2f)" % gloomling.global_position.y)
	gloomling.queue_free()

	for level in range(1, 4):
		world.set_block(Vector3i(wall_x, ground + level, z), world.air_id)
	await _wait_process(2)
