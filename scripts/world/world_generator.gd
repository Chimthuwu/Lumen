extends RefCounted
class_name WorldGenerator

const WORLD_X := 128
const WORLD_Y := 64
const WORLD_Z := 128
const CHUNK_SIZE := 16
const CHUNKS_X := 8
const CHUNKS_Y := 4
const CHUNKS_Z := 8

const SPAWN_X := 64
const SPAWN_Z := 64
const SPAWN_CLEAR_RADIUS := 4.0
const SPAWN_BLEND_RADIUS := 8.0
const SURFACE_BASE_HEIGHT := 23.0

const TREE_CELL := 9
const TREE_CHANCE := 0.5
const TREE_REACH := 8
const TREE_MIN_HEIGHT := 7
const TREE_MAX_HEIGHT := 12
const RIVER_CENTER_X := 94.0
const RIVER_WIDTH := 8.0
const RIVER_BED_HEIGHT := 17.0
const CRYSTAL_CELL := 24
const CRYSTAL_CHANCE := 0.42
const CRYSTAL_REACH := 10
const ASH_BLOOM_CHANCE := 0.32
const SCATTER_CELL := 5
const SCATTER_CHANCE := 0.05
const PROP_CELL := 7
const PROP_CHANCE := 0.62
const PROP_REACH := 7

const LANDMARK_TREES := [
	Vector2i(75, 60), Vector2i(54, 67), Vector2i(70, 76), Vector2i(57, 53),
	Vector2i(79, 72), Vector2i(50, 58), Vector2i(66, 49), Vector2i(61, 80)
]
const LANDMARK_CRYSTALS := [Vector2i(80, 51), Vector2i(46, 77)]
const BRANCH_DIRECTIONS := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1),
	Vector3i(1, 0, 1), Vector3i(1, 0, -1),
	Vector3i(-1, 0, 1), Vector3i(-1, 0, -1)
]


static func build_maps(world_seed: int) -> Dictionary:
	var broad_noise := _make_noise(world_seed ^ 0x1A2B3C, 3, 0.0045)
	var hill_noise := _make_noise(world_seed ^ 0x51A7, 3, 0.012)
	var detail_noise := _make_noise(world_seed ^ 0x7C31, 2, 0.045)
	var ridge_noise := _make_noise(world_seed ^ 0x6D2B, 4, 0.013)
	ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	var mesa_noise := _make_noise(world_seed ^ 0x39AF, 2, 0.017)
	var river_noise := _make_noise(world_seed ^ 0x2E77, 2, 0.06)
	var heights := PackedInt32Array()
	heights.resize(WORLD_X * WORLD_Z)
	var biome_map := PackedByteArray()
	biome_map.resize(WORLD_X * WORLD_Z)
	biome_map.fill(0)
	for z in range(WORLD_Z):
		for x in range(WORLD_X):
			var height_value := SURFACE_BASE_HEIGHT
			height_value += broad_noise.get_noise_2d(float(x), float(z)) * 6.8
			height_value += hill_noise.get_noise_2d(float(x), float(z)) * 3.2
			height_value += detail_noise.get_noise_2d(float(x), float(z)) * 0.35

			# Ridges: sharp ridged noise lifted into long spines that break the
			# dune horizon without touching the spawn basin.
			var ridge := clampf(ridge_noise.get_noise_2d(float(x), float(z)) * 0.5 + 0.5, 0.0, 1.0)
			var ridge_mask := smoothstep(0.58, 0.92, ridge)
			height_value += ridge_mask * ridge_mask * 12.0

			# Mesas: low-frequency plateaus with short cliff walls. Only raises
			# ground so the plains and river keep their shape.
			var mesa := mesa_noise.get_noise_2d(float(x) * 0.62, float(z) * 0.62)
			var mesa_mask := smoothstep(0.16, 0.30, mesa)
			var plateau := 33.0 + detail_noise.get_noise_2d(float(x), float(z)) * 1.8
			height_value = lerpf(height_value, maxf(height_value, plateau), mesa_mask)

			# Dry riverbed: a winding channel east of spawn, carved to a flat bed.
			var river_center := RIVER_CENTER_X + sin(float(z) * 0.07) * 13.0 + sin(float(z) * 0.023 + 2.1) * 6.0
			var river_distance := absf(float(x) - river_center)
			var bank := smoothstep(RIVER_WIDTH, 1.5, river_distance)
			var bed := smoothstep(3.5, 1.0, river_distance)
			height_value -= bank * 4.2
			height_value += river_noise.get_noise_2d(float(x), float(z)) * bank * 0.6
			height_value = lerpf(height_value, RIVER_BED_HEIGHT, bed * 0.72)

			heights[x + z * WORLD_X] = clampi(roundi(height_value), 12, 46)
	_flatten_spawn(heights)
	return {"heights": heights, "biome_map": biome_map}


