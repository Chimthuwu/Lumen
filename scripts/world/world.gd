extends Node3D
class_name VoxelWorld

signal gloom_noise_emitted(world_position: Vector3, strength: float)
signal chunk_light_changed(chunk_coords: Vector3i, light_data: PackedByteArray)
signal chunk_loaded(chunk_coords: Vector3i)
# Emitted for every successful player edit so the save system can journal
# sparse (cell -> id) changes instead of copying whole chunk arrays.
signal block_edited(cell: Vector3i, block_id: int)

# Infinite horizontal streaming. Y stays fixed at 64 blocks (4 chunks); X and Z
# are unbounded. Chunks live in a sparse dictionary keyed by chunk coordinates,
# generated in worker threads and unloaded with hysteresis once the interest
# point has moved away.

const WORLD_Y := 64
const CHUNK_SIZE := 16
const CHUNKS_Y := 4
const STREAM_RADIUS := 8
const UNLOAD_RADIUS := 10
const SPAWN_CHUNK := Vector2i(4, 4)
const SPAWN_READY_COLUMNS := 1
const MAX_WORKERS := 4
const MAX_MESH_COMMITS_PER_FRAME := 1
const MAX_MESH_DISPATCH_PER_FRAME := 1
const LIGHT_FRAME_BUDGET_USEC := 7000
const LIGHT_STEP_BATCH := 64
const FLASHLIGHT_RANGE := 12.0
const FLASHLIGHT_INNER_COS := 0.94
const FLASHLIGHT_OUTER_COS := 0.82
const FLASHLIGHT_INTENSITY := 0.85
const INVALID_CHUNK := Vector3i(-1000000, -1000000, -1000000)
# A generation focus expires this long after the last set_generation_focus()
# call, so streaming falls back to the camera the moment the buggy stops.
const GENERATION_FOCUS_TTL := 0.5
const FOCUS_DISK_RADIUS := 2
# Per-biome fog modulation (Ashen, Hush, Frost, Mire). The biome weight vector
# blends these continuously, so fog thickens across a border band instead of
# popping when the dominant biome flips.
const BIOME_FOG_SCALE := [1.0, 1.7, 1.45, 2.6]
const BIOME_FOG_TINT := [
	Color(1.0, 1.0, 1.0),
	Color(0.62, 0.70, 0.66),
	Color(0.78, 0.88, 1.0),
	Color(0.55, 0.72, 0.42),
]
const BLOCK_RESOURCE_PATHS := [
	"res://data/blocks/air.tres",
	"res://data/blocks/ashen_soil.tres",
	"res://data/blocks/dirt.tres",
	"res://data/blocks/stone.tres",
	"res://data/blocks/iron_ore.tres",
	"res://data/blocks/lumen_crystal.tres",
	"res://data/blocks/torch.tres",
	"res://data/blocks/mycelium.tres",
	"res://data/blocks/pale_bloom.tres",
	"res://data/blocks/rotted_dirt.tres",
	"res://data/blocks/rotted_ashen_soil.tres",
	"res://data/blocks/dead_wood.tres",
	"res://data/blocks/beacon.tres",
	"res://data/blocks/pale_wood.tres",
	"res://data/blocks/hush_soil.tres",
	"res://data/blocks/canyon_gravel.tres",
	"res://data/blocks/frost_snow.tres",
	"res://data/blocks/frost_ice.tres",
	"res://data/blocks/mire_mud.tres",
	"res://data/blocks/toxic_silt.tres",
]
const Generator = preload("res://scripts/world/world_generator.gd")
const VegetationScript = preload("res://scripts/world/vegetation.gd")
const ChunkScript = preload("res://scripts/world/chunk.gd")
const Mesher = preload("res://scripts/world/chunk_mesher.gd")
const LightPropagator = preload("res://scripts/light/light_propagator.gd")
const HorizonRidgesScript = preload("res://scripts/world/horizon_ridges.gd")
const WaterScript = preload("res://scripts/world/water_surface.gd")

@export var world_seed := 139732

var chunk_records: Dictionary = {}
var modified_chunks: Dictionary = {}
var stream_center := Vector2i(1 << 30, 1 << 30)
var stream_timer := 0.0
var vegetation: WorldVegetation
var water: ToxicWater
var horizon_ridges: Node3D
var sun_light: DirectionalLight3D
var block_defs: Array[BlockLightDef] = []
var block_ids: Dictionary = {}
var palette := PackedColorArray()
var fixture_ids: Dictionary = {}
var emissive_ids: Dictionary = {}
var air_id := 0
var attenuation := PackedByteArray()
var emitted_light := PackedByteArray()
var static_light_sources: Array[Dictionary] = []
var extinguished_sources: Dictionary = {}
var gloom_manager: GloomManager
var ambient_sky_level := 0.0
var flashlight_enabled := true
var initialized_light_chunks := 0
var light_updates_last_frame := 0
var light_work_frames := 0
var max_light_frame_usec := 0
var light_completion_logged := false
var generated_chunk_count := 0
var meshed_chunk_count := 0
var is_generated := false
var world_material: ShaderMaterial
var player_camera: Camera3D
var slow_frame_streak := 0

# Generation focus (contract endpoint 4): a world cell the streaming queues
# should chase, published by the buggy while driving.
var generation_focus_cell := Vector3i.ZERO
var generation_focus_stamp := -100.0

# Smoothed biome atmosphere (read by DayNightCycle when writing the fog).
var biome_fog_scale := 1.0
var biome_fog_tint := Color(1.0, 1.0, 1.0)

var generation_queue: Array[Vector3i] = []
var generation_set: Dictionary = {}
var generation_results: Dictionary = {}
var generation_task_ids := PackedInt64Array([-1, -1, -1, -1])
var generation_task_chunks: Array[Vector3i] = [INVALID_CHUNK, INVALID_CHUNK, INVALID_CHUNK, INVALID_CHUNK]
var light_queue: Array[Vector3i] = []
var light_set: Dictionary = {}
var active_light_coords := INVALID_CHUNK
var active_light_state: Dictionary = {}
var has_active_light := false
var mesh_queue: Array[Vector3i] = []
var mesh_set: Dictionary = {}
var mesh_results: Dictionary = {}
var mesh_task_ids := PackedInt64Array([-1, -1, -1, -1])
var mesh_task_chunks: Array[Vector3i] = [INVALID_CHUNK, INVALID_CHUNK, INVALID_CHUNK, INVALID_CHUNK]
var mesh_task_revisions := PackedInt32Array([-1, -1, -1, -1])
var worker_mutex := Mutex.new()


