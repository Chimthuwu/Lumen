extends RefCounted
class_name WorldGenerator

# Coordinate-based chunk generation for the streaming world. The generator no
# longer reads a global height map: every column asks BiomeManager, every feature
# is derived from a world-coordinate grid, and the output depends only on
# (world_seed, chunk origin). That is what allows chunks to be built in worker
# threads and regenerated identically after they have been unloaded.

const DEFAULT_SEED := 139732
const CHUNK_SIZE := 16
const WORLD_Y := 64
const CHUNKS_Y := 4

const SPAWN_X := 64
const SPAWN_Z := 64
const SPAWN_CLEAR_RADIUS := 4.0
const SPAWN_BLEND_RADIUS := 8.0

const TREE_CELL := 14
const TREE_CHANCE := 0.18
const CRYSTAL_CELL := 24
const CRYSTAL_CHANCE := 0.26
const HUSH_TREE_CELL := 4
const HUSH_TREE_CHANCE := 0.78
const HUSH_TREE_REACH := 6
const HUSH_TREE_MIN_HEIGHT := 12
const HUSH_TREE_MAX_HEIGHT := 20
const FROST_SPIRE_CELL := 11
const FROST_SPIRE_CHANCE := 0.42
const FROST_SPIRE_REACH := 5
const PROP_CELL := 11
const PROP_CHANCE := 0.16
const PROP_REACH := 8
const SCATTER_CELL := 5
const SCATTER_CHANCE := 0.012

const LANDMARK_TREES := [Vector2i(75, 60), Vector2i(54, 67), Vector2i(68, 72), Vector2i(61, 80)]
const LANDMARK_CRYSTALS := [Vector2i(80, 51), Vector2i(46, 77)]
const LANDMARK_SPIRES := [Vector2i(78, 110), Vector2i(44, 120), Vector2i(38, 58)]
const BRANCH_DIRECTIONS := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	Vector3i(1, 0, 1), Vector3i(1, 0, -1),
	Vector3i(-1, 0, 1), Vector3i(-1, 0, -1)
]


static func generate_chunk(chunk: Vector3i, world_seed: int, block_ids: Dictionary, modifications: PackedByteArray = PackedByteArray()) -> PackedByteArray:
	BiomeManager.configure(world_seed)
	var origin := chunk * CHUNK_SIZE
	var output := PackedByteArray()
	output.resize(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE)
	output.fill(int(block_ids[&"air"]))

	var air_id := int(block_ids[&"air"])
	var stone_id := int(block_ids[&"stone"])
	var ashen_soil_id := int(block_ids[&"ashen_soil"])
	var gravel_id := int(block_ids.get(&"canyon_gravel", ashen_soil_id))
	var mycelium_id := int(block_ids.get(&"mycelium", ashen_soil_id))
	var rotted_id := int(block_ids.get(&"rotted_ashen_soil", ashen_soil_id))
	var frost_snow_id := int(block_ids.get(&"frost_snow", ashen_soil_id))
	var frost_ice_id := int(block_ids.get(&"frost_ice", stone_id))
	var mire_mud_id := int(block_ids.get(&"mire_mud", ashen_soil_id))
	var toxic_silt_id := int(block_ids.get(&"toxic_silt", mire_mud_id))
	var crystal_id := int(block_ids[&"lumen_crystal"])
	var iron_id := int(block_ids[&"iron_ore"])
	var torch_id := int(block_ids.get(&"torch", -1))

	var heights := _height_cache(origin)
	var rng := RandomNumberGenerator.new()
	rng.seed = _chunk_seed(world_seed, origin)
	for z in range(CHUNK_SIZE):
		var world_z := origin.z + z
		for x in range(CHUNK_SIZE):
			var world_x := origin.x + x
			var surface_y := heights[_cache_index(x, z)]
			var biome := BiomeManager.surface_biome(world_x, world_z)
			var slope := _cache_slope(heights, x, z)
			var canyon_floor := BiomeManager.is_canyon_floor(world_x, world_z)
			var rocky := slope >= 2 or BiomeManager.rock_noise(world_x, world_z) > 0.62
			# Per-biome surface/subsurface recipe.
			var top_id := ashen_soil_id
			var sub_id := ashen_soil_id
			var sub_depth := 3
			match biome:
				BiomeManager.HUSH:
					# Hushwoods floor is dark mycelium over rotted soil, not the
					# Ashen ground it used to fall back to.
					top_id = mycelium_id
					sub_id = rotted_id
					sub_depth = 4
				BiomeManager.FROST:
					top_id = frost_snow_id
					sub_id = frost_ice_id
					sub_depth = 3
				BiomeManager.MIRE:
					top_id = mire_mud_id
					sub_id = mire_mud_id
					sub_depth = 4
				_:
					if canyon_floor:
						top_id = gravel_id
						sub_id = gravel_id
					elif rocky:
						top_id = stone_id
						sub_id = stone_id
			for y in range(CHUNK_SIZE):
				var world_y := origin.y + y
				if world_x == 64 and world_z == 58 and world_y == surface_y + 1 and torch_id >= 0:
					output[_local_index(x, y, z)] = torch_id
					continue
				if world_y > surface_y:
					continue
				var block_id: int
				if world_y == surface_y:
					block_id = top_id
				elif world_y >= surface_y - sub_depth:
					block_id = sub_id
					if biome == BiomeManager.MIRE and world_y <= BiomeManager.WATER_LEVEL + 2:
						block_id = toxic_silt_id if world_y < surface_y - 1 else mire_mud_id
				else:
					block_id = stone_id
					if world_y < 12 and BiomeManager.cave_noise(world_x, world_y, world_z) > 0.48:
						block_id = air_id
					elif rng.randf() < 0.0025:
						block_id = crystal_id if rng.randf() < 0.08 else iron_id
				output[_local_index(x, y, z)] = block_id

	_stamp_tree_stumps(output, origin, world_seed, block_ids)
	_stamp_crystal_clusters(output, origin, world_seed, crystal_id)
	_stamp_ashen_props(output, origin, world_seed, stone_id, air_id)
	_stamp_landmark_spires(output, origin, world_seed, stone_id, air_id)
	_stamp_hush_trees(output, origin, world_seed, block_ids)
	_stamp_frost_spires(output, origin, world_seed, frost_ice_id, stone_id)

	if modifications.size() == CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE:
		return modifications.duplicate()
	return output