static func _make_noise(noise_seed: int, octaves: int, frequency: float) -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = noise_seed
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = octaves
	noise.frequency = frequency
	return noise


static func _flatten_spawn(heights: PackedInt32Array) -> void:
	var spawn_height := heights[SPAWN_X + SPAWN_Z * WORLD_X]
	for z in range(SPAWN_Z - 9, SPAWN_Z + 10):
		for x in range(SPAWN_X - 9, SPAWN_X + 10):
			var distance := Vector2(float(x - SPAWN_X), float(z - SPAWN_Z)).length()
			if distance <= SPAWN_CLEAR_RADIUS:
				heights[x + z * WORLD_X] = spawn_height
			elif distance < SPAWN_BLEND_RADIUS:
				var blend := (distance - SPAWN_CLEAR_RADIUS) / (SPAWN_BLEND_RADIUS - SPAWN_CLEAR_RADIUS)
				heights[x + z * WORLD_X] = roundi(lerpf(float(spawn_height), float(heights[x + z * WORLD_X]), blend))


static func generate_chunk(chunk_index: int, world_seed: int, heights: PackedInt32Array, block_ids: Dictionary, tree_sites: Array = []) -> PackedByteArray:
	var chunk_x := chunk_index % CHUNKS_X
	var chunk_z := int(chunk_index / CHUNKS_X) % CHUNKS_Z
	var chunk_y := int(chunk_index / (CHUNKS_X * CHUNKS_Z))
	var origin_x := chunk_x * CHUNK_SIZE
	var origin_y := chunk_y * CHUNK_SIZE
	var origin_z := chunk_z * CHUNK_SIZE
	var chunk_seed := int((world_seed * 1103515245 + chunk_x * 73856093 + chunk_y * 19349663 + chunk_z * 83492791) & 0x7fffffff)
	var rng := RandomNumberGenerator.new()
	rng.seed = chunk_seed
	var cave_noise := _make_noise(world_seed ^ 0x2C79, 2, 0.075)
	var rock_noise := _make_noise(world_seed ^ 0x33E1, 3, 0.021)
	var output := PackedByteArray()
	output.resize(CHUNK_SIZE * CHUNK_SIZE * CHUNK_SIZE)
	output.fill(block_ids[&"air"])
	for z in range(CHUNK_SIZE):
		var world_z := origin_z + z
		for y in range(CHUNK_SIZE):
			var world_y := origin_y + y
			for x in range(CHUNK_SIZE):
				var world_x := origin_x + x
				var surface_y := heights[world_x + world_z * WORLD_X]
				var block_id: int
				if world_x == 64 and world_z == 58 and world_y == surface_y + 1:
					block_id = block_ids[&"torch"]
				elif world_y > surface_y:
					continue
				else:
					var rock := rock_noise.get_noise_2d(float(world_x), float(world_z))
					var on_cliff := _surface_slope(heights, world_x, world_z) >= 2 and rock > 0.2
					if world_y == surface_y:
						if on_cliff or rock > 0.7:
							block_id = block_ids[&"stone"]
						else:
							block_id = block_ids[&"ashen_soil"]
					elif world_y >= surface_y - 3:
						if on_cliff:
							block_id = block_ids[&"stone"]
						else:
							block_id = block_ids[&"ashen_soil"]
					else:
						block_id = block_ids[&"stone"]
						if world_y < 12 and cave_noise.get_noise_3d(float(world_x), float(world_y), float(world_z)) > 0.48:
							block_id = block_ids[&"air"]
						elif rng.randf() < 0.0025:
							block_id = block_ids[&"lumen_crystal"] if rng.randf() < 0.08 else block_ids[&"iron_ore"]
				var local_index := x + y * CHUNK_SIZE + z * CHUNK_SIZE * CHUNK_SIZE
				output[local_index] = block_id
	var origin := Vector3i(origin_x, origin_y, origin_z)
	var wood_id := int(block_ids.get(&"dead_wood", -1))
	if wood_id >= 0:
		_stamp_tree_stumps(output, origin, tree_sites, wood_id)
	_stamp_crystal_clusters(output, origin, world_seed, heights, int(block_ids[&"lumen_crystal"]))
	_stamp_ground_scatter(output, origin, world_seed, heights, int(block_ids[&"ashen_soil"]), int(block_ids[&"pale_bloom"]), int(block_ids[&"mycelium"]))
	_stamp_world_props(output, origin, world_seed, heights, block_ids)
	return output