func _ready() -> void:
	_load_block_palette()
	BiomeManager.configure(world_seed)
	player_camera = get_parent().get_node_or_null("Player/Camera3D") as Camera3D
	sun_light = get_parent().get_node_or_null("DirectionalLight3D") as DirectionalLight3D
	vegetation = VegetationScript.new()
	vegetation.name = "Vegetation"
	add_child(vegetation)
	vegetation.configure(AABB(Vector3(-100000.0, -8.0, -100000.0), Vector3(200000.0, 96.0, 200000.0)))
	water = WaterScript.new()
	water.name = "ToxicWater"
	add_child(water)
	horizon_ridges = HorizonRidgesScript.new()
	horizon_ridges.name = "HorizonRidges"
	add_child(horizon_ridges)
	horizon_ridges.build(world_seed)
	_update_streaming(true)


func _exit_tree() -> void:
	for slot in range(MAX_WORKERS):
		if generation_task_ids[slot] != -1:
			WorkerThreadPool.wait_for_task_completion(generation_task_ids[slot])
			generation_task_ids[slot] = -1
		if mesh_task_ids[slot] != -1:
			WorkerThreadPool.wait_for_task_completion(mesh_task_ids[slot])
			mesh_task_ids[slot] = -1


func _process(delta: float) -> void:
	_check_slow_frame(delta)
	_update_biome_atmosphere(delta)
	stream_timer += delta
	if stream_timer >= 0.2:
		stream_timer = 0.0
		_update_streaming(false)
	_process_generation()
	_process_light_updates()
	_process_extinguished_lights(delta)
	_process_mesh_pipeline()
	_update_flashlight_uniforms()


func _load_block_palette() -> void:
	world_material = ShaderMaterial.new()
	world_material.shader = load("res://shaders/light_dither.gdshader") as Shader
	world_material.set_shader_parameter("dither_bands", 8.0)
	world_material.set_shader_parameter("flashlight_enabled", flashlight_enabled)
	world_material.set_shader_parameter("flashlight_range", FLASHLIGHT_RANGE)
	world_material.set_shader_parameter("flashlight_inner_cos", FLASHLIGHT_INNER_COS)
	world_material.set_shader_parameter("flashlight_outer_cos", FLASHLIGHT_OUTER_COS)
	world_material.set_shader_parameter("flashlight_intensity", FLASHLIGHT_INTENSITY)
	world_material.set_shader_parameter("ambient_sky_level", ambient_sky_level)
	world_material.set_shader_parameter("sun_strength", 0.0)
	world_material.set_shader_parameter("detail_texture", _create_detail_texture())
	world_material.set_shader_parameter("detail_strength", 0.8)
	for path in BLOCK_RESOURCE_PATHS:
		var definition := load(path) as BlockLightDef
		if definition == null:
			push_error("Could not load block definition: %s" % path)
			continue
		var block_index := block_defs.size()
		block_defs.append(definition)
		block_ids[definition.block_id] = block_index
		var color := definition.albedo
		color.a = 1.0
		palette.append(color)
		attenuation.append(definition.attenuation)
		emitted_light.append(definition.emitted_light)
		if definition.block_id == &"air":
			air_id = block_index
	fixture_ids.clear()
	for fixture in [&"torch", &"pale_bloom", &"mycelium", &"lumen_crystal", &"beacon"]:
		if block_ids.has(fixture):
			fixture_ids[int(block_ids[fixture])] = fixture
	emissive_ids.clear()
	for index in range(block_defs.size()):
		if block_defs[index].emitted_light > 0:
			emissive_ids[index] = true


func _create_detail_texture() -> ImageTexture:
	# One tile per world unit. The dark border becomes grout at block seams;
	# the interior carries pixel grain, speckles and hairline cracks.
	var size := 64
	var image := Image.create(size, size, false, Image.FORMAT_RGB8)
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.seed = 4471
	noise.frequency = 0.11
	noise.fractal_octaves = 3
	var rng := RandomNumberGenerator.new()
	rng.seed = 771
	for y in range(size):
		for x in range(size):
			var value := 0.86 + noise.get_noise_2d(float(x), float(y)) * 0.16
			if rng.randf() < 0.06:
				value -= 0.14
			if absf(noise.get_noise_2d(float(x) * 2.7, float(y) * 2.7)) < 0.04:
				value *= 0.76
			var edge := minf(minf(float(x), float(size - 1 - x)), minf(float(y), float(size - 1 - y)))
			if edge < 2.0:
				value *= 0.56
			elif edge < 4.0:
				value *= 0.86
			value = clampf(value, 0.0, 1.0)
			image.set_pixel(x, y, Color(value, value, value))
	return ImageTexture.create_from_image(image)


# --- Streaming --------------------------------------------------------------

func _interest_position() -> Vector3:
	# Until the spawn area is ready the camera still sits at the origin, so use
	# the spawn column as the streaming/light priority point.
	if is_generated and is_instance_valid(player_camera):
		return player_camera.global_position
	return Vector3(float(SPAWN_CHUNK.x * CHUNK_SIZE + 8), 32.0, float(SPAWN_CHUNK.y * CHUNK_SIZE + 8))


# Contract endpoint 4: while a fresh focus exists (the buggy publishes one
# every tick while driving), queue ordering chases the focus instead of the
# camera, so a fast approach never outruns the generator.
func set_generation_focus(cell: Vector3i) -> void:
	generation_focus_cell = cell
	generation_focus_stamp = float(Time.get_ticks_msec()) * 0.001


func _focus_is_fresh() -> bool:
	return float(Time.get_ticks_msec()) * 0.001 - generation_focus_stamp < GENERATION_FOCUS_TTL


func _priority_position() -> Vector3:
	if _focus_is_fresh():
		return Vector3(generation_focus_cell) + Vector3(0.5, 0.0, 0.5)
	return _interest_position()


