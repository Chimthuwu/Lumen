extends Node
class_name GloomManager

signal gloom_changed(chunk_coords: Vector3i, value: float)

# Gloom is tracked per loaded chunk. Streaming means the set of chunks changes
# constantly, so levels live in dictionaries keyed by chunk coordinates rather
# than fixed arrays sized to the old 8x4x8 world.

const CONFIG: GloomConfig = preload("res://data/world/gloom_config.tres")

var world: VoxelWorld
var cycle: DayNightCycle
var levels: Dictionary = {}
var lit_fraction: Dictionary = {}
var sky_fraction: Dictionary = {}
var underground_fraction: Dictionary = {}
var rot_cursors: Dictionary = {}
var tick_accumulator := 0.0
var initialized := true
var pending_restore: Array = []


func _ready() -> void:
	world = get_parent().get_node("VoxelWorld") as VoxelWorld
	cycle = get_parent().get_node("DayNightCycle") as DayNightCycle
	world.chunk_light_changed.connect(_on_chunk_light_changed)
	world.chunk_loaded.connect(_on_chunk_loaded)
	world.gloom_noise_emitted.connect(_on_gloom_noise)
	world.gloom_manager = self


func _process(delta: float) -> void:
	if not world.is_generated:
		return
	tick_accumulator += delta
	if tick_accumulator < CONFIG.tick_seconds:
		return
	var elapsed := minf(tick_accumulator, CONFIG.tick_seconds * 2.0)
	tick_accumulator = 0.0
	_tick_gloom(elapsed)
	_process_rotting()


func _on_chunk_loaded(coords: Vector3i) -> void:
	if not levels.has(coords):
		levels[coords] = 0.0
	if not lit_fraction.has(coords):
		lit_fraction[coords] = 0.0
	_ensure_sky_stats(coords)


func _ensure_sky_stats(coords: Vector3i) -> void:
	if sky_fraction.has(coords):
		return
	var origin := coords * world.CHUNK_SIZE
	var sky_cells := 0
	for z in range(world.CHUNK_SIZE):
		for x in range(world.CHUNK_SIZE):
			var surface_y: int = world.get_surface_height(origin.x + x, origin.z + z)
			sky_cells += clampi(origin.y + world.CHUNK_SIZE - maxi(origin.y, surface_y), 0, world.CHUNK_SIZE)
	var exposed := float(sky_cells) / float(world.CHUNK_SIZE * world.CHUNK_SIZE * world.CHUNK_SIZE)
	sky_fraction[coords] = exposed
	underground_fraction[coords] = 1.0 - exposed


func _tick_gloom(delta: float) -> void:
	for key in world.chunk_records.keys():
		var coords: Vector3i = key
		_ensure_sky_stats(coords)
		var center := Vector3(coords * world.CHUNK_SIZE) + Vector3.ONE * (world.CHUNK_SIZE * 0.5)
		var sky_light: float = float(sky_fraction.get(coords, 0.0)) * cycle.ambient_level
		var dynamic_light := world.get_flashlight_level_at(center)
		if world.player_camera != null:
			var player_coords := world._chunk_of(Vector3i(
				floori(world.player_camera.global_position.x),
				floori(world.player_camera.global_position.y),
				floori(world.player_camera.global_position.z)))
			if player_coords == coords:
				dynamic_light = maxf(dynamic_light, world.get_flashlight_level_at(world.player_camera.global_position))
		var light_exposure := maxf(float(lit_fraction.get(coords, 0.0)), maxf(sky_light * (1.0 + CONFIG.daylight_relief), dynamic_light))
		var previous: float = float(levels.get(coords, 0.0))
		var value := previous
		if light_exposure >= 0.08:
			value = maxf(0.0, previous - CONFIG.lit_fall_per_second * light_exposure * delta)
		else:
			var multiplier: float = float(underground_fraction.get(coords, 1.0)) * (CONFIG.underground_multiplier - 1.0) + 1.0
			var sky: float = float(sky_fraction.get(coords, 0.0))
			if sky > 0.1 and cycle.phase_name == "night":
				multiplier *= CONFIG.night_multiplier
			elif sky > 0.1 and (cycle.phase_name == "twilight" or cycle.phase_name == "dawn"):
				multiplier *= lerpf(1.0, CONFIG.night_multiplier, cycle.phase_fraction)
			value = minf(1.0, previous + CONFIG.dark_rise_per_second * multiplier * delta)
		levels[coords] = value
		if not is_equal_approx(previous, value):
			gloom_changed.emit(coords, value)