static func _surface_slope(heights: PackedInt32Array, x: int, z: int) -> int:
	var here := heights[x + z * WORLD_X]
	var slope := 0
	if x > 0:
		slope = maxi(slope, absi(here - heights[x - 1 + z * WORLD_X]))
	if x < WORLD_X - 1:
		slope = maxi(slope, absi(here - heights[x + 1 + z * WORLD_X]))
	if z > 0:
		slope = maxi(slope, absi(here - heights[x + (z - 1) * WORLD_X]))
	if z < WORLD_Z - 1:
		slope = maxi(slope, absi(here - heights[x + (z + 1) * WORLD_X]))
	return slope


static func _flat_enough(heights: PackedInt32Array, x: int, z: int) -> bool:
	var here := heights[x + z * WORLD_X]
	for offset_z in range(-1, 2):
		for offset_x in range(-1, 2):
			var cell_x := x + offset_x
			var cell_z := z + offset_z
			if cell_x < 0 or cell_x >= WORLD_X or cell_z < 0 or cell_z >= WORLD_Z:
				continue
			if absi(heights[cell_x + cell_z * WORLD_X] - here) > 1:
				return false
	return true


# --- Dead trees -------------------------------------------------------------

# Tree shapes are no longer voxel cells: every tree is a deterministic site that
# WorldVegetation renders as a low-poly MultiMesh. The generator keeps one wood
# stump block per site so the trunk stays harvestable and visibly rooted.
static func collect_tree_sites(world_seed: int, heights: PackedInt32Array) -> Array:
	var sites: Array = []
	var grids_x := ceili(float(WORLD_X) / TREE_CELL)
	var grids_z := ceili(float(WORLD_Z) / TREE_CELL)
	for grid_z in range(grids_z):
		for grid_x in range(grids_x):
			var tree_rng := RandomNumberGenerator.new()
			tree_rng.seed = _column_seed(world_seed, grid_x, grid_z, 0x7A11)
			if tree_rng.randf() > TREE_CHANCE:
				continue
			var base_x := grid_x * TREE_CELL + tree_rng.randi_range(3, TREE_CELL - 4)
			var base_z := grid_z * TREE_CELL + tree_rng.randi_range(3, TREE_CELL - 4)
			if base_x < 1 or base_x >= WORLD_X - 1 or base_z < 1 or base_z >= WORLD_Z - 1:
				continue
			if _near_spawn(base_x, base_z):
				continue
			var landmark_overlap := false
			for landmark in LANDMARK_TREES:
				if absi(base_x - landmark.x) <= 4 and absi(base_z - landmark.y) <= 4:
					landmark_overlap = true
					break
			if landmark_overlap:
				continue
			for landmark in LANDMARK_CRYSTALS:
				if absi(base_x - landmark.x) <= 7 and absi(base_z - landmark.y) <= 7:
					landmark_overlap = true
					break
			if landmark_overlap:
				continue
			if not _flat_enough(heights, base_x, base_z):
				continue
			sites.append(_make_site(heights, base_x, base_z, tree_rng.randi(), false))
	for landmark in LANDMARK_TREES:
		var landmark_rng := RandomNumberGenerator.new()
		landmark_rng.seed = _column_seed(world_seed, landmark.x, landmark.y, 0x9E37)
		sites.append(_make_site(heights, landmark.x, landmark.y, landmark_rng.randi(), true))
	return sites


static func _make_site(heights: PackedInt32Array, x: int, z: int, shape_seed: int, landmark: bool) -> Dictionary:
	return {
		"x": x,
		"z": z,
		"y": heights[x + z * WORLD_X],
		"seed": shape_seed,
		"landmark": landmark
	}


static func _stamp_tree_stumps(output: PackedByteArray, origin: Vector3i, tree_sites: Array, wood_id: int) -> void:
	for site in tree_sites:
		_set_cell(output, origin, Vector3i(int(site["x"]), int(site["y"]), int(site["z"])), wood_id)


# --- Lumen crystal clusters -------------------------------------------------

static func _stamp_crystal_clusters(output: PackedByteArray, origin: Vector3i, world_seed: int, heights: PackedInt32Array, crystal_id: int) -> void:
	var min_gx := floori(float(origin.x - CRYSTAL_REACH) / CRYSTAL_CELL)
	var max_gx := floori(float(origin.x + CHUNK_SIZE - 1 + CRYSTAL_REACH) / CRYSTAL_CELL)
	var min_gz := floori(float(origin.z - CRYSTAL_REACH) / CRYSTAL_CELL)
	var max_gz := floori(float(origin.z + CHUNK_SIZE - 1 + CRYSTAL_REACH) / CRYSTAL_CELL)
	for grid_z in range(min_gz, max_gz + 1):
		for grid_x in range(min_gx, max_gx + 1):
			var cluster_rng := RandomNumberGenerator.new()
			cluster_rng.seed = _column_seed(world_seed, grid_x, grid_z, 0xC0DE)
			if cluster_rng.randf() > CRYSTAL_CHANCE:
				continue
			var base_x := grid_x * CRYSTAL_CELL + cluster_rng.randi_range(3, CRYSTAL_CELL - 4)
			var base_z := grid_z * CRYSTAL_CELL + cluster_rng.randi_range(3, CRYSTAL_CELL - 4)
			if base_x < 2 or base_x >= WORLD_X - 2 or base_z < 2 or base_z >= WORLD_Z - 2:
				continue
			if _near_spawn(base_x, base_z) or not _flat_enough(heights, base_x, base_z):
				continue
			_stamp_crystal_cluster(output, origin, heights, cluster_rng, base_x, base_z, false, crystal_id)
	for landmark in LANDMARK_CRYSTALS:
		var landmark_rng := RandomNumberGenerator.new()
		landmark_rng.seed = _column_seed(world_seed, landmark.x, landmark.y, 0x51DE)
		_stamp_crystal_cluster(output, origin, heights, landmark_rng, landmark.x, landmark.y, true, crystal_id)


static func _stamp_crystal_cluster(output: PackedByteArray, origin: Vector3i, heights: PackedInt32Array, rng: RandomNumberGenerator, base_x: int, base_z: int, landmark: bool, crystal_id: int) -> void:
	var center_height := rng.randi_range(12, 14) if landmark else rng.randi_range(7, 10)
	_stamp_shard(output, origin, heights, crystal_id, base_x, base_z, center_height, 2 if landmark else 1, Vector2i.ZERO)
	var shard_count := 3 if landmark else rng.randi_range(2, 3)
	for shard in range(shard_count):
		var angle := rng.randf_range(0.0, TAU)
		var radius := rng.randf_range(2.2, 3.8)
		var shard_x := base_x + roundi(cos(angle) * radius)
		var shard_z := base_z + roundi(sin(angle) * radius)
		if shard_x < 1 or shard_x >= WORLD_X - 1 or shard_z < 1 or shard_z >= WORLD_Z - 1:
			continue
		var shard_height := rng.randi_range(4, 6)
		var lean := Vector2i(roundi(cos(angle)), roundi(sin(angle)))
		_stamp_shard(output, origin, heights, crystal_id, shard_x, shard_z, shard_height, 1, lean)
	var nub_x := base_x + rng.randi_range(-3, 3)
	var nub_z := base_z + rng.randi_range(-3, 3)
	if nub_x >= 1 and nub_x < WORLD_X - 1 and nub_z >= 1 and nub_z < WORLD_Z - 1:
		var nub_ground := heights[nub_x + nub_z * WORLD_X]
		_set_cell(output, origin, Vector3i(nub_x, nub_ground, nub_z), crystal_id)
		if rng.randf() < 0.5:
			_set_cell(output, origin, Vector3i(nub_x, nub_ground + 1, nub_z), crystal_id)


static func _stamp_shard(output: PackedByteArray, origin: Vector3i, heights: PackedInt32Array, crystal_id: int, base_x: int, base_z: int, shard_height: int, width: int, lean: Vector2i) -> void:
	var ground_y := heights[base_x + base_z * WORLD_X]
	var x := base_x
	var z := base_z
	for step in range(shard_height):
		if lean != Vector2i.ZERO and step > 1 and step % 3 == 0:
			x = clampi(x + lean.x, 0, WORLD_X - 1)
			z = clampi(z + lean.y, 0, WORLD_Z - 1)
		var step_width := width if step < shard_height - 3 else 1
		for wide_x in range(step_width):
			for wide_z in range(step_width):
				_set_cell(output, origin, Vector3i(x + wide_x, ground_y + step, z + wide_z), crystal_id)


# --- Ground scatter ---------------------------------------------------------

static func _stamp_ground_scatter(output: PackedByteArray, origin: Vector3i, world_seed: int, heights: PackedInt32Array, soil_id: int, bloom_id: int, mycelium_id: int) -> void:
	var min_gx := floori(float(origin.x) / SCATTER_CELL) - 1
	var max_gx := floori(float(origin.x + CHUNK_SIZE) / SCATTER_CELL) + 1
	var min_gz := floori(float(origin.z) / SCATTER_CELL) - 1
	var max_gz := floori(float(origin.z + CHUNK_SIZE) / SCATTER_CELL) + 1
	for grid_z in range(min_gz, max_gz + 1):
		for grid_x in range(min_gx, max_gx + 1):
			var scatter_rng := RandomNumberGenerator.new()
			scatter_rng.seed = _column_seed(world_seed, grid_x, grid_z, 0x5CA7)
			if scatter_rng.randf() > SCATTER_CHANCE:
				continue
			var center_x := grid_x * SCATTER_CELL + scatter_rng.randi_range(1, SCATTER_CELL - 1)
			var center_z := grid_z * SCATTER_CELL + scatter_rng.randi_range(1, SCATTER_CELL - 1)
			if center_x < 1 or center_x >= WORLD_X - 1 or center_z < 1 or center_z >= WORLD_Z - 1:
				continue
			if _near_spawn(center_x, center_z):
				continue
			var patch_id := mycelium_id if scatter_rng.randf() < 0.3 else bloom_id
			var patch_radius := scatter_rng.randi_range(1, 2)
			for offset_z in range(-patch_radius, patch_radius + 1):
				for offset_x in range(-patch_radius, patch_radius + 1):
					if absi(offset_x) + absi(offset_z) > patch_radius:
						continue
					if scatter_rng.randf() < 0.35:
						continue
					var cell_x := center_x + offset_x
					var cell_z := center_z + offset_z
					if cell_x < 1 or cell_x >= WORLD_X - 1 or cell_z < 1 or cell_z >= WORLD_Z - 1:
						continue
					var ground_y := heights[cell_x + cell_z * WORLD_X]
					if _get_cell(output, origin, Vector3i(cell_x, ground_y, cell_z)) != soil_id:
						continue
					_set_cell(output, origin, Vector3i(cell_x, ground_y, cell_z), patch_id)


# --- Ground props ------------------------------------------------------------
# Scattered boulder clusters, fallen logs, and broken wall remnants sit on the
# ash plain so the terrain reads as a lived-in ruin field rather than a bald dune.

static func _stamp_world_props(output: PackedByteArray, origin: Vector3i, world_seed: int, heights: PackedInt32Array, block_ids: Dictionary) -> void:
	var air_id := int(block_ids[&"air"])
	var stone_id := int(block_ids[&"stone"])
	var wood_id := int(block_ids.get(&"dead_wood", -1))
	var bloom_id := int(block_ids[&"pale_bloom"])
	var mycelium_id := int(block_ids[&"mycelium"])
	var min_gx := floori(float(origin.x - PROP_REACH) / PROP_CELL)
	var max_gx := floori(float(origin.x + CHUNK_SIZE - 1 + PROP_REACH) / PROP_CELL)
	var min_gz := floori(float(origin.z - PROP_REACH) / PROP_CELL)
	var max_gz := floori(float(origin.z + CHUNK_SIZE - 1 + PROP_REACH) / PROP_CELL)
	for grid_z in range(min_gz, max_gz + 1):
		for grid_x in range(min_gx, max_gx + 1):
			var prop_rng := RandomNumberGenerator.new()
			prop_rng.seed = _column_seed(world_seed, grid_x, grid_z, 0x9A17)
			if prop_rng.randf() > PROP_CHANCE:
				continue
			var base_x := grid_x * PROP_CELL + prop_rng.randi_range(1, PROP_CELL - 2)
			var base_z := grid_z * PROP_CELL + prop_rng.randi_range(1, PROP_CELL - 2)
			if base_x < 2 or base_x >= WORLD_X - 2 or base_z < 2 or base_z >= WORLD_Z - 2:
				continue
			if _near_spawn(base_x, base_z) or _near_landmark(base_x, base_z, 4) or not _flat_enough(heights, base_x, base_z):
				continue
			var roll := prop_rng.randf()
			if roll < 0.34:
				_stamp_pebbles(output, origin, heights, prop_rng, base_x, base_z, stone_id, air_id)
			elif roll < 0.64 and wood_id >= 0:
				_stamp_fallen_log(output, origin, heights, prop_rng, base_x, base_z, wood_id, air_id)
			elif roll < 0.84:
				_stamp_ruin(output, origin, heights, prop_rng, base_x, base_z, stone_id, wood_id, air_id)
			else:
				_stamp_prop_shrub(output, origin, heights, prop_rng, base_x, base_z, bloom_id, mycelium_id, air_id)


static func _stamp_pebbles(output: PackedByteArray, origin: Vector3i, heights: PackedInt32Array, rng: RandomNumberGenerator, base_x: int, base_z: int, stone_id: int, air_id: int) -> void:
	_place_prop_cell(output, origin, heights, base_x, base_z, 1, stone_id, air_id)
	var extra := rng.randi_range(1, 3)
	for pebble in range(extra):
		var offset_x := rng.randi_range(-1, 1)
		var offset_z := rng.randi_range(-1, 1)
		_place_prop_cell(output, origin, heights, base_x + offset_x, base_z + offset_z, 1, stone_id, air_id)
	if rng.randf() < 0.4:
		_place_prop_cell(output, origin, heights, base_x + rng.randi_range(-1, 1), base_z + rng.randi_range(-1, 1), 2, stone_id, air_id)


static func _stamp_fallen_log(output: PackedByteArray, origin: Vector3i, heights: PackedInt32Array, rng: RandomNumberGenerator, base_x: int, base_z: int, wood_id: int, air_id: int) -> void:
	var length := rng.randi_range(3, 6)
	var horizontal := rng.randf() < 0.5
	var half := int(length / 2.0)
	for step in range(length):
		var offset := step - half
		var cell_x := base_x + (offset if horizontal else 0)
		var cell_z := base_z + (0 if horizontal else offset)
		_place_prop_cell(output, origin, heights, cell_x, cell_z, 1, wood_id, air_id)
	# A raised broken end and a couple of branch stubs keep the silhouette readable.
	var end_x := base_x + ((length - 1 - half) if horizontal else 0)
	var end_z := base_z + (0 if horizontal else (length - 1 - half))
	_place_prop_cell(output, origin, heights, end_x, end_z, 2, wood_id, air_id)
	var stub_count := rng.randi_range(1, 2)
	for stub in range(stub_count):
		var stub_x := base_x + (rng.randi_range(-1, 1) if horizontal else rng.randi_range(-1, 1))
		var stub_z := base_z + (rng.randi_range(0, 1) if horizontal else rng.randi_range(0, 1))
		_place_prop_cell(output, origin, heights, stub_x, stub_z, 2, wood_id, air_id)


static func _stamp_ruin(output: PackedByteArray, origin: Vector3i, heights: PackedInt32Array, rng: RandomNumberGenerator, base_x: int, base_z: int, stone_id: int, wood_id: int, air_id: int) -> void:
	var length := rng.randi_range(3, 5)
	var horizontal := rng.randf() < 0.5
	var gap := rng.randi_range(1, length - 2)
	var pillar := rng.randi_range(0, length - 1)
	for step in range(length):
		if step == gap:
			continue
		var wall_height := 2
		if step == pillar:
			wall_height = 3
		elif rng.randf() < 0.3:
			wall_height = 1
		var offset := step - int(length / 2.0)
		var cell_x := base_x + (offset if horizontal else 0)
		var cell_z := base_z + (0 if horizontal else offset)
		for level in range(1, wall_height + 1):
			_place_prop_cell(output, origin, heights, cell_x, cell_z, level, stone_id, air_id)
		if step == pillar and wood_id >= 0:
			_place_prop_cell(output, origin, heights, cell_x, cell_z, wall_height + 1, wood_id, air_id)
	# Rubble knocked loose from the wall.
	var rubble := rng.randi_range(1, 2)
	for piece in range(rubble):
		_place_prop_cell(output, origin, heights, base_x + rng.randi_range(-2, 2), base_z + rng.randi_range(-2, 2), 1, stone_id, air_id)


static func _stamp_prop_shrub(output: PackedByteArray, origin: Vector3i, heights: PackedInt32Array, rng: RandomNumberGenerator, base_x: int, base_z: int, bloom_id: int, mycelium_id: int, air_id: int) -> void:
	var shrub_id := mycelium_id if rng.randf() < 0.45 else bloom_id
	var clump := rng.randi_range(2, 4)
	for blade in range(clump):
		var cell_x := base_x + rng.randi_range(-1, 1)
		var cell_z := base_z + rng.randi_range(-1, 1)
		_place_prop_cell(output, origin, heights, cell_x, cell_z, 1, shrub_id, air_id)
		if rng.randf() < 0.35:
			_place_prop_cell(output, origin, heights, cell_x, cell_z, 2, shrub_id, air_id)


static func _place_prop_cell(output: PackedByteArray, origin: Vector3i, heights: PackedInt32Array, x: int, z: int, offset_y: int, block_id: int, air_id: int) -> void:
	if x < 1 or x >= WORLD_X - 1 or z < 1 or z >= WORLD_Z - 1:
		return
	var cell := Vector3i(x, heights[x + z * WORLD_X] + offset_y, z)
	if cell.y < 1 or cell.y >= WORLD_Y - 1:
		return
	if _get_cell(output, origin, cell) != air_id:
		return
	_set_cell(output, origin, cell, block_id)


static func _near_landmark(x: int, z: int, radius: int) -> bool:
	for landmark in LANDMARK_TREES:
		if absi(x - landmark.x) <= radius and absi(z - landmark.y) <= radius:
			return true
	for landmark in LANDMARK_CRYSTALS:
		if absi(x - landmark.x) <= radius and absi(z - landmark.y) <= radius:
			return true
	return false


static func _get_cell(output: PackedByteArray, origin: Vector3i, cell: Vector3i) -> int:
	var local_x := cell.x - origin.x
	var local_y := cell.y - origin.y
	var local_z := cell.z - origin.z
	if local_x < 0 or local_x >= CHUNK_SIZE or local_y < 0 or local_y >= CHUNK_SIZE or local_z < 0 or local_z >= CHUNK_SIZE:
		return -1
	return output[local_x + local_y * CHUNK_SIZE + local_z * CHUNK_SIZE * CHUNK_SIZE]


static func _set_cell(output: PackedByteArray, origin: Vector3i, cell: Vector3i, block_id: int) -> void:
	var local_x := cell.x - origin.x
	var local_y := cell.y - origin.y
	var local_z := cell.z - origin.z
	if local_x < 0 or local_x >= CHUNK_SIZE or local_y < 0 or local_y >= CHUNK_SIZE or local_z < 0 or local_z >= CHUNK_SIZE:
		return
	output[local_x + local_y * CHUNK_SIZE + local_z * CHUNK_SIZE * CHUNK_SIZE] = block_id


static func _near_spawn(x: int, z: int) -> bool:
	return absi(x - SPAWN_X) <= 7 and absi(z - SPAWN_Z) <= 7


static func _column_seed(world_seed: int, x: int, z: int, salt: int) -> int:
	var value := world_seed * 1103515245 + x * 73856093 + z * 19349663 + salt
	value = (value ^ (value >> 13)) * 1274126177
	return value & 0x7fffffff
