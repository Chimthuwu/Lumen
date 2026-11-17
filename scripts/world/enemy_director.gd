extends Node
class_name EnemyDirector

const CONFIG: EnemyConfig = preload("res://data/world/enemy_config.tres")
const GLOOM_CONFIG: GloomConfig = preload("res://data/world/gloom_config.tres")
const GloomlingScript = preload("res://scripts/enemies/gloomling.gd")
const LampEaterScript = preload("res://scripts/enemies/lamp_eater.gd")
const HollowScript = preload("res://scripts/enemies/hollow.gd")

var world: VoxelWorld
var gloom: GloomManager
var player: VoxelPlayer
var spawn_timer := 0.0
var rng := RandomNumberGenerator.new()
var chunk_cooldowns: Dictionary = {}

func _ready() -> void:
	world = get_parent().get_node("VoxelWorld") as VoxelWorld
	gloom = get_parent().get_node("GloomManager") as GloomManager
	player = get_parent().get_node("Player") as VoxelPlayer
	rng.randomize()

func _process(delta: float) -> void:
	if not world.is_generated or not player.spawned:
		return
	spawn_timer += delta
	for key in chunk_cooldowns.keys():
		chunk_cooldowns[key] = maxf(0.0, float(chunk_cooldowns[key]) - delta)
	if spawn_timer < CONFIG.spawn_tick_seconds:
		return
	spawn_timer = 0.0
	_spawn_from_gloom()

func _spawn_from_gloom() -> void:
	var enemies := get_tree().get_nodes_in_group("enemies")
	if enemies.size() >= CONFIG.max_active_enemies:
		return
	var candidates: Array[int] = []
	for chunk_index in range(world.CHUNK_COUNT):
		if gloom.levels[chunk_index] < GLOOM_CONFIG.spawn_threshold:
			continue
		if float(chunk_cooldowns.get(chunk_index, 0.0)) > 0.0:
			continue
		candidates.append(chunk_index)
	if candidates.is_empty():
		return
	candidates.shuffle()
	for chunk_index in candidates:
		var position := _find_spawn_position(chunk_index)
		if position == Vector3(-1.0, -1.0, -1.0):
			continue
		var hollow_count := 0
		for existing in enemies:
			if existing is Hollow:
				hollow_count += 1
		var hollow := hollow_count < CONFIG.max_active_hollows and rng.randf() < CONFIG.hollow_spawn_chance
		var lamp_eater := not hollow and rng.randf() < CONFIG.lamp_eater_spawn_chance
		var count := 1 if (lamp_eater or hollow) else mini(CONFIG.gloomling_group_size, CONFIG.max_active_enemies - enemies.size())
		for index in range(count):
			var enemy: GloomEnemy
			if hollow and index == 0:
				enemy = HollowScript.new()
				_configure_hollow(enemy)
			elif lamp_eater and index == 0:
				enemy = LampEaterScript.new()
				_configure_lamp_eater(enemy)
			else:
				enemy = GloomlingScript.new()
				_configure_gloomling(enemy)
			# The Hollow is too tall to risk the usual jitter embedding it in
			# terrain; it spawns exactly on the checked surface cell.
			var jitter := Vector3.ZERO if hollow else Vector3(rng.randf_range(-1.2, 1.2), 0.0, rng.randf_range(-1.2, 1.2))
			enemy.position = position + jitter
			get_parent().add_child(enemy)
		chunk_cooldowns[chunk_index] = CONFIG.spawn_cooldown_seconds
		return

func _find_spawn_position(chunk_index: int) -> Vector3:
	var surface_spawn := _find_surface_spawn_position(chunk_index)
	if surface_spawn != Vector3(-1.0, -1.0, -1.0):
		return surface_spawn
	return _find_cave_spawn_position(chunk_index)

func _find_surface_spawn_position(chunk_index: int) -> Vector3:
	var coords: Vector3i = world._chunk_coords(chunk_index)
	for attempt in range(12):
		var x := coords.x * 16 + rng.randi_range(1, 14)
		var z := coords.z * 16 + rng.randi_range(1, 14)
		var floor_y: int = world.get_surface_height(x, z)
		var spawn := Vector3(x + 0.5, floor_y + 1.05, z + 0.5)
		var distance := spawn.distance_to(player.position)
		if distance < CONFIG.min_spawn_distance or distance > CONFIG.max_spawn_distance:
			continue
		var surface_chunk := Vector3i(x / 16, floor_y / 16, z / 16)
		if world._chunk_index(surface_chunk) != chunk_index:
			continue
		var headroom_clear := true
		for level in range(1, 4):
			if world.get_block_id(Vector3i(x, floor_y + level, z)) != world.air_id:
				headroom_clear = false
				break
		if not headroom_clear:
			continue
		if _is_visible_from_player(spawn):
			continue
		return spawn
	return Vector3(-1.0, -1.0, -1.0)