static func is_canyon_floor(x: int, z: int) -> bool:
	return BiomeManager.is_canyon_floor(x, z)


static func _height_cache(origin: Vector3i) -> PackedInt32Array:
	var cache := PackedInt32Array()
	cache.resize(18 * 18)
	for z in range(-1, CHUNK_SIZE + 1):
		for x in range(-1, CHUNK_SIZE + 1):
			cache[(x + 1) + (z + 1) * 18] = BiomeManager.get_height(origin.x + x, origin.z + z)
	return cache


static func _cache_index(x: int, z: int) -> int:
	return (x + 1) + (z + 1) * 18


static func _cache_slope(heights: PackedInt32Array, x: int, z: int) -> int:
	var here := heights[_cache_index(x, z)]
	var slope := absi(here - heights[_cache_index(x - 1, z)])
	slope = maxi(slope, absi(here - heights[_cache_index(x + 1, z)]))
	slope = maxi(slope, absi(here - heights[_cache_index(x, z - 1)]))
	slope = maxi(slope, absi(here - heights[_cache_index(x, z + 1)]))
	return slope


static func _flat_at(x: int, z: int) -> bool:
	var here := BiomeManager.get_height(x, z)
	return absi(BiomeManager.get_height(x - 1, z) - here) <= 1 \
		and absi(BiomeManager.get_height(x + 1, z) - here) <= 1 \
		and absi(BiomeManager.get_height(x, z - 1) - here) <= 1 \
		and absi(BiomeManager.get_height(x, z + 1) - here) <= 1


static func _local_index(x: int, y: int, z: int) -> int:
	return x + y * CHUNK_SIZE + z * CHUNK_SIZE * CHUNK_SIZE


static func _get_cell(output: PackedByteArray, origin: Vector3i, cell: Vector3i) -> int:
	var local_x := cell.x - origin.x
	var local_y := cell.y - origin.y
	var local_z := cell.z - origin.z
	if local_x < 0 or local_x >= CHUNK_SIZE or local_y < 0 or local_y >= CHUNK_SIZE or local_z < 0 or local_z >= CHUNK_SIZE:
		return -1
	return output[_local_index(local_x, local_y, local_z)]