func _on_chunk_light_changed(coords: Vector3i, light_data: PackedByteArray) -> void:
	var lit_cells := 0
	for level in light_data:
		if int(level) >= 3:
			lit_cells += 1
	lit_fraction[coords] = float(lit_cells) / float(light_data.size())


func _on_gloom_noise(world_position: Vector3, strength: float) -> void:
	var cell := Vector3i(floori(world_position.x), floori(world_position.y), floori(world_position.z))
	if not world._inside_world(cell):
		return
	var coords := world._chunk_of(cell)
	_add_noise(coords, strength * CONFIG.noise_to_gloom_scale)
	var directions: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i(0, 0, 1), Vector3i(0, 0, -1)]
	for direction in directions:
		var neighbor: Vector3i = coords + direction
		if world.chunk_records.has(neighbor):
			_add_noise(neighbor, strength * CONFIG.noise_to_gloom_scale * 0.25)


func _add_noise(coords: Vector3i, amount: float) -> void:
	levels[coords] = minf(1.0, float(levels.get(coords, 0.0)) + amount)
	gloom_changed.emit(coords, float(levels[coords]))


func _process_rotting() -> void:
	var converted := 0
	var keys: Array = world.chunk_records.keys()
	for coords in keys:
		if converted >= CONFIG.max_rots_per_tick:
			break
		if float(levels.get(coords, 0.0)) < CONFIG.rot_threshold:
			continue
		if _try_rot_block(coords):
			converted += 1


func _try_rot_block(coords: Vector3i) -> bool:
	var origin: Vector3i = coords * world.CHUNK_SIZE
	var cursor := int(rot_cursors.get(coords, 0))
	for offset in range(96):
		var local_index := (cursor + offset) % 4096
		var local := Vector3i(local_index % 16, int(local_index / 16) % 16, int(local_index / 256))
		var cell := origin + local
		var block_id := world.get_block_id(cell)
		var definition: BlockLightDef = world.block_defs[block_id]
		if definition.rotted_variant_id == &"" or not world.block_ids.has(definition.rotted_variant_id):
			continue
		if world.set_block(cell, world.block_ids[definition.rotted_variant_id]):
			rot_cursors[coords] = (local_index + 1) % 4096
			return true
	rot_cursors[coords] = (cursor + 96) % 4096
	return false


func get_level_for_cell(cell: Vector3i) -> float:
	if not world._inside_world(cell):
		return 0.0
	return float(levels.get(world._chunk_of(cell), 0.0))


func set_level_for_cell(cell: Vector3i, value: float) -> void:
	if not world._inside_world(cell):
		return
	var coords := world._chunk_of(cell)
	var clamped := clampf(value, 0.0, 1.0)
	if is_equal_approx(float(levels.get(coords, 0.0)), clamped):
		return
	levels[coords] = clamped
	gloom_changed.emit(coords, clamped)


func to_save_array() -> Array:
	var saved: Array = []
	for key in levels.keys():
		var coords: Vector3i = key
		saved.append({"c": [coords.x, coords.y, coords.z], "v": float(levels[key])})
	return saved


func restore_from_array(saved: Array) -> void:
	for entry in saved:
		if not entry is Dictionary or not entry.has("c"):
			continue
		var coords_array: Array = entry["c"]
		if coords_array.size() != 3:
			continue
		var coords := Vector3i(int(coords_array[0]), int(coords_array[1]), int(coords_array[2]))
		levels[coords] = clampf(float(entry.get("v", 0.0)), 0.0, 1.0)