func _update_streaming(force: bool) -> void:
	var position := _interest_position()
	var center := Vector2i(floori(position.x / float(CHUNK_SIZE)), floori(position.z / float(CHUNK_SIZE)))
	if not force and center == stream_center:
		return
	stream_center = center
	for offset_z in range(-STREAM_RADIUS, STREAM_RADIUS + 1):
		for offset_x in range(-STREAM_RADIUS, STREAM_RADIUS + 1):
			if offset_x * offset_x + offset_z * offset_z > STREAM_RADIUS * STREAM_RADIUS:
				continue
			var column := center + Vector2i(offset_x, offset_z)
			for chunk_y in range(CHUNKS_Y):
				var coords := Vector3i(column.x, chunk_y, column.y)
				if not chunk_records.has(coords) and not generation_set.has(coords):
					_queue_generation(coords)
	# Bow wave: when the buggy drags the focus away from the camera, make sure
	# the columns around the focus are queued even if the camera disk has not
	# grown to cover them yet.
	if _focus_is_fresh():
		var focus_column := Vector2i(floori(float(generation_focus_cell.x) / CHUNK_SIZE), floori(float(generation_focus_cell.z) / CHUNK_SIZE))
		for offset_z in range(-FOCUS_DISK_RADIUS, FOCUS_DISK_RADIUS + 1):
			for offset_x in range(-FOCUS_DISK_RADIUS, FOCUS_DISK_RADIUS + 1):
				if offset_x * offset_x + offset_z * offset_z > FOCUS_DISK_RADIUS * FOCUS_DISK_RADIUS:
					continue
				var column := focus_column + Vector2i(offset_x, offset_z)
				for chunk_y in range(CHUNKS_Y):
					var coords := Vector3i(column.x, chunk_y, column.y)
					if not chunk_records.has(coords) and not generation_set.has(coords):
						_queue_generation(coords)
	_unload_far_chunks(center)
	vegetation.update_region(world_seed, center * CHUNK_SIZE, 96)
	# The water scan is only worth paying for near The Mire; rebuilding it over
	# every Ashen or Frostfall column caused visible main-thread hitches.
	var center_weights := BiomeManager.get_weights(center.x * CHUNK_SIZE + 8, center.y * CHUNK_SIZE + 8)
	if center_weights[BiomeManager.MIRE] > 0.1:
		water.update_region(center, 96)
	else:
		water.clear()
	if horizon_ridges != null:
		horizon_ridges.position = Vector3(position.x, 0.0, position.z)


func _queue_generation(coords: Vector3i) -> void:
	if coords.y < 0 or coords.y >= CHUNKS_Y or generation_set.has(coords):
		return
	generation_set[coords] = true
	generation_queue.append(coords)


func _pop_nearest_generation() -> Vector3i:
	if generation_queue.is_empty():
		return INVALID_CHUNK
	var position := _priority_position()
	var best_index := 0
	var best_distance := INF
	for index in range(generation_queue.size()):
		var coords := generation_queue[index]
		var center := Vector3(coords) * float(CHUNK_SIZE) + Vector3.ONE * (CHUNK_SIZE * 0.5)
		var distance := center.distance_squared_to(position)
		if distance < best_distance:
			best_distance = distance
			best_index = index
	var coords := generation_queue[best_index]
	generation_queue.remove_at(best_index)
	generation_set.erase(coords)
	return coords


func _fill_generation_workers() -> void:
	for slot in range(MAX_WORKERS):
		if generation_task_ids[slot] != -1:
			continue
		var coords := _pop_nearest_generation()
		if coords == INVALID_CHUNK:
			return
		generation_task_chunks[slot] = coords
		generation_task_ids[slot] = WorkerThreadPool.add_task(Callable(self, "_generate_chunk_task").bind(coords))


func _generate_chunk_task(coords: Vector3i) -> void:
	var modifications: PackedByteArray = modified_chunks.get(coords, PackedByteArray())
	var generated := Generator.generate_chunk(coords, world_seed, block_ids, modifications)
	worker_mutex.lock()
	generation_results[coords] = generated
	worker_mutex.unlock()