static func _set_cell(output: PackedByteArray, origin: Vector3i, cell: Vector3i, block_id: int) -> void:
	if block_id < 0:
		return
	var local_x := cell.x - origin.x
	var local_y := cell.y - origin.y
	var local_z := cell.z - origin.z
	if local_x < 0 or local_x >= CHUNK_SIZE or local_y < 0 or local_y >= CHUNK_SIZE or local_z < 0 or local_z >= CHUNK_SIZE:
		return
	output[_local_index(local_x, local_y, local_z)] = block_id


# --- Dead tree sites (Ashen Flats) -------------------------------------------

static func collect_tree_sites_region(world_seed: int, min_x: int, min_z: int, max_x: int, max_z: int) -> Array:
	BiomeManager.configure(world_seed)
	var sites: Array = []
	var min_gx := floori(float(min_x) / float(TREE_CELL)) - 1
	var max_gx := floori(float(max_x) / float(TREE_CELL)) + 1
	var min_gz := floori(float(min_z) / float(TREE_CELL)) - 1
	var max_gz := floori(float(max_z) / float(TREE_CELL)) + 1
	for grid_z in range(min_gz, max_gz + 1):
		for grid_x in range(min_gx, max_gx + 1):
			var site := _tree_site(world_seed, grid_x, grid_z)
			if site.is_empty():
				continue
			if int(site["x"]) < min_x or int(site["x"]) > max_x or int(site["z"]) < min_z or int(site["z"]) > max_z:
				continue
			sites.append(site)
	for landmark: Vector2i in LANDMARK_TREES:
		if landmark.x < min_x or landmark.x > max_x or landmark.y < min_z or landmark.y > max_z:
			continue
		var landmark_rng := RandomNumberGenerator.new()
		landmark_rng.seed = _column_seed(world_seed, landmark.x, landmark.y, 0x9E37)
		sites.append({
			"x": landmark.x,
			"z": landmark.y,
			"y": BiomeManager.get_height(landmark.x, landmark.y),
			"seed": landmark_rng.randi(),
			"landmark": true,
		})
	return sites


static func _tree_site(world_seed: int, grid_x: int, grid_z: int) -> Dictionary:
	var tree_rng := RandomNumberGenerator.new()
	tree_rng.seed = _column_seed(world_seed, grid_x, grid_z, 0x7A11)
	if tree_rng.randf() > TREE_CHANCE:
		return {}
	var base_x := grid_x * TREE_CELL + tree_rng.randi_range(3, TREE_CELL - 4)
	var base_z := grid_z * TREE_CELL + tree_rng.randi_range(3, TREE_CELL - 4)
	if absi(base_x - SPAWN_X) <= 7 and absi(base_z - SPAWN_Z) <= 7:
		return {}
	if BiomeManager.dominant_biome(base_x, base_z) != BiomeManager.ASHEN:
		return {}
	if BiomeManager.is_canyon_floor(base_x, base_z):
		return {}
	for landmark: Vector2i in LANDMARK_TREES:
		if absi(base_x - landmark.x) <= 4 and absi(base_z - landmark.y) <= 4:
			return {}
	for landmark: Vector2i in LANDMARK_CRYSTALS:
		if absi(base_x - landmark.x) <= 7 and absi(base_z - landmark.y) <= 7:
			return {}
	if not _flat_at(base_x, base_z):
		return {}
	return {
		"x": base_x,
		"z": base_z,
		"y": BiomeManager.get_height(base_x, base_z),
		"seed": tree_rng.randi(),
		"landmark": false,
	}


static func _stamp_tree_stumps(output: PackedByteArray, origin: Vector3i, world_seed: int, block_ids: Dictionary) -> void:
	var wood_id := int(block_ids.get(&"dead_wood", -1))
	if wood_id < 0:
		return
	var sites := collect_tree_sites_region(world_seed, origin.x, origin.z, origin.x + CHUNK_SIZE - 1, origin.z + CHUNK_SIZE - 1)
	for site in sites:
		_set_cell(output, origin, Vector3i(int(site["x"]), int(site["y"]), int(site["z"])), wood_id)


# --- Lumen crystal clusters --------------------------------------------------

static func _stamp_crystal_clusters(output: PackedByteArray, origin: Vector3i, world_seed: int, crystal_id: int) -> void:
	var min_gx := floori(float(origin.x - 10) / float(CRYSTAL_CELL))
	var max_gx := floori(float(origin.x + CHUNK_SIZE - 1 + 10) / float(CRYSTAL_CELL))
	var min_gz := floori(float(origin.z - 10) / float(CRYSTAL_CELL))
	var max_gz := floori(float(origin.z + CHUNK_SIZE - 1 + 10) / float(CRYSTAL_CELL))
	for grid_z in range(min_gz, max_gz + 1):
		for grid_x in range(min_gx, max_gx + 1):
			var cluster_rng := RandomNumberGenerator.new()
			cluster_rng.seed = _column_seed(world_seed, grid_x, grid_z, 0xC0DE)
			if cluster_rng.randf() > CRYSTAL_CHANCE:
				continue
			var base_x := grid_x * CRYSTAL_CELL + cluster_rng.randi_range(3, CRYSTAL_CELL - 4)
			var base_z := grid_z * CRYSTAL_CELL + cluster_rng.randi_range(3, CRYSTAL_CELL - 4)
			if BiomeManager.dominant_biome(base_x, base_z) != BiomeManager.ASHEN:
				continue
			if absi(base_x - SPAWN_X) <= 7 and absi(base_z - SPAWN_Z) <= 7:
				continue
			if not _flat_at(base_x, base_z):
				continue
			var base_y := BiomeManager.get_height(base_x, base_z)
			var center_height := cluster_rng.randi_range(6, 8)
			_stamp_shard(output, origin, crystal_id, base_x, base_z, base_y, center_height, 1)
			var shard_count := cluster_rng.randi_range(2, 3)
			for shard in range(shard_count):
				var angle := cluster_rng.randf_range(0.0, TAU)
				var radius := cluster_rng.randf_range(2.2, 3.8)
				var shard_x := base_x + roundi(cos(angle) * radius)
				var shard_z := base_z + roundi(sin(angle) * radius)
				var shard_y := BiomeManager.get_height(shard_x, shard_z)
				_stamp_shard(output, origin, crystal_id, shard_x, shard_z, shard_y, cluster_rng.randi_range(3, 5), 1)


static func _stamp_shard(output: PackedByteArray, origin: Vector3i, crystal_id: int, base_x: int, base_z: int, ground_y: int, shard_height: int, width: int) -> void:
	for step in range(shard_height):
		var step_width := width if step < shard_height - 3 else 1
		for wide_x in range(step_width):
			for wide_z in range(step_width):
				_set_cell(output, origin, Vector3i(base_x + wide_x, ground_y + step, base_z + wide_z), crystal_id)


# --- Ashen props -------------------------------------------------------------

static func _stamp_ashen_props(output: PackedByteArray, origin: Vector3i, world_seed: int, stone_id: int, air_id: int) -> void:
	var min_gx := floori(float(origin.x - PROP_REACH) / float(PROP_CELL))
	var max_gx := floori(float(origin.x + CHUNK_SIZE - 1 + PROP_REACH) / float(PROP_CELL))
	var min_gz := floori(float(origin.z - PROP_REACH) / float(PROP_CELL))
	var max_gz := floori(float(origin.z + CHUNK_SIZE - 1 + PROP_REACH) / float(PROP_CELL))
	for grid_z in range(min_gz, max_gz + 1):
		for grid_x in range(min_gx, max_gx + 1):
			var prop_rng := RandomNumberGenerator.new()
			prop_rng.seed = _column_seed(world_seed, grid_x, grid_z, 0x9A17)
			if prop_rng.randf() > PROP_CHANCE:
				continue
			var base_x := grid_x * PROP_CELL + prop_rng.randi_range(1, PROP_CELL - 2)
			var base_z := grid_z * PROP_CELL + prop_rng.randi_range(1, PROP_CELL - 2)
			if absi(base_x - SPAWN_X) <= 7 and absi(base_z - SPAWN_Z) <= 7:
				continue
			if BiomeManager.dominant_biome(base_x, base_z) != BiomeManager.ASHEN:
				continue
			if BiomeManager.is_canyon_floor(base_x, base_z) or not _flat_at(base_x, base_z):
				continue
			if prop_rng.randf() < 0.45:
				_stamp_pebbles(output, origin, prop_rng, base_x, base_z, stone_id, air_id)
			else:
				_stamp_boulder(output, origin, prop_rng, base_x, base_z, stone_id, air_id)


static func _stamp_pebbles(output: PackedByteArray, origin: Vector3i, rng: RandomNumberGenerator, base_x: int, base_z: int, stone_id: int, air_id: int) -> void:
	_place_prop_cell(output, origin, base_x, base_z, 1, stone_id, air_id)
	for pebble in range(rng.randi_range(1, 3)):
		_place_prop_cell(output, origin, base_x + rng.randi_range(-1, 1), base_z + rng.randi_range(-1, 1), 1, stone_id, air_id)


static func _stamp_boulder(output: PackedByteArray, origin: Vector3i, rng: RandomNumberGenerator, base_x: int, base_z: int, stone_id: int, air_id: int) -> void:
	var width := rng.randi_range(1, 2)
	var height := rng.randi_range(2, 4)
	for level in range(height):
		var radius := width if level == 0 else maxi(0, width - 1)
		for offset_z in range(-radius, radius + 1):
			for offset_x in range(-radius, radius + 1):
				if offset_x * offset_x + offset_z * offset_z > radius * radius + 1:
					continue
				if level > 0 and rng.randf() < 0.22:
					continue
				_place_prop_cell(output, origin, base_x + offset_x, base_z + offset_z, 1 + level, stone_id, air_id)


static func _place_prop_cell(output: PackedByteArray, origin: Vector3i, x: int, z: int, offset_y: int, block_id: int, air_id: int) -> void:
	var cell := Vector3i(x, BiomeManager.get_height(x, z) + offset_y, z)
	if cell.y < 1 or cell.y >= WORLD_Y - 1:
		return
	if _get_cell(output, origin, cell) != air_id:
		return
	_set_cell(output, origin, cell, block_id)


# --- Hushwoods pale trees ----------------------------------------------------

static func _stamp_hush_trees(output: PackedByteArray, origin: Vector3i, world_seed: int, block_ids: Dictionary) -> void:
	var wood_id := int(block_ids.get(&"pale_wood", block_ids.get(&"dead_wood", -1)))
	if wood_id < 0:
		return
	var min_gx := floori(float(origin.x - HUSH_TREE_REACH) / float(HUSH_TREE_CELL))
	var max_gx := floori(float(origin.x + CHUNK_SIZE - 1 + HUSH_TREE_REACH) / float(HUSH_TREE_CELL))
	var min_gz := floori(float(origin.z - HUSH_TREE_REACH) / float(HUSH_TREE_CELL))
	var max_gz := floori(float(origin.z + CHUNK_SIZE - 1 + HUSH_TREE_REACH) / float(HUSH_TREE_CELL))
	for grid_z in range(min_gz, max_gz + 1):
		for grid_x in range(min_gx, max_gx + 1):
			var tree_rng := RandomNumberGenerator.new()
			tree_rng.seed = _column_seed(world_seed, grid_x, grid_z, 0x6E55)
			if tree_rng.randf() > HUSH_TREE_CHANCE:
				continue
			var base_x := grid_x * HUSH_TREE_CELL + tree_rng.randi_range(1, HUSH_TREE_CELL - 2)
			var base_z := grid_z * HUSH_TREE_CELL + tree_rng.randi_range(1, HUSH_TREE_CELL - 2)
			if BiomeManager.get_weights(base_x, base_z)[BiomeManager.HUSH] <= 0.5:
				continue
			if not _flat_at(base_x, base_z):
				continue
			var base_y := BiomeManager.get_height(base_x, base_z)
			if base_y < 15:
				continue
			var height := tree_rng.randi_range(HUSH_TREE_MIN_HEIGHT, HUSH_TREE_MAX_HEIGHT)
			_stamp_hush_tree(output, origin, tree_rng, base_x, base_y, base_z, height, wood_id)


static func _stamp_hush_tree(output: PackedByteArray, origin: Vector3i, rng: RandomNumberGenerator, base_x: int, base_y: int, base_z: int, height: int, wood_id: int) -> void:
	var lean := Vector2i.ZERO
	if rng.randf() < 0.7:
		lean = Vector2i(rng.randi_range(-1, 1), rng.randi_range(-1, 1))
		if lean == Vector2i.ZERO:
			lean = Vector2i(1, 0)
	var x := base_x
	var z := base_z
	for step in range(height):
		var y := base_y + 1 + step
		_set_cell(output, origin, Vector3i(x, y, z), wood_id)
		if step == 0:
			_set_cell(output, origin, Vector3i(x + lean.x, y, z), wood_id)
			_set_cell(output, origin, Vector3i(x, y, z + lean.y), wood_id)
		if step >= 4 and step <= height - 3 and step % 3 == 2 and rng.randf() < 0.6:
			x += lean.x
			z += lean.y
		if step >= 4 and step % 3 == 0 and rng.randf() < 0.7:
			_stamp_hush_branch(output, origin, rng, Vector3i(x, y, z), wood_id)
	_stamp_hush_branch(output, origin, rng, Vector3i(x, base_y + height, z), wood_id)


static func _stamp_hush_branch(output: PackedByteArray, origin: Vector3i, rng: RandomNumberGenerator, start: Vector3i, wood_id: int) -> void:
	var direction: Vector3i = BRANCH_DIRECTIONS[rng.randi_range(0, BRANCH_DIRECTIONS.size() - 1)]
	var length := rng.randi_range(2, 4)
	var x := start.x
	var y := start.y
	var z := start.z
	for step in range(length):
		x += direction.x
		z += direction.z
		if step % 2 == 1:
			y += 1
		_set_cell(output, origin, Vector3i(x, y, z), wood_id)
		if rng.randf() < 0.3:
			_set_cell(output, origin, Vector3i(x, y + 1, z), wood_id)
	_set_cell(output, origin, Vector3i(x, y + 1, z), wood_id)
	_set_cell(output, origin, Vector3i(x, y + 2, z), wood_id)


# --- Ashen landmark spires ---------------------------------------------------

# Three deliberate stone buttes break the horizon. Each is stamped from its
# fixed root, so neighbouring chunks reproduce the same blocks without seams.
static func _stamp_landmark_spires(output: PackedByteArray, origin: Vector3i, world_seed: int, stone_id: int, air_id: int) -> void:
	var chunk_max_x := origin.x + CHUNK_SIZE - 1
	var chunk_max_z := origin.z + CHUNK_SIZE - 1
	for spire: Vector2i in LANDMARK_SPIRES:
		if spire.x + 12 < origin.x or spire.x - 12 > chunk_max_x or spire.y + 12 < origin.z or spire.y - 12 > chunk_max_z:
			continue
		var rng := RandomNumberGenerator.new()
		rng.seed = _column_seed(world_seed, spire.x, spire.y, 0x5A17)
		var base_y := BiomeManager.get_height(spire.x, spire.y)
		var height := rng.randi_range(6, 9)
		var lean := Vector2i(rng.randi_range(-1, 1), rng.randi_range(-1, 1))
		if lean == Vector2i.ZERO:
			lean = Vector2i(1, 0)
		var x := spire.x
		var z := spire.y
		for step in range(height):
			var y := base_y + 1 + step
			var radius := 2 if step < height - 3 else 1
			if step == 0:
				radius = 3
			for offset_z in range(-radius, radius + 1):
				for offset_x in range(-radius, radius + 1):
					if offset_x * offset_x + offset_z * offset_z > radius * radius + 1:
						continue
					if step > 0 and rng.randf() < 0.16:
						continue
					var cell_x := x + offset_x
					var cell_z := z + offset_z
					var column_ground := BiomeManager.get_height(cell_x, cell_z)
					for fill_y in range(maxi(column_ground, y - 5), y):
						_set_cell(output, origin, Vector3i(cell_x, fill_y, cell_z), stone_id)
					_set_cell(output, origin, Vector3i(cell_x, y, cell_z), stone_id)
			if step > 2 and step % 4 == 0:
				x += lean.x
				z += lean.y
		_set_cell(output, origin, Vector3i(x, base_y + height + 1, z), stone_id)
		for piece in range(7):
			var angle := rng.randf_range(0.0, TAU)
			var radius := rng.randf_range(3.0, 6.5)
			var rubble_x := spire.x + roundi(cos(angle) * radius)
			var rubble_z := spire.y + roundi(sin(angle) * radius)
			_place_prop_cell(output, origin, rubble_x, rubble_z, 1, stone_id, air_id)