func _find_cave_spawn_position(chunk_index: int) -> Vector3:
	var coords: Vector3i = world._chunk_coords(chunk_index)
	var min_y := coords.y * 16 + 1
	var max_y := coords.y * 16 + 14
	for attempt in range(16):
		var x := coords.x * 16 + rng.randi_range(1, 14)
		var z := coords.z * 16 + rng.randi_range(1, 14)
		var highest := mini(max_y, world.get_surface_height(x, z) - 2)
		if highest < min_y:
			continue
		var y := rng.randi_range(min_y, highest)
		var cell := Vector3i(x, y, z)
		if world.get_block_id(cell) != world.air_id or world.get_block_id(cell + Vector3i.UP) != world.air_id:
			continue
		if world.get_block_id(Vector3i(x, y - 1, z)) == world.air_id:
			continue
		var spawn := Vector3(x + 0.5, y + 0.05, z + 0.5)
		var distance := spawn.distance_to(player.position)
		if distance < CONFIG.min_spawn_distance or distance > CONFIG.max_spawn_distance:
			continue
		if world._chunk_index(Vector3i(x / 16, y / 16, z / 16)) != chunk_index:
			continue
		if _is_visible_from_player(spawn):
			continue
		return spawn
	return Vector3(-1.0, -1.0, -1.0)

func debug_spawn_gloomlings(count: int = 3) -> void:
	_debug_spawn(0, count)

func debug_spawn_lamp_eater() -> void:
	_debug_spawn(1, 1)

func debug_spawn_hollow() -> void:
	_debug_spawn(2, 1)


func _debug_spawn(kind: int, count: int) -> void:
	if not world.is_generated or not player.spawned:
		return
	for index in range(count):
		var cell_x := 0
		var cell_z := 0
		var found_column := false
		for attempt in range(8):
			var angle := rng.randf_range(0.0, TAU)
			var distance := rng.randf_range(5.0, 8.0)
			cell_x = floori(player.position.x + cos(angle) * distance)
			cell_z = floori(player.position.z + sin(angle) * distance)
			if world._inside_world(Vector3i(cell_x, 0, cell_z)):
				found_column = true
				break
		if not found_column:
			continue
		var surface: int = world.get_surface_height(cell_x, cell_z)
		var enemy: GloomEnemy
		match kind:
			2:
				enemy = HollowScript.new()
				_configure_hollow(enemy)
			1:
				enemy = LampEaterScript.new()
				_configure_lamp_eater(enemy)
			_:
				enemy = GloomlingScript.new()
				_configure_gloomling(enemy)
		enemy.position = Vector3(cell_x + 0.5, surface + 1.05, cell_z + 0.5)
		get_parent().add_child(enemy)


func _configure_gloomling(enemy: GloomEnemy) -> void:
	enemy.move_speed = CONFIG.gloomling_speed
	enemy.max_health = CONFIG.gloomling_health
	enemy.touch_damage = CONFIG.gloomling_damage
	enemy.attack_range = CONFIG.gloomling_attack_range
	enemy.dissolve_light_level = CONFIG.gloomling_dissolve_light


func _configure_lamp_eater(enemy: GloomEnemy) -> void:
	enemy.move_speed = CONFIG.lamp_eater_speed
	enemy.max_health = CONFIG.lamp_eater_health
	enemy.touch_damage = CONFIG.lamp_eater_damage
	enemy.attack_range = CONFIG.lamp_eater_attack_range
	enemy.dissolve_light_level = 15
	if enemy is LampEater:
		enemy.extinguish_distance = CONFIG.lamp_eater_extinguish_distance
		enemy.extinguish_seconds = CONFIG.lamp_eater_extinguish_seconds
		enemy.target_radius = CONFIG.lamp_eater_target_radius
		enemy.target_blocks = CONFIG.lamp_eater_target_blocks


func _configure_hollow(enemy: GloomEnemy) -> void:
	enemy.move_speed = CONFIG.hollow_speed
	enemy.max_health = CONFIG.hollow_health
	enemy.touch_damage = CONFIG.hollow_damage
	enemy.attack_range = CONFIG.hollow_attack_range
	enemy.attack_interval = CONFIG.hollow_attack_interval
	enemy.dissolve_light_level = 16

func _is_visible_from_player(target: Vector3) -> bool:
	var start := player.camera.global_position
	var offset := target - start
	var steps := ceili(offset.length() * 3.0)
	for step_index in range(1, steps):
		var point := start + offset * (float(step_index) / float(steps))
		var cell := Vector3i(floori(point.x), floori(point.y), floori(point.z))
		if world._inside_world(cell) and world.get_block_id(cell) != world.air_id:
			return false
	return true