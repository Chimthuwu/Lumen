extends Node3D
class_name VoxelWorld

const WORLD_X := 128
const WORLD_Y := 64
const WORLD_Z := 128
const CHUNK_SIZE := 16
const CHUNKS_X := 8
const CHUNKS_Y := 4
const CHUNKS_Z := 8
const CHUNK_COUNT := CHUNKS_X * CHUNKS_Y * CHUNKS_Z
const MAX_WORKERS := 4
const MAX_MESH_COMMITS_PER_FRAME := 2
const BLOCK_VOLUME := WORLD_X * WORLD_Y * WORLD_Z
const BLOCK_RESOURCE_PATHS := [
	"res://data/blocks/air.tres",
	"res://data/blocks/ashen_soil.tres",
	"res://data/blocks/dirt.tres",
	"res://data/blocks/stone.tres",
	"res://data/blocks/iron_ore.tres",
	"res://data/blocks/lumen_crystal.tres",
	"res://data/blocks/torch.tres",
	"res://data/blocks/mycelium.tres",
	"res://data/blocks/pale_bloom.tres"
]
const Generator = preload("res://scripts/world/world_generator.gd")
const ChunkScript = preload("res://scripts/world/chunk.gd")
const Mesher = preload("res://scripts/world/chunk_mesher.gd")
const LightPropagator = preload("res://scripts/light/light_propagator.gd")

@export var world_seed := 139732

var blocks := PackedByteArray()
var heights := PackedInt32Array()
var biome_map := PackedByteArray()
var block_defs: Array[BlockLightDef] = []
var block_ids: Dictionary = {}
var palette := PackedColorArray()
var air_id := 0
var attenuation := PackedByteArray()
var emitted_light := PackedByteArray()
var light_buffers: Array[PackedByteArray] = []
var light_initialized := PackedByteArray()
var static_light_sources: Array[Dictionary] = []
var light_dirty_queue: Array[int] = []
var light_dirty_head := 0
var light_dirty_set: Dictionary = {}
var initialized_light_chunks := 0
var light_updates_last_frame := 0
var light_update_times_usec: Array[int] = []
var max_light_chunks_per_frame := 1
var chunk_nodes: Array = []
var generation_results: Array = []
var generation_task_ids := PackedInt64Array([-1, -1, -1, -1])
var generation_task_chunks := PackedInt32Array([-1, -1, -1, -1])
var generated_chunk_count := 0
var is_generated := false
var mesh_results: Array = []
var mesh_task_ids := PackedInt64Array([-1, -1, -1, -1])
var mesh_task_chunks := PackedInt32Array([-1, -1, -1, -1])
var mesh_task_revisions := PackedInt32Array([-1, -1, -1, -1])
var mesh_task_revisions_for_result := PackedInt32Array()
var worker_mutex := Mutex.new()
var chunk_revisions := PackedInt32Array()
var mesh_installed := PackedByteArray()
var meshed_chunk_count := 0
var dirty_queue: Array[int] = []
var dirty_head := 0
var dirty_set: Dictionary = {}
var completed_meshes: Array[int] = []
var completed_head := 0
var world_material: ShaderMaterial
var player_camera: Camera3D
var slow_frame_streak := 0


func _exit_tree() -> void:
	for slot in range(MAX_WORKERS):
		if generation_task_ids[slot] != -1:
			WorkerThreadPool.wait_for_task_completion(generation_task_ids[slot])
			generation_task_ids[slot] = -1
		if mesh_task_ids[slot] != -1:
			WorkerThreadPool.wait_for_task_completion(mesh_task_ids[slot])
			mesh_task_ids[slot] = -1


func _ready() -> void:
	_load_block_palette()
	blocks.resize(BLOCK_VOLUME)
	blocks.fill(air_id)
	generation_results.resize(CHUNK_COUNT)
	mesh_results.resize(CHUNK_COUNT)
	mesh_task_revisions_for_result.resize(CHUNK_COUNT)
	chunk_revisions.resize(CHUNK_COUNT)
	chunk_revisions.fill(0)
	mesh_installed.resize(CHUNK_COUNT)
	mesh_installed.fill(0)
	light_buffers.resize(CHUNK_COUNT)
	light_initialized.resize(CHUNK_COUNT)
	light_initialized.fill(0)
	for chunk_index in range(CHUNK_COUNT):
		var chunk_light := PackedByteArray()
		chunk_light.resize(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE)
		chunk_light.fill(0)
		light_buffers[chunk_index] = chunk_light
	_create_chunk_nodes()
	player_camera = get_parent().get_node_or_null("Player/Camera3D") as Camera3D
	var maps: Dictionary = Generator.build_maps(world_seed)
	heights = maps["heights"]
	biome_map = maps["biome_map"]
	_fill_generation_workers()


func _process(delta: float) -> void:
	_check_slow_frame(delta)
	if not is_generated:
		_process_generation()
	else:
		_process_light_updates()
		_process_mesh_pipeline()
		_update_flashlight_uniforms()

func _load_block_palette() -> void:
	world_material = ShaderMaterial.new()
	world_material.shader = load("res://shaders/light_dither.gdshader") as Shader
	world_material.set_shader_parameter("dither_bands", 6.0)
	world_material.set_shader_parameter("flashlight_enabled", true)
	world_material.set_shader_parameter("flashlight_range", 12.0)
	world_material.set_shader_parameter("flashlight_inner_cos", 0.94)
	world_material.set_shader_parameter("flashlight_outer_cos", 0.82)
	world_material.set_shader_parameter("flashlight_intensity", 0.85)
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

func _create_chunk_nodes() -> void:
	chunk_nodes.resize(CHUNK_COUNT)
	for chunk_y in range(CHUNKS_Y):
		for chunk_z in range(CHUNKS_Z):
			for chunk_x in range(CHUNKS_X):
				var index := _chunk_index(Vector3i(chunk_x, chunk_y, chunk_z))
				var chunk = ChunkScript.new()
				chunk.name = "Chunk_%d_%d_%d" % [chunk_x, chunk_y, chunk_z]
				chunk.configure(Vector3i(chunk_x, chunk_y, chunk_z), Vector3(chunk_x, chunk_y, chunk_z) * CHUNK_SIZE, world_material)
				add_child(chunk)
				chunk_nodes[index] = chunk


func _fill_generation_workers() -> void:
	for slot in range(MAX_WORKERS):
		if generation_task_ids[slot] != -1 or generated_chunk_count + _active_generation_count() >= CHUNK_COUNT:
			continue
		var next_chunk := generated_chunk_count + _active_generation_count()
		if next_chunk >= CHUNK_COUNT:
			return
		generation_task_chunks[slot] = next_chunk
		generation_task_ids[slot] = WorkerThreadPool.add_task(Callable(self, "_generate_chunk_task").bind(next_chunk))


func _active_generation_count() -> int:
	var active := 0
	for slot in range(MAX_WORKERS):
		if generation_task_ids[slot] != -1:
			active += 1
	return active


func _generate_chunk_task(chunk_index: int) -> void:
	var generated := Generator.generate_chunk(chunk_index, world_seed, heights, block_ids)
	worker_mutex.lock()
	generation_results[chunk_index] = generated
	worker_mutex.unlock()


func _process_generation() -> void:
	for slot in range(MAX_WORKERS):
		var task_id := generation_task_ids[slot]
		if task_id == -1 or not WorkerThreadPool.is_task_completed(task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(task_id)
		var chunk_index := generation_task_chunks[slot]
		var chunk_data: PackedByteArray = generation_results[chunk_index]
		_copy_generated_chunk(chunk_index, chunk_data)
		generation_results[chunk_index] = null
		generation_task_ids[slot] = -1
		generation_task_chunks[slot] = -1
		generated_chunk_count += 1
	if generated_chunk_count == CHUNK_COUNT:
		is_generated = true
		_rebuild_static_light_sources()
		_log_world_counts()
		for chunk_index in range(CHUNK_COUNT):
			_enqueue_light_dirty(chunk_index)
	else:
		_fill_generation_workers()


func _copy_generated_chunk(chunk_index: int, chunk_data: PackedByteArray) -> void:
	var chunk_x := chunk_index % CHUNKS_X
	var chunk_z := int(chunk_index / CHUNKS_X) % CHUNKS_Z
	var chunk_y := int(chunk_index / (CHUNKS_X * CHUNKS_Z))
	for z in range(CHUNK_SIZE):
		for y in range(CHUNK_SIZE):
			var local_start := y * CHUNK_SIZE + z * CHUNK_SIZE * CHUNK_SIZE
			var world_start := chunk_x * CHUNK_SIZE + (chunk_z * CHUNK_SIZE + z) * WORLD_X + (chunk_y * CHUNK_SIZE + y) * WORLD_X * WORLD_Z
			for x in range(CHUNK_SIZE):
				blocks[world_start + x] = chunk_data[local_start + x]


func _process_mesh_pipeline() -> void:
	for slot in range(MAX_WORKERS):
		var task_id := mesh_task_ids[slot]
		if task_id == -1 or not WorkerThreadPool.is_task_completed(task_id):
			continue
		WorkerThreadPool.wait_for_task_completion(task_id)
		completed_meshes.append(mesh_task_chunks[slot])
		mesh_task_ids[slot] = -1
		mesh_task_chunks[slot] = -1
	var commits := 0
	while commits < MAX_MESH_COMMITS_PER_FRAME and completed_head < completed_meshes.size():
		var chunk_index := completed_meshes[completed_head]
		completed_head += 1
		var result: Dictionary = mesh_results[chunk_index]
		mesh_results[chunk_index] = null
		if chunk_revisions[chunk_index] != mesh_task_revisions_for_result[chunk_index]:
			_queue_dirty(chunk_index)
		else:
			_apply_mesh_result(chunk_index, result)
		commits += 1
	if completed_head >= completed_meshes.size():
		completed_meshes.clear()
		completed_head = 0
	_fill_mesh_workers()


func _fill_mesh_workers() -> void:
	var active := 0
	for slot in range(MAX_WORKERS):
		if mesh_task_ids[slot] != -1:
			active += 1
	active += completed_meshes.size() - completed_head
	for slot in range(MAX_WORKERS):
		if active >= MAX_WORKERS:
			return
		if mesh_task_ids[slot] != -1:
			continue
		var next_chunk := _pop_dirty()
		if next_chunk == -1:
			return
		var snapshot := _make_mesh_snapshot(next_chunk)
		var revision := chunk_revisions[next_chunk]
		mesh_task_chunks[slot] = next_chunk
		mesh_task_revisions[slot] = revision
		mesh_task_revisions_for_result[next_chunk] = revision
		mesh_task_ids[slot] = WorkerThreadPool.add_task(Callable(self, "_mesh_chunk_task").bind(next_chunk, snapshot["blocks"], snapshot["light"]))
		active += 1


func _mesh_chunk_task(chunk_index: int, block_snapshot: PackedByteArray, light_snapshot: PackedByteArray) -> void:
	var mesh_data := Mesher.build(block_snapshot, light_snapshot, palette, air_id)
	worker_mutex.lock()
	mesh_results[chunk_index] = mesh_data
	worker_mutex.unlock()

func _make_mesh_snapshot(chunk_index: int) -> Dictionary:
	var chunk_x := chunk_index % CHUNKS_X
	var chunk_z := int(chunk_index / CHUNKS_X) % CHUNKS_Z
	var chunk_y := int(chunk_index / (CHUNKS_X * CHUNKS_Z))
	var origin := Vector3i(chunk_x, chunk_y, chunk_z) * CHUNK_SIZE
	var block_snapshot := PackedByteArray()
	var light_snapshot := PackedByteArray()
	block_snapshot.resize(18 * 18 * 18)
	light_snapshot.resize(18 * 18 * 18)
	block_snapshot.fill(air_id)
	light_snapshot.fill(0)
	for z in range(-1, CHUNK_SIZE + 1):
		for y in range(-1, CHUNK_SIZE + 1):
			for x in range(-1, CHUNK_SIZE + 1):
				var cell := origin + Vector3i(x, y, z)
				if not _inside_world(cell):
					continue
				var snapshot_index := (x + 1) + (y + 1) * 18 + (z + 1) * 18 * 18
				block_snapshot[snapshot_index] = blocks[_block_index(cell)]
				light_snapshot[snapshot_index] = get_light_level(cell)
	return {"blocks": block_snapshot, "light": light_snapshot}

func _process_light_updates() -> void:
	light_updates_last_frame = 0
	while light_updates_last_frame < max_light_chunks_per_frame:
		var chunk_index := _pop_light_dirty()
		if chunk_index == -1:
			break
		var old_light: PackedByteArray = light_buffers[chunk_index]
		var coords := _chunk_coords(chunk_index)
		var light_start_usec := Time.get_ticks_usec()
		var new_light: PackedByteArray = LightPropagator.build_chunk(blocks, coords, static_light_sources, attenuation, block_ids[&"stone"] )
		light_update_times_usec.append(Time.get_ticks_usec() - light_start_usec)
		var was_initialized := light_initialized[chunk_index] != 0
		if not was_initialized or new_light != old_light:
			light_buffers[chunk_index] = new_light
			chunk_revisions[chunk_index] += 1
			_queue_dirty(chunk_index)
		if not was_initialized:
			light_initialized[chunk_index] = 1
			initialized_light_chunks += 1
			if initialized_light_chunks == CHUNK_COUNT:
				_log_light_timings()
		light_updates_last_frame += 1
	if light_dirty_head >= light_dirty_queue.size():
		light_dirty_queue.clear()
		light_dirty_head = 0


func _log_light_timings() -> void:
	var sorted_times := light_update_times_usec.duplicate()
	sorted_times.sort()
	print("M2 main world light timings us median=%d max=%d; two-chunk budget test uses per-frame cap %d" % [sorted_times[sorted_times.size() / 2], sorted_times[sorted_times.size() - 1], max_light_chunks_per_frame])

func _enqueue_light_dirty(chunk_index: int) -> void:
	if chunk_index < 0 or chunk_index >= CHUNK_COUNT or light_dirty_set.has(chunk_index):
		return
	light_dirty_set[chunk_index] = true
	light_dirty_queue.append(chunk_index)


func _pop_light_dirty() -> int:
	while light_dirty_head < light_dirty_queue.size():
		var chunk_index := light_dirty_queue[light_dirty_head]
		light_dirty_head += 1
		light_dirty_set.erase(chunk_index)
		return chunk_index
	return -1


func _rebuild_static_light_sources() -> void:
	static_light_sources.clear()
	for block_index in range(BLOCK_VOLUME):
		var block_id := int(blocks[block_index])
		var level := int(emitted_light[block_id])
		if level <= 0:
			continue
		var cell_y := int(block_index / (WORLD_X * WORLD_Z))
		var cell_z := int(block_index / WORLD_X) % WORLD_Z
		var cell_x := block_index % WORLD_X
		static_light_sources.append({"cell": Vector3i(cell_x, cell_y, cell_z), "level": level})


func _update_static_light_source(cell: Vector3i, new_block_id: int) -> void:
	for index in range(static_light_sources.size() - 1, -1, -1):
		if static_light_sources[index]["cell"] == cell:
			static_light_sources.remove_at(index)
	var level := int(emitted_light[new_block_id])
	if level > 0:
		static_light_sources.append({"cell": cell, "level": level})

func _queue_light_region(cell: Vector3i) -> void:
	var min_x := maxi(0, floori(float(cell.x - 15) / CHUNK_SIZE))
	var min_y := maxi(0, floori(float(cell.y - 15) / CHUNK_SIZE))
	var min_z := maxi(0, floori(float(cell.z - 15) / CHUNK_SIZE))
	var max_x := mini(CHUNKS_X - 1, floori(float(cell.x + 15) / CHUNK_SIZE))
	var max_y := mini(CHUNKS_Y - 1, floori(float(cell.y + 15) / CHUNK_SIZE))
	var max_z := mini(CHUNKS_Z - 1, floori(float(cell.z + 15) / CHUNK_SIZE))
	for chunk_y in range(min_y, max_y + 1):
		for chunk_z in range(min_z, max_z + 1):
			for chunk_x in range(min_x, max_x + 1):
				_enqueue_light_dirty(_chunk_index(Vector3i(chunk_x, chunk_y, chunk_z)))


func _chunk_coords(chunk_index: int) -> Vector3i:
	return Vector3i(chunk_index % CHUNKS_X, int(chunk_index / (CHUNKS_X * CHUNKS_X)), int(chunk_index / CHUNKS_X) % CHUNKS_Z)


func get_light_level(cell: Vector3i) -> int:
	if not _inside_world(cell):
		return 0
	var coords := Vector3i(int(cell.x / CHUNK_SIZE), int(cell.y / CHUNK_SIZE), int(cell.z / CHUNK_SIZE))
	var local_index := (cell.x % CHUNK_SIZE) + (cell.y % CHUNK_SIZE) * CHUNK_SIZE + (cell.z % CHUNK_SIZE) * CHUNK_SIZE * CHUNK_SIZE
	return light_buffers[_chunk_index(coords)][local_index]


func _update_flashlight_uniforms() -> void:
	if player_camera == null or world_material == null:
		return
	world_material.set_shader_parameter("flashlight_position", player_camera.global_position)
	world_material.set_shader_parameter("flashlight_direction", -player_camera.global_basis.z)

func _apply_mesh_result(chunk_index: int, result: Dictionary) -> void:
	var chunk = chunk_nodes[chunk_index]
	var vertices: PackedVector3Array = result["vertices"]
	chunk.install_geometry(vertices, result["normals"], result["colors"])
	if mesh_installed[chunk_index] == 0:
		mesh_installed[chunk_index] = 1
		meshed_chunk_count += 1


func _queue_dirty(chunk_index: int) -> void:
	if chunk_index < 0 or chunk_index >= CHUNK_COUNT or dirty_set.has(chunk_index):
		return
	dirty_set[chunk_index] = true
	dirty_queue.append(chunk_index)


func _pop_dirty() -> int:
	while dirty_head < dirty_queue.size():
		var chunk_index := dirty_queue[dirty_head]
		dirty_head += 1
		dirty_set.erase(chunk_index)
		return chunk_index
	if dirty_head > 0:
		dirty_queue.clear()
		dirty_head = 0
	return -1


func set_block(cell: Vector3i, block_id: int) -> bool:
	if not is_generated or not _inside_world(cell) or block_id < 0 or block_id >= block_defs.size():
		return false
	var index := _block_index(cell)
	var previous_id := int(blocks[index])
	if previous_id == block_id:
		return false
	blocks[index] = block_id
	_mark_cell_and_border_chunks(cell)
	if attenuation[previous_id] != attenuation[block_id] or emitted_light[previous_id] != emitted_light[block_id]:
		if emitted_light[previous_id] != emitted_light[block_id]:
			_update_static_light_source(cell, block_id)
		_queue_light_region(cell)
	return true

func _mark_cell_and_border_chunks(cell: Vector3i) -> void:
	var chunk_cell := Vector3i(int(cell.x / CHUNK_SIZE), int(cell.y / CHUNK_SIZE), int(cell.z / CHUNK_SIZE))
	_mark_chunk(chunk_cell)
	if cell.x % CHUNK_SIZE == 0: _mark_chunk(chunk_cell + Vector3i(-1, 0, 0))
	if cell.x % CHUNK_SIZE == CHUNK_SIZE - 1: _mark_chunk(chunk_cell + Vector3i(1, 0, 0))
	if cell.y % CHUNK_SIZE == 0: _mark_chunk(chunk_cell + Vector3i(0, -1, 0))
	if cell.y % CHUNK_SIZE == CHUNK_SIZE - 1: _mark_chunk(chunk_cell + Vector3i(0, 1, 0))
	if cell.z % CHUNK_SIZE == 0: _mark_chunk(chunk_cell + Vector3i(0, 0, -1))
	if cell.z % CHUNK_SIZE == CHUNK_SIZE - 1: _mark_chunk(chunk_cell + Vector3i(0, 0, 1))


func _mark_chunk(coords: Vector3i) -> void:
	if coords.x < 0 or coords.y < 0 or coords.z < 0 or coords.x >= CHUNKS_X or coords.y >= CHUNKS_Y or coords.z >= CHUNKS_Z:
		return
	var index := _chunk_index(coords)
	chunk_revisions[index] += 1
	_queue_dirty(index)


func get_block_id(cell: Vector3i) -> int:
	if not _inside_world(cell):
		return air_id
	return blocks[_block_index(cell)]


func is_solid(cell: Vector3i) -> bool:
	return not _inside_world(cell) or get_block_id(cell) != air_id


func _block_index(cell: Vector3i) -> int:
	return cell.x + cell.z * WORLD_X + cell.y * WORLD_X * WORLD_Z


func _chunk_index(coords: Vector3i) -> int:
	return coords.x + coords.z * CHUNKS_X + coords.y * CHUNKS_X * CHUNKS_Z


func _inside_world(cell: Vector3i) -> bool:
	return cell.x >= 0 and cell.y >= 0 and cell.z >= 0 and cell.x < WORLD_X and cell.y < WORLD_Y and cell.z < WORLD_Z


func get_surface_height(x: int, z: int) -> int:
	return heights[clampi(x, 0, WORLD_X - 1) + clampi(z, 0, WORLD_Z - 1) * WORLD_X]


func restore_save(save_data: Dictionary) -> bool:
	var loaded_blocks: PackedByteArray = save_data.get("blocks", PackedByteArray())
	var metadata: Dictionary = save_data.get("metadata", {})
	var dimensions: Array = metadata.get("dimensions", [])
	if loaded_blocks.size() != BLOCK_VOLUME or dimensions != [WORLD_X, WORLD_Y, WORLD_Z]:
		push_error("M1 restore: save dimensions or block volume do not match this world")
		return false
	blocks = loaded_blocks
	world_seed = int(metadata["seed"])
	var saved_biomes: Array = metadata.get("biome_map", [])
	if saved_biomes.size() != WORLD_X * WORLD_Z:
		push_error("M1 restore: biome map length mismatch")
		return false
	biome_map.resize(saved_biomes.size())
	for index in range(saved_biomes.size()):
		biome_map[index] = int(saved_biomes[index])
	_rebuild_static_light_sources()
	light_dirty_queue.clear()
	light_dirty_set.clear()
	light_dirty_head = 0
	initialized_light_chunks = 0
	for index in range(CHUNK_COUNT):
		light_buffers[index].fill(0)
		light_initialized[index] = 0
		chunk_revisions[index] += 1
		_queue_dirty(index)
		_enqueue_light_dirty(index)
	return true

func _log_world_counts() -> void:
	var counts := PackedInt64Array()
	counts.resize(block_defs.size())
	counts.fill(0)
	for block_id in blocks:
		counts[block_id] += 1
	print("M1 world generated seed=%d size=%dx%dx%d chunks=%d" % [world_seed, WORLD_X, WORLD_Y, WORLD_Z, CHUNK_COUNT])
	for block_index in range(block_defs.size()):
		print("M1 block count %s=%d" % [block_defs[block_index].block_id, counts[block_index]])
	var ashen_columns := 0
	for biome_id in biome_map:
		if biome_id == 0:
			ashen_columns += 1
	var cave_air := 0
	for y in range(12):
		for z in range(WORLD_Z):
			for x in range(WORLD_X):
				if get_block_id(Vector3i(x, y, z)) == air_id:
					cave_air += 1
	print("M1 biome count Ashen Flats columns=%d; underground cave air voxels=%d" % [ashen_columns, cave_air])


func _check_slow_frame(delta: float) -> void:
	if delta > 0.020:
		slow_frame_streak += 1
		if slow_frame_streak == 10:
			var active_meshes := 0
			for chunk in chunk_nodes:
				if chunk.mesh_instance.mesh != null:
					active_meshes += 1
			var phase := "generation" if not is_generated else ("light" if light_dirty_head < light_dirty_queue.size() else "meshing/render")
			push_warning("M1 10 consecutive >20ms frames; draw_calls=%d active_chunks=%d phase=%s" % [Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), active_meshes, phase])
	else:
		slow_frame_streak = 0