func _process_generation() -> void:
	for slot in range(MAX_WORKERS):
		var task_id := generation_task_ids[slot]
		if task_id == -1 or not WorkerThreadPool.is_task_completed(task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(task_id)
		var coords := generation_task_chunks[slot]
		var chunk_data: PackedByteArray = generation_results.get(coords, PackedByteArray())
		generation_results.erase(coords)
		generation_task_ids[slot] = -1
		generation_task_chunks[slot] = INVALID_CHUNK
		if chunk_data.size() != CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE:
			continue
		if _column_distance(coords, stream_center) > UNLOAD_RADIUS:
			continue
		if chunk_records.has(coords):
			continue
		_install_chunk(coords, chunk_data)
	_fill_generation_workers()


func _install_chunk(coords: Vector3i, blocks: PackedByteArray) -> void:
	var chunk = ChunkScript.new()
	chunk.name = "Chunk_%d_%d_%d" % [coords.x, coords.y, coords.z]
	chunk.configure(coords, Vector3(coords) * float(CHUNK_SIZE), world_material)
	add_child(chunk)
	var light := PackedByteArray()
	light.resize(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE)
	light.fill(0)
	chunk_records[coords] = {
		"blocks": blocks,
		"light": light,
		"light_ready": false,
		"revision": 0,
		"mesh_installed": false,
		"node": chunk,
		"sources": [],
	}
	generated_chunk_count += 1
	_collect_chunk_sources(coords)
	_enqueue_light(coords)
	_queue_mesh(coords)
	for offset in _neighbor_offsets(1):
		var neighbor: Vector3i = coords + offset
		if chunk_records.has(neighbor):
			_enqueue_light(neighbor)
			_queue_mesh(neighbor)
	chunk_loaded.emit(coords)


func _unload_far_chunks(center: Vector2i) -> void:
	var to_remove: Array[Vector3i] = []
	for key in chunk_records.keys():
		var coords: Vector3i = key
		if _column_distance(coords, center) <= UNLOAD_RADIUS:
			continue
		if generation_set.has(coords) or mesh_set.has(coords):
			continue
		if has_active_light and active_light_coords == coords:
			continue
		to_remove.append(coords)
	for coords in to_remove:
		_unload_chunk(coords)
	if not to_remove.is_empty() and not light_completion_logged:
		light_completion_logged = true
		print("WORLD streaming: first unload batch=%d loaded=%d" % [to_remove.size(), chunk_records.size()])


func _unload_chunk(coords: Vector3i) -> void:
	var record: Dictionary = chunk_records.get(coords, {})
	if record.is_empty():
		return
	for cell in record.get("sources", []):
		_remove_static_light_source(cell)
	if bool(record["light_ready"]):
		initialized_light_chunks = maxi(0, initialized_light_chunks - 1)
	if bool(record["mesh_installed"]):
		meshed_chunk_count = maxi(0, meshed_chunk_count - 1)
	var node = record["node"]
	if is_instance_valid(node):
		node.queue_free()
	chunk_records.erase(coords)


func _column_distance(coords: Vector3i, center: Vector2i) -> int:
	return maxi(absi(coords.x - center.x), absi(coords.z - center.y))


func _neighbor_offsets(radius: int) -> Array[Vector3i]:
	var offsets: Array[Vector3i] = []
	for z in range(-radius, radius + 1):
		for y in range(-radius, radius + 1):
			for x in range(-radius, radius + 1):
				if x == 0 and y == 0 and z == 0:
					continue
				offsets.append(Vector3i(x, y, z))
	return offsets


func _all_neighbors_loaded(coords: Vector3i) -> bool:
	for offset in _neighbor_offsets(1):
		var neighbor: Vector3i = coords + offset
		# Above and below the fixed 64-block column is solid world, not a
		# missing chunk, so those neighbours never need to stream in.
		if neighbor.y < 0 or neighbor.y >= CHUNKS_Y:
			continue
		if not chunk_records.has(neighbor):
			return false
	return true


func _face_neighbors_loaded(coords: Vector3i) -> bool:
	for offset in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
		var neighbor: Vector3i = coords + offset
		if neighbor.y < 0 or neighbor.y >= CHUNKS_Y:
			continue
		if not chunk_records.has(neighbor):
			return false
	return true


func _check_spawn_ready() -> void:
	if is_generated:
		return
	for offset_z in range(-SPAWN_READY_COLUMNS, SPAWN_READY_COLUMNS + 1):
		for offset_x in range(-SPAWN_READY_COLUMNS, SPAWN_READY_COLUMNS + 1):
			for chunk_y in range(CHUNKS_Y):
				var coords := Vector3i(SPAWN_CHUNK.x + offset_x, chunk_y, SPAWN_CHUNK.y + offset_z)
				var record: Dictionary = chunk_records.get(coords, {})
				if record.is_empty() or not bool(record["light_ready"]) or not bool(record["mesh_installed"]):
					return
	is_generated = true
	print("WORLD spawn ready: loaded=%d generated=%d lit=%d meshed=%d" % [chunk_records.size(), generated_chunk_count, initialized_light_chunks, meshed_chunk_count])


# --- Light ------------------------------------------------------------------

func _enqueue_light(coords: Vector3i) -> void:
	if coords.y < 0 or coords.y >= CHUNKS_Y or light_set.has(coords):
		return
	var record: Dictionary = chunk_records.get(coords, {})
	if record.is_empty() or bool(record["light_ready"]):
		return
	light_set[coords] = true
	light_queue.append(coords)


func _pop_light() -> Vector3i:
	if light_queue.is_empty():
		return INVALID_CHUNK
	var position := _priority_position()
	var best_index := 0
	var best_distance := INF
	for index in range(light_queue.size()):
		var coords := light_queue[index]
		var center := Vector3(coords) * float(CHUNK_SIZE) + Vector3.ONE * (CHUNK_SIZE * 0.5)
		var distance := center.distance_squared_to(position)
		if distance < best_distance:
			best_distance = distance
			best_index = index
	var coords := light_queue[best_index]
	light_queue.remove_at(best_index)
	light_set.erase(coords)
	return coords


func _process_light_updates() -> void:
	light_updates_last_frame = 0
	var frame_start_usec := Time.get_ticks_usec()
	while Time.get_ticks_usec() - frame_start_usec < LIGHT_FRAME_BUDGET_USEC:
		if not has_active_light:
			var coords := _pop_light()
			if coords == INVALID_CHUNK:
				break
			var record: Dictionary = chunk_records.get(coords, {})
			if record.is_empty() or bool(record["light_ready"]):
				continue
			if not _all_neighbors_loaded(coords):
				# It will be queued again when the missing neighbour installs.
				continue
			var padded := _build_padded_blocks(coords)
			active_light_state = LightPropagator.begin_chunk(padded, coords, static_light_sources, attenuation, int(block_ids[&"stone"]))
			active_light_coords = coords
			has_active_light = true
		if not LightPropagator.advance_chunk(active_light_state, LIGHT_STEP_BATCH):
			continue
		var coords := active_light_coords
		var new_light: PackedByteArray = active_light_state["result"]
		has_active_light = false
		active_light_coords = INVALID_CHUNK
		active_light_state.clear()
		var record: Dictionary = chunk_records.get(coords, {})
		if record.is_empty():
			continue
		var was_initialized := bool(record["light_ready"])
		record["light"] = new_light
		record["light_ready"] = true
		record["revision"] = int(record["revision"]) + 1
		chunk_light_changed.emit(coords, new_light)
		_queue_mesh(coords)
		for offset in [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i(0, 0, 1), Vector3i(0, 0, -1)]:
			_queue_mesh(coords + offset)
		if not was_initialized:
			initialized_light_chunks += 1
			light_updates_last_frame += 1
		if not light_completion_logged and initialized_light_chunks > 0 and is_generated:
			pass
	var frame_work_usec := Time.get_ticks_usec() - frame_start_usec
	if frame_work_usec > 0:
		light_work_frames += 1
		max_light_frame_usec = maxi(max_light_frame_usec, frame_work_usec)
	_check_spawn_ready()


func _build_padded_blocks(coords: Vector3i) -> PackedByteArray:
	var padded := PackedByteArray()
	padded.resize(LightPropagator.PADDED_VOLUME)
	padded.fill(int(block_ids[&"stone"]))
	var origin := coords * CHUNK_SIZE - Vector3i(LightPropagator.LIGHT_RANGE, LightPropagator.LIGHT_RANGE, LightPropagator.LIGHT_RANGE)
	var limit := LightPropagator.PADDED_SIZE
	var chunk_low := Vector3i(floori(float(origin.x) / CHUNK_SIZE), floori(float(origin.y) / CHUNK_SIZE), floori(float(origin.z) / CHUNK_SIZE))
	var chunk_high := Vector3i(floori(float(origin.x + limit - 1) / CHUNK_SIZE), floori(float(origin.y + limit - 1) / CHUNK_SIZE), floori(float(origin.z + limit - 1) / CHUNK_SIZE))
	for chunk_z in range(chunk_low.z, chunk_high.z + 1):
		for chunk_y in range(chunk_low.y, chunk_high.y + 1):
			for chunk_x in range(chunk_low.x, chunk_high.x + 1):
				var neighbor := Vector3i(chunk_x, chunk_y, chunk_z)
				var record: Dictionary = chunk_records.get(neighbor, {})
				if record.is_empty():
					continue
				var neighbor_origin := neighbor * CHUNK_SIZE
				var x_start := maxi(origin.x, neighbor_origin.x)
				var x_end := mini(origin.x + limit, neighbor_origin.x + CHUNK_SIZE)
				var y_start := maxi(origin.y, neighbor_origin.y)
				var y_end := mini(origin.y + limit, neighbor_origin.y + CHUNK_SIZE)
				var z_start := maxi(origin.z, neighbor_origin.z)
				var z_end := mini(origin.z + limit, neighbor_origin.z + CHUNK_SIZE)
				if x_start >= x_end or y_start >= y_end or z_start >= z_end:
					continue
				var source_blocks: PackedByteArray = record["blocks"]
				for world_z in range(z_start, z_end):
					for world_y in range(y_start, y_end):
						var source_start := (x_start - neighbor_origin.x) + (world_y - neighbor_origin.y) * CHUNK_SIZE + (world_z - neighbor_origin.z) * CHUNK_SIZE * CHUNK_SIZE
						var target_start := (x_start - origin.x) + (world_y - origin.y) * limit + (world_z - origin.z) * limit * limit
						for offset_x in range(x_end - x_start):
							padded[target_start + offset_x] = source_blocks[source_start + offset_x]
	return padded


func _sources_for_chunk(coords: Vector3i) -> Array:
	return static_light_sources


func _collect_chunk_sources(coords: Vector3i) -> void:
	var record: Dictionary = chunk_records.get(coords, {})
	if record.is_empty():
		return
	var blocks: PackedByteArray = record["blocks"]
	var chunk_origin := coords * CHUNK_SIZE
	var sources: Array = []
	for index in range(blocks.size()):
		var block_id := int(blocks[index])
		var level := int(emitted_light[block_id])
		if level <= 0:
			continue
		var cell := chunk_origin + Vector3i(index % CHUNK_SIZE, int(index / CHUNK_SIZE) % CHUNK_SIZE, int(index / (CHUNK_SIZE * CHUNK_SIZE)))
		if extinguished_sources.has(cell):
			continue
		sources.append(cell)
		static_light_sources.append({"cell": cell, "level": level, "cool": block_id == int(block_ids[&"lumen_crystal"])})
	record["sources"] = sources


func _remove_static_light_source(cell: Vector3i) -> void:
	for index in range(static_light_sources.size() - 1, -1, -1):
		if static_light_sources[index]["cell"] == cell:
			static_light_sources.remove_at(index)


func _update_static_light_source(cell: Vector3i, new_block_id: int) -> void:
	_remove_static_light_source(cell)
	if extinguished_sources.has(cell):
		return
	var level := int(emitted_light[new_block_id])
	if level > 0:
		static_light_sources.append({"cell": cell, "level": level, "cool": new_block_id == int(block_ids[&"lumen_crystal"])})
		var coords := _chunk_of(cell)
		var record: Dictionary = chunk_records.get(coords, {})
		if not record.is_empty():
			var sources: Array = record["sources"]
			if not sources.has(cell):
				sources.append(cell)


func extinguish_light_source(cell: Vector3i, duration: float) -> bool:
	if not _inside_world(cell) or duration <= 0.0:
		return false
	var block_id := get_block_id(cell)
	if emitted_light[block_id] <= 0:
		return false
	extinguished_sources[cell] = duration
	_update_static_light_source(cell, block_id)
	_queue_light_region(cell)
	return true


func _process_extinguished_lights(delta: float) -> void:
	for cell in extinguished_sources.keys():
		var remaining := float(extinguished_sources[cell]) - delta
		if remaining > 0.0:
			extinguished_sources[cell] = remaining
			continue
		extinguished_sources.erase(cell)
		var block_id := get_block_id(cell)
		if emitted_light[block_id] > 0:
			_update_static_light_source(cell, block_id)
			_queue_light_region(cell)


func _queue_light_region(cell: Vector3i) -> void:
	var low := _chunk_of(cell - Vector3i(15, 15, 15))
	var high := _chunk_of(cell + Vector3i(15, 15, 15))
	if has_active_light:
		var active := active_light_coords
		if active.x >= low.x and active.x <= high.x and active.y >= low.y and active.y <= high.y and active.z >= low.z and active.z <= high.z:
			has_active_light = false
			active_light_coords = INVALID_CHUNK
			active_light_state.clear()
			_enqueue_light(active)
	for chunk_y in range(maxi(0, low.y), mini(CHUNKS_Y - 1, high.y) + 1):
		for chunk_z in range(low.z, high.z + 1):
			for chunk_x in range(low.x, high.x + 1):
				_enqueue_light(Vector3i(chunk_x, chunk_y, chunk_z))


# --- Meshing ----------------------------------------------------------------

func _queue_mesh(coords: Vector3i) -> void:
	if mesh_set.has(coords):
		return
	var record: Dictionary = chunk_records.get(coords, {})
	if record.is_empty() or not bool(record["light_ready"]):
		return
	mesh_set[coords] = true
	mesh_queue.append(coords)


func _pop_mesh() -> Vector3i:
	if mesh_queue.is_empty():
		return INVALID_CHUNK
	var coords := mesh_queue[0]
	mesh_queue.remove_at(0)
	mesh_set.erase(coords)
	return coords


func _fill_mesh_workers() -> void:
	for slot in range(MAX_WORKERS):
		if mesh_task_ids[slot] != -1:
			continue
		var coords := _pop_mesh()
		if coords == INVALID_CHUNK:
			return
		var record: Dictionary = chunk_records.get(coords, {})
		if record.is_empty() or not bool(record["light_ready"]):
			continue
		if not _face_neighbors_loaded(coords):
			continue
		var revision := int(record["revision"])
		var snapshot := _make_mesh_snapshot(coords)
		mesh_task_chunks[slot] = coords
		mesh_task_revisions[slot] = revision
		var chunk_sources := _light_sources_for_chunk(coords)
		mesh_task_ids[slot] = WorkerThreadPool.add_task(Callable(self, "_mesh_chunk_task").bind(coords, revision, snapshot["blocks"], snapshot["light"], snapshot["sky"], chunk_sources))


func _mesh_chunk_task(coords: Vector3i, revision: int, block_snapshot: PackedByteArray, light_snapshot: PackedByteArray, sky_snapshot: PackedByteArray, light_sources: Array) -> void:
	var mesh_data := Mesher.build(block_snapshot, light_snapshot, sky_snapshot, palette, air_id, fixture_ids, emissive_ids, light_sources)
	worker_mutex.lock()
	mesh_results[coords] = {"revision": revision, "mesh": mesh_data}
	worker_mutex.unlock()


func _process_mesh_pipeline() -> void:
	for slot in range(MAX_WORKERS):
		var task_id := mesh_task_ids[slot]
		if task_id == -1 or not WorkerThreadPool.is_task_completed(task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(task_id)
		mesh_task_ids[slot] = -1
		mesh_task_chunks[slot] = INVALID_CHUNK
	var commits := 0
	for entry_key in mesh_results.keys():
		if commits >= MAX_MESH_COMMITS_PER_FRAME:
			break
		var coords: Vector3i = entry_key
		var entry: Dictionary = mesh_results[coords]
		mesh_results.erase(coords)
		var record: Dictionary = chunk_records.get(coords, {})
		if record.is_empty():
			continue
		if int(record["revision"]) != int(entry["revision"]):
			_queue_mesh(coords)
			continue
		_apply_mesh_result(coords, entry["mesh"])
		commits += 1
	_fill_mesh_workers()


func _apply_mesh_result(coords: Vector3i, result: Dictionary) -> void:
	var record: Dictionary = chunk_records.get(coords, {})
	if record.is_empty():
		return
	var chunk = record["node"]
	var vertices: PackedVector3Array = result["vertices"]
	chunk.install_geometry(vertices, result["normals"], result["colors"], result["uv2"])
	if not bool(record["mesh_installed"]):
		record["mesh_installed"] = true
		meshed_chunk_count += 1
	_check_spawn_ready()


func _light_sources_for_chunk(coords: Vector3i) -> Array:
	var origin := coords * CHUNK_SIZE
	var reach := 12
	var low := origin - Vector3i(reach, reach, reach)
	var high := origin + Vector3i(CHUNK_SIZE + reach, CHUNK_SIZE + reach, CHUNK_SIZE + reach)
	var sources: Array = []
	for source in static_light_sources:
		var cell: Vector3i = source["cell"]
		if cell.x < low.x or cell.y < low.y or cell.z < low.z or cell.x > high.x or cell.y > high.y or cell.z > high.z:
			continue
		sources.append({"position": Vector3(cell - origin) + Vector3(0.5, 0.5, 0.5), "cool": bool(source.get("cool", false))})
	return sources


func _make_mesh_snapshot(coords: Vector3i) -> Dictionary:
	var origin := coords * CHUNK_SIZE
	var snap_origin := origin - Vector3i.ONE
	var limit := 18
	var block_snapshot := PackedByteArray()
	var light_snapshot := PackedByteArray()
	var sky_snapshot := PackedByteArray()
	block_snapshot.resize(limit * limit * limit)
	light_snapshot.resize(limit * limit * limit)
	sky_snapshot.resize(limit * limit * limit)
	block_snapshot.fill(int(block_ids[&"stone"]))
	light_snapshot.fill(0)
	sky_snapshot.fill(0)
	# Copy the 18^3 halo straight out of the neighbouring chunk rows instead of
	# looking up every cell individually. Unloaded space keeps the stone fill,
	# so the frontier never exposes the underside of the world.
	var chunk_low := _chunk_of(snap_origin)
	var chunk_high := _chunk_of(snap_origin + Vector3i(limit - 1, limit - 1, limit - 1))
	for chunk_z in range(chunk_low.z, chunk_high.z + 1):
		for chunk_y in range(chunk_low.y, chunk_high.y + 1):
			for chunk_x in range(chunk_low.x, chunk_high.x + 1):
				var neighbor := Vector3i(chunk_x, chunk_y, chunk_z)
				var record: Dictionary = chunk_records.get(neighbor, {})
				if record.is_empty():
					continue
				var neighbor_origin := neighbor * CHUNK_SIZE
				var x_start := maxi(snap_origin.x, neighbor_origin.x)
				var x_end := mini(snap_origin.x + limit, neighbor_origin.x + CHUNK_SIZE)
				var y_start := maxi(snap_origin.y, neighbor_origin.y)
				var y_end := mini(snap_origin.y + limit, neighbor_origin.y + CHUNK_SIZE)
				var z_start := maxi(snap_origin.z, neighbor_origin.z)
				var z_end := mini(snap_origin.z + limit, neighbor_origin.z + CHUNK_SIZE)
				if x_start >= x_end or y_start >= y_end or z_start >= z_end:
					continue
				var source_blocks: PackedByteArray = record["blocks"]
				var light_ready := bool(record["light_ready"])
				var source_light: PackedByteArray = record["light"]
				for world_z in range(z_start, z_end):
					for world_y in range(y_start, y_end):
						var source_start := (x_start - neighbor_origin.x) + (world_y - neighbor_origin.y) * CHUNK_SIZE + (world_z - neighbor_origin.z) * CHUNK_SIZE * CHUNK_SIZE
						var target_start := (x_start - snap_origin.x) + (world_y - snap_origin.y) * limit + (world_z - snap_origin.z) * limit * limit
						for offset_x in range(x_end - x_start):
							block_snapshot[target_start + offset_x] = source_blocks[source_start + offset_x]
							if light_ready:
								light_snapshot[target_start + offset_x] = source_light[source_start + offset_x]
	# Sky fill only depends on the column. Fill the vertical run above each
	# surface instead of testing every cell against the heightfield.
	for z in range(-1, CHUNK_SIZE + 1):
		for x in range(-1, CHUNK_SIZE + 1):
			var info := BiomeManager.column_info(origin.x + x, origin.z + z)
			var sky_value := info.y
			if sky_value <= 0:
				continue
			var first_y := maxi(-1, info.x - origin.y)
			for y in range(first_y, CHUNK_SIZE + 1):
				var world_y := origin.y + y
				if world_y < 0 or world_y >= WORLD_Y:
					continue
				var snapshot_index := (x + 1) + (y + 1) * 18 + (z + 1) * 18 * 18
				sky_snapshot[snapshot_index] = sky_value
	return {"blocks": block_snapshot, "light": light_snapshot, "sky": sky_snapshot}


func _local_index(cell: Vector3i, coords: Vector3i) -> int:
	return (cell.x - coords.x * CHUNK_SIZE) + (cell.y - coords.y * CHUNK_SIZE) * CHUNK_SIZE + (cell.z - coords.z * CHUNK_SIZE) * CHUNK_SIZE * CHUNK_SIZE


# --- Blocks -----------------------------------------------------------------

func get_block_id(cell: Vector3i) -> int:
	# Contract endpoint 6: X/Z are unbounded and negative-safe via floori chunk
	# mapping. Y is a fixed slab: [0, WORLD_Y). Outside the slab or inside an
	# unloaded chunk this reports air — use is_solid for physics decisions.
	if cell.y < 0 or cell.y >= WORLD_Y:
		return air_id
	var coords := _chunk_of(cell)
	var record: Dictionary = chunk_records.get(coords, {})
	if record.is_empty():
		return air_id
	return int(record["blocks"][_local_index(cell, coords)])


func is_solid(cell: Vector3i) -> bool:
	if cell.y < 0 or cell.y >= WORLD_Y:
		return true
	var coords := _chunk_of(cell)
	var record: Dictionary = chunk_records.get(coords, {})
	if record.is_empty():
		# Invisible wall at the frontier so nothing falls out of the world.
		return true
	return int(record["blocks"][_local_index(cell, coords)]) != air_id


func get_light_level(cell: Vector3i) -> int:
	if cell.y < 0 or cell.y >= WORLD_Y:
		return 0
	var coords := _chunk_of(cell)
	var record: Dictionary = chunk_records.get(coords, {})
	if record.is_empty() or not bool(record["light_ready"]):
		return 0
	return int(record["light"][_local_index(cell, coords)])


func set_block(cell: Vector3i, block_id: int) -> bool:
	if not is_generated or not _inside_world(cell) or block_id < 0 or block_id >= block_defs.size():
		return false
	var coords := _chunk_of(cell)
	var record: Dictionary = chunk_records.get(coords, {})
	if record.is_empty():
		return false
	var index := _local_index(cell, coords)
	var blocks: PackedByteArray = record["blocks"]
	var previous_id := int(blocks[index])
	if previous_id == block_id:
		return false
	var was_extinguished := extinguished_sources.has(cell)
	blocks[index] = block_id
	record["blocks"] = blocks
	modified_chunks[coords] = blocks.duplicate()
	if vegetation != null and block_id == air_id and previous_id != air_id:
		vegetation.hide_tree_at(cell)
	if extinguished_sources.has(cell):
		extinguished_sources.erase(cell)
	_mark_cell_and_border_chunks(cell)
	if attenuation[previous_id] != attenuation[block_id] or emitted_light[previous_id] != emitted_light[block_id]:
		if emitted_light[previous_id] != emitted_light[block_id] or was_extinguished:
			_update_static_light_source(cell, block_id)
		_queue_light_region(cell)
	block_edited.emit(cell, block_id)
	return true


func _mark_cell_and_border_chunks(cell: Vector3i) -> void:
	var chunk_cell := _chunk_of(cell)
	_mark_chunk(chunk_cell)
	if cell.x % CHUNK_SIZE == 0: _mark_chunk(chunk_cell + Vector3i(-1, 0, 0))
	if cell.x % CHUNK_SIZE == CHUNK_SIZE - 1: _mark_chunk(chunk_cell + Vector3i(1, 0, 0))
	if cell.y % CHUNK_SIZE == 0: _mark_chunk(chunk_cell + Vector3i(0, -1, 0))
	if cell.y % CHUNK_SIZE == CHUNK_SIZE - 1: _mark_chunk(chunk_cell + Vector3i(0, 1, 0))
	if cell.z % CHUNK_SIZE == 0: _mark_chunk(chunk_cell + Vector3i(0, 0, -1))
	if cell.z % CHUNK_SIZE == CHUNK_SIZE - 1: _mark_chunk(chunk_cell + Vector3i(0, 0, 1))


func _mark_chunk(coords: Vector3i) -> void:
	var record: Dictionary = chunk_records.get(coords, {})
	if record.is_empty():
		return
	record["revision"] = int(record["revision"]) + 1
	_queue_mesh(coords)


func _chunk_of(cell: Vector3i) -> Vector3i:
	return Vector3i(floori(float(cell.x) / CHUNK_SIZE), floori(float(cell.y) / CHUNK_SIZE), floori(float(cell.z) / CHUNK_SIZE))


func _inside_world(cell: Vector3i) -> bool:
	return cell.y >= 0 and cell.y < WORLD_Y


func is_chunk_loaded_at(cell: Vector3i) -> bool:
	return chunk_records.has(_chunk_of(cell))


# Contract endpoint 3: the honest "drivable" test for the buggy governor —
# takes a CHUNK coordinate and requires both the light bake and the mesh.
func is_chunk_ready(chunk_cell: Vector3i) -> bool:
	var record: Dictionary = chunk_records.get(chunk_cell, {})
	if record.is_empty():
		return false
	return bool(record["light_ready"]) and bool(record["mesh_installed"])


func get_surface_height(x: int, z: int) -> int:
	return BiomeManager.get_height(x, z)


# Contract endpoint 1: dominant biome of a world cell. Returns BiomeManager
# ids: 0 = Ashen Flats, 1 = Hushwoods, 2 = Frostfall, 3 = The Mire.
func get_biome_at(cell: Vector3i) -> int:
	return BiomeManager.dominant_biome(cell.x, cell.z)


func is_canyon_floor(x: int, z: int) -> bool:
	return BiomeManager.is_canyon_floor(x, z)


func loaded_block_count() -> int:
	return chunk_records.size() * CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE


# Contract endpoint 5: the one place the spawn column is published. Gameplay
# code should never hardcode WorldGenerator/Spawner coordinates again.
var spawn_origin: Vector3i:
	get:
		return Vector3i(BiomeManager.SPAWN_X, 0, BiomeManager.SPAWN_Z)


func spawn_height() -> int:
	return BiomeManager.get_height(BiomeManager.SPAWN_X, BiomeManager.SPAWN_Z)


# DEPRECATED for saving: prefer connecting to the block_edited signal and
# journaling sparse cells. This still stores a full 4 KB array per touched
# chunk, which defeats the purpose on an infinite map; it remains only as the
# generation-override layer consumed by _generate_chunk_task.
func get_modified_chunks() -> Dictionary:
	return modified_chunks


# --- Atmosphere and light ---------------------------------------------------

# Contract-adjacent: biome fog blending. Weighted by the continuous biome
# field so fog thickens across border bands; DayNightCycle multiplies its
# daylight fog by biome_fog_scale and tints with biome_fog_tint.
func _update_biome_atmosphere(delta: float) -> void:
	if not is_instance_valid(player_camera):
		return
	var position := player_camera.global_position
	var weights := BiomeManager.get_weights(floori(position.x), floori(position.z))
	var target_scale := 0.0
	var target_tint := Color(0.0, 0.0, 0.0)
	for index in range(BiomeManager.BIOME_COUNT):
		target_scale += weights[index] * float(BIOME_FOG_SCALE[index])
		var tint: Color = BIOME_FOG_TINT[index]
		target_tint.r += weights[index] * tint.r
		target_tint.g += weights[index] * tint.g
		target_tint.b += weights[index] * tint.b
	var blend := 1.0 - exp(-delta * 0.8)
	biome_fog_scale = lerpf(biome_fog_scale, target_scale, blend)
	biome_fog_tint = biome_fog_tint.lerp(target_tint, blend)

func set_sun(direction: Vector3, color: Color, strength: float) -> void:
	if world_material == null:
		return
	var sun_direction := direction.normalized()
	var sun_strength := clampf(strength, 0.0, 1.0)
	world_material.set_shader_parameter("sun_direction", sun_direction)
	world_material.set_shader_parameter("sun_color", Vector3(color.r, color.g, color.b))
	world_material.set_shader_parameter("sun_strength", sun_strength)
	if vegetation != null:
		vegetation.set_sun(sun_direction, color, sun_strength)
	if sun_light != null:
		sun_light.light_energy = sun_strength * 1.15
		sun_light.light_color = color
		var up := Vector3.UP if absf(sun_direction.y) < 0.98 else Vector3.FORWARD
		sun_light.global_transform = Transform3D(Basis.looking_at(-sun_direction, up), Vector3.ZERO)


func set_ambient_sky_level(level: float) -> void:
	ambient_sky_level = clampf(level, 0.0, 1.0)
	if world_material != null:
		world_material.set_shader_parameter("ambient_sky_level", ambient_sky_level)
	if vegetation != null:
		vegetation.set_ambient_level(ambient_sky_level)


func set_flashlight_enabled(enabled: bool) -> void:
	flashlight_enabled = enabled
	if world_material != null:
		world_material.set_shader_parameter("flashlight_enabled", enabled)


func get_flashlight_level_at(world_position: Vector3) -> float:
	if not flashlight_enabled or player_camera == null:
		return 0.0
	var from_source := world_position - player_camera.global_position
	var distance := from_source.length()
	if distance <= 0.001 or distance >= FLASHLIGHT_RANGE:
		return 0.0
	var alignment := from_source.normalized().dot((-player_camera.global_basis.z).normalized())
	var cone := smoothstep(FLASHLIGHT_OUTER_COS, FLASHLIGHT_INNER_COS, alignment)
	var falloff := 1.0 - distance / FLASHLIGHT_RANGE
	return clampf(FLASHLIGHT_INTENSITY * cone * falloff * falloff, 0.0, 1.0)


func get_gloom_level(cell: Vector3i) -> float:
	if gloom_manager == null:
		return 0.0
	return gloom_manager.get_level_for_cell(cell)


func _update_flashlight_uniforms() -> void:
	if player_camera == null or world_material == null:
		return
	world_material.set_shader_parameter("camera_position", player_camera.global_position)
	world_material.set_shader_parameter("camera_direction", (-player_camera.global_basis.z).normalized())


func emit_gloom_noise(world_position: Vector3, strength: float) -> void:
	if strength > 0.0:
		gloom_noise_emitted.emit(world_position, strength)


# --- Persistence ------------------------------------------------------------

func restore_save(save_data: Dictionary) -> bool:
	var metadata: Dictionary = save_data.get("metadata", {})
	if metadata.is_empty():
		return false
	world_seed = int(metadata.get("seed", world_seed))
	modified_chunks = save_data.get("edits", {}).duplicate()
	BiomeManager.configure(world_seed)
	for key in chunk_records.keys():
		var record: Dictionary = chunk_records[key]
		var node = record["node"]
		if is_instance_valid(node):
			node.queue_free()
	chunk_records.clear()
	generation_queue.clear()
	generation_set.clear()
	generation_results.clear()
	light_queue.clear()
	light_set.clear()
	mesh_queue.clear()
	mesh_set.clear()
	mesh_results.clear()
	static_light_sources.clear()
	has_active_light = false
	active_light_coords = INVALID_CHUNK
	active_light_state.clear()
	initialized_light_chunks = 0
	meshed_chunk_count = 0
	generated_chunk_count = 0
	light_completion_logged = false
	stream_center = Vector2i(1 << 30, 1 << 30)
	is_generated = false
	_update_streaming(true)
	return true


func _log_world_counts() -> void:
	print("WORLD streaming seed=%d stream_radius=%d loaded_chunks=%d modified_chunks=%d" % [world_seed, STREAM_RADIUS, chunk_records.size(), modified_chunks.size()])


func _check_slow_frame(delta: float) -> void:
	if delta > 0.020:
		slow_frame_streak += 1
		if slow_frame_streak == 10:
			var active_meshes := 0
			for key in chunk_records.keys():
				var record: Dictionary = chunk_records[key]
				var node = record["node"]
				if is_instance_valid(node) and node.mesh_instance.mesh != null:
					active_meshes += 1
			var phase := "generation" if not is_generated else ("light" if not light_queue.is_empty() else "meshing/render")
			push_warning("WORLD 10 consecutive >20ms frames; draw_calls=%d active_chunks=%d phase=%s" % [Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), active_meshes, phase])
	else:
		slow_frame_streak = 0