# --- Frostfall ice spires ----------------------------------------------------

static func _stamp_frost_spires(output: PackedByteArray, origin: Vector3i, world_seed: int, ice_id: int, stone_id: int) -> void:
	var min_gx := floori(float(origin.x - FROST_SPIRE_REACH) / float(FROST_SPIRE_CELL))
	var max_gx := floori(float(origin.x + CHUNK_SIZE - 1 + FROST_SPIRE_REACH) / float(FROST_SPIRE_CELL))
	var min_gz := floori(float(origin.z - FROST_SPIRE_REACH) / float(FROST_SPIRE_CELL))
	var max_gz := floori(float(origin.z + CHUNK_SIZE - 1 + FROST_SPIRE_REACH) / float(FROST_SPIRE_CELL))
	for grid_z in range(min_gz, max_gz + 1):
		for grid_x in range(min_gx, max_gx + 1):
			var spire_rng := RandomNumberGenerator.new()
			spire_rng.seed = _column_seed(world_seed, grid_x, grid_z, 0x1CE5)
			if spire_rng.randf() > FROST_SPIRE_CHANCE:
				continue
			var base_x := grid_x * FROST_SPIRE_CELL + spire_rng.randi_range(2, FROST_SPIRE_CELL - 2)
			var base_z := grid_z * FROST_SPIRE_CELL + spire_rng.randi_range(2, FROST_SPIRE_CELL - 2)
			if BiomeManager.dominant_biome(base_x, base_z) != BiomeManager.FROST:
				continue
			if not _flat_at(base_x, base_z):
				continue
			var base_y := BiomeManager.get_height(base_x, base_z)
			# Broad height/lean variance so frost columns read as a jagged,
			# wind-thrown field rather than evenly turned posts.
			var height := spire_rng.randi_range(4, 17)
			var lean := Vector2i.ZERO
			if spire_rng.randf() < 0.6:
				lean = Vector2i(spire_rng.randi_range(-1, 1), spire_rng.randi_range(-1, 1))
			var x := base_x
			var z := base_z
			for step in range(height):
				var y := base_y + 1 + step
				var radius := 1 if step < height - 4 else 0
				for offset_z in range(-radius, radius + 1):
					for offset_x in range(-radius, radius + 1):
						if offset_x * offset_x + offset_z * offset_z > radius * radius + 1:
							continue
						var cell := Vector3i(x + offset_x, y, z + offset_z)
						if _get_cell(output, origin, cell) != -1:
							_set_cell(output, origin, cell, ice_id)
				if step == 0:
					var foot := Vector3i(x, base_y, z)
					_set_cell(output, origin, foot, ice_id)
				if step > 1 and step % (3 if height > 10 else 4) == 0 and lean != Vector2i.ZERO:
					x += lean.x
					z += lean.y
			if height > 10 and spire_rng.randf() < 0.4:
				var companion_x := base_x + spire_rng.randi_range(-3, 3)
				var companion_z := base_z + spire_rng.randi_range(-3, 3)
				if _flat_at(companion_x, companion_z):
					var companion_y := BiomeManager.get_height(companion_x, companion_z)
					_stamp_shard(output, origin, ice_id, companion_x, companion_z, companion_y + 1, spire_rng.randi_range(3, 7), 1)
			# Splinters around the base catch the low sun.
			for splinter in range(3):
				var angle := spire_rng.randf_range(0.0, TAU)
				var side_x := base_x + roundi(cos(angle) * 2.0)
				var side_z := base_z + roundi(sin(angle) * 2.0)
				var side_y := BiomeManager.get_height(side_x, side_z)
				_stamp_shard(output, origin, ice_id, side_x, side_z, side_y + 1, spire_rng.randi_range(1, 3), 1)


static func _chunk_seed(world_seed: int, origin: Vector3i) -> int:
	var value := world_seed * 1103515245 + origin.x * 73856093 + origin.y * 19349663 + origin.z * 83492791
	value = (value ^ (value >> 13)) * 1274126177
	return value & 0x7fffffff


static func _column_seed(world_seed: int, x: int, z: int, salt: int) -> int:
	var value := world_seed * 1103515245 + x * 73856093 + z * 19349663 + salt
	value = (value ^ (value >> 13)) * 1274126177
	return value & 0x7fffffff
