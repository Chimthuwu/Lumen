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

const TREE_CELL := 14
const TREE_CHANCE := 0.18
# Hushwoods: a pale dead forest across the north-west, walled off from the ash
# flats by a noisy border. Voxel trees (rather than the MultiMesh trees) keep
# the pale wood harvestable and the forest dense enough to feel enclosed.
const HUSH_MAX_X := 46
const HUSH_MAX_Z := 42
const HUSH_EDGE := 7.0
const HUSH_TREE_CELL := 4
const HUSH_TREE_CHANCE := 0.78
const HUSH_TREE_REACH := 6
const HUSH_TREE_MIN_HEIGHT := 12
const HUSH_TREE_MAX_HEIGHT := 20
const TREE_REACH := 8
const TREE_MIN_HEIGHT := 7
const TREE_MAX_HEIGHT := 12
# Ashen Flats is a canyon country: two deep, winding channels cut through
# rocky shelves and mesas, with wide open ground between them. Depths are
# carved from the heightfield rather than stamped, so the whole basin stays
# walkable and the voxel collision mesh needs no special cases.
const RIVER_CENTER_X := 94.0
const RIVER_WIDTH := 12.0
const RIVER_WALL := 12.0
const RIVER_BED_HEIGHT := 14.0
const RAVINE_CENTER_X := 25.0
const RAVINE_WIDTH := 8.0
const RAVINE_WALL := 11.0
const RAVINE_BED_HEIGHT := 12.5
const RAVINE_MIN_Z := 48
const CANYON_FLOOR_MAX := 19
const MESA_HEIGHT := 34.0
const CRYSTAL_CELL := 24
const CRYSTAL_CHANCE := 0.26
const CRYSTAL_REACH := 10
const ASH_BLOOM_CHANCE := 0.32
const SCATTER_CELL := 5
const SCATTER_CHANCE := 0.012
const PROP_CELL := 11
const PROP_CHANCE := 0.16
const PROP_REACH := 8

const LANDMARK_TREES := [
	Vector2i(75, 60), Vector2i(54, 67), Vector2i(79, 72), Vector2i(61, 80)
]
const LANDMARK_CRYSTALS := [Vector2i(80, 51), Vector2i(46, 77)]
const LANDMARK_SPIRES := [Vector2i(54, 112), Vector2i(112, 60), Vector2i(82, 14)]
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
	var shelf_noise := _make_noise(world_seed ^ 0x71C3, 3, 0.052)
	shelf_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	var ridge_noise := _make_noise(world_seed ^ 0x6D2B, 4, 0.013)
	ridge_noise.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	var mesa_noise := _make_noise(world_seed ^ 0x39AF, 2, 0.017)
	var river_noise := _make_noise(world_seed ^ 0x2E77, 2, 0.06)
	var ravine_noise := _make_noise(world_seed ^ 0x5B2D, 2, 0.075)
	var hush_noise := _make_noise(world_seed ^ 0x4B17, 2, 0.045)
	var heights := PackedInt32Array()
	heights.resize(WORLD_X * WORLD_Z)
	var biome_map := PackedByteArray()
	biome_map.resize(WORLD_X * WORLD_Z)
	biome_map.fill(0)
	for z in range(WORLD_Z):
		for x in range(WORLD_X):
			var height_value := SURFACE_BASE_HEIGHT
			height_value += broad_noise.get_noise_2d(float(x), float(z)) * 8.4
			height_value += hill_noise.get_noise_2d(float(x), float(z)) * 3.4
			height_value += detail_noise.get_noise_2d(float(x), float(z)) * 0.4

			# Rocky shelves: ridged noise lifted into broken ledges so the open
			# ground reads as weathered rock rather than a smooth dune.
			var shelf := clampf(shelf_noise.get_noise_2d(float(x), float(z)) * 0.5 + 0.5, 0.0, 1.0)
			height_value += smoothstep(0.42, 0.78, shelf) * 3.0

			# Ridges: sharp ridged noise lifted into long spines that break the
			# dune horizon without touching the spawn basin.
			var ridge := clampf(ridge_noise.get_noise_2d(float(x), float(z)) * 0.5 + 0.5, 0.0, 1.0)
			var ridge_mask := smoothstep(0.58, 0.92, ridge)
			height_value += ridge_mask * ridge_mask * 13.0

			# Mesas: low-frequency plateaus with short cliff walls. Only raises
			# ground so the plains and canyons keep their shape.
			var mesa := mesa_noise.get_noise_2d(float(x) * 0.62, float(z) * 0.62)
			var mesa_mask := smoothstep(0.14, 0.32, mesa)
			var plateau := MESA_HEIGHT + detail_noise.get_noise_2d(float(x), float(z)) * 2.0
			height_value = lerpf(height_value, maxf(height_value, plateau), mesa_mask)

			# Landmark buttes get a rocky plinth so their stone bases grow out of
			# the ground instead of sitting on top of it.
			for spire in LANDMARK_SPIRES:
				var spire_distance := Vector2(float(x - spire.x), float(z - spire.y)).length()
				if spire_distance < 10.0:
					height_value += smoothstep(10.0, 2.0, spire_distance) * 3.8

			# Dry river canyon: a wide, winding channel east of spawn. The bed is
			# bare rock and gravel, with a braided inner channel and long sloping
			# walls that can be walked in and out of.
			var river_center := RIVER_CENTER_X + sin(float(z) * 0.07) * 13.0 + sin(float(z) * 0.023 + 2.1) * 6.0
			var river_distance := absf(float(x) - river_center)
			if river_distance < RIVER_WIDTH + RIVER_WALL:
				var canyon_bed := RIVER_BED_HEIGHT - 0.9 + river_noise.get_noise_2d(float(x), float(z)) * 0.9
				var braid := smoothstep(3.0, 0.5, river_distance) * 1.1
				var wall := smoothstep(RIVER_WIDTH, RIVER_WIDTH + RIVER_WALL, river_distance)
				height_value = lerpf(canyon_bed - braid, height_value, wall)

			# Western ravine: a second deep cut in the southern flats, fading in
			# below the Hushwoods border so the forest rim stays intact.
			if z > RAVINE_MIN_Z:
				var ravine_center := RAVINE_CENTER_X + sin(float(z) * 0.075) * 7.0 + sin(float(z) * 0.031 + 1.3) * 4.0
				var ravine_distance := absf(float(x) - ravine_center)
				if ravine_distance < RAVINE_WIDTH + RAVINE_WALL:
					var ravine_bed := RAVINE_BED_HEIGHT + ravine_noise.get_noise_2d(float(x), float(z)) * 1.2
					var ravine_wall := smoothstep(RAVINE_WIDTH, RAVINE_WIDTH + RAVINE_WALL, ravine_distance)
					var fade := smoothstep(float(RAVINE_MIN_Z), float(RAVINE_MIN_Z) + 12.0, float(z))
					height_value = lerpf(ravine_bed, height_value, lerpf(1.0, ravine_wall, fade))

			# Deep chasm west of spawn: a winding split in the plain with steep
			# walls and a dark, uneven floor.
			var chasm_center := 33.0 + sin(float(z) * 0.055) * 7.0 + sin(float(z) * 0.021 + 1.7) * 3.0
			var chasm_distance := absf(float(x) - chasm_center)
			var chasm_edge := smoothstep(5.5, 1.2, chasm_distance)
			if chasm_edge > 0.001:
				var chasm_floor := 13.0 + detail_noise.get_noise_2d(float(x) * 1.7, float(z) * 1.7) * 1.8
				height_value = lerpf(height_value, chasm_floor, chasm_edge)

			# Towering mesa landmark in the north-east: sheer walls, flat crown.
			var tower_distance := Vector2(float(x) - 103.0, float(z) - 33.0).length()
			if tower_distance < 15.0:
				var tower_mask := smoothstep(15.0, 9.0, tower_distance)
				var crown := 50.0 + detail_noise.get_noise_2d(float(x) * 0.8, float(z) * 0.8) * 1.2
				height_value = lerpf(height_value, crown, tower_mask)

			heights[x + z * WORLD_X] = clampi(roundi(height_value), 12, 52)

			# Hushwoods border: both coordinates must pass a noise-thickened
			# threshold, so the treeline wanders instead of forming a corner.
			var hush_x := float(HUSH_MAX_X - x) + hush_noise.get_noise_2d(float(x), float(z)) * HUSH_EDGE
			var hush_z := float(HUSH_MAX_Z - z) + hush_noise.get_noise_2d(float(x) + 53.0, float(z) - 31.0) * HUSH_EDGE
			if hush_x > 0.0 and hush_z > 0.0:
				biome_map[x + z * WORLD_X] = 1
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


static func generate_chunk(chunk_index: int, world_seed: int, heights: PackedInt32Array, block_ids: Dictionary, tree_sites: Array = [], biome_map: PackedByteArray = PackedByteArray()) -> PackedByteArray:
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
	var hush_soil_id := int(block_ids.get(&"hush_soil", block_ids[&"ashen_soil"]))
	var gravel_id := int(block_ids.get(&"canyon_gravel", block_ids[&"ashen_soil"]))
	var pale_wood_id := int(block_ids.get(&"pale_wood", block_ids.get(&"dead_wood", -1)))
	for z in range(CHUNK_SIZE):
		var world_z := origin_z + z
		for y in range(CHUNK_SIZE):
			var world_y := origin_y + y
			for x in range(CHUNK_SIZE):
				var world_x := origin_x + x
				var surface_y := heights[world_x + world_z * WORLD_X]
				var hush := _hush_at(biome_map, world_x, world_z)
				var block_id: int
				if world_x == 64 and world_z == 58 and world_y == surface_y + 1:
					block_id = block_ids[&"torch"]
				elif world_y > surface_y:
					continue
				else:
					var rock := rock_noise.get_noise_2d(float(world_x), float(world_z))
					var slope := _surface_slope(heights, world_x, world_z)
					var canyon_floor := surface_y <= CANYON_FLOOR_MAX
					var rocky := slope >= 2 or rock > 0.62
					if world_y == surface_y:
						if rocky:
							block_id = block_ids[&"stone"]
						elif hush and surface_y > 16:
							block_id = hush_soil_id
						elif canyon_floor:
							block_id = gravel_id
						else:
							block_id = block_ids[&"ashen_soil"]
					elif world_y >= surface_y - 3:
						if rocky:
							block_id = block_ids[&"stone"]
						elif hush and surface_y > 16:
							block_id = hush_soil_id
						elif canyon_floor:
							block_id = gravel_id
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
	_stamp_ground_scatter(output, origin, world_seed, heights, int(block_ids[&"ashen_soil"]), int(block_ids[&"pale_bloom"]), int(block_ids[&"mycelium"]), hush_soil_id, biome_map)
	_stamp_world_props(output, origin, world_seed, heights, block_ids, biome_map)
	_stamp_spires(output, origin, world_seed, heights, int(block_ids[&"stone"]), int(block_ids[&"air"]))
	if pale_wood_id >= 0:
		_stamp_hush_trees(output, origin, world_seed, heights, biome_map, pale_wood_id)
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
static func collect_tree_sites(world_seed: int, heights: PackedInt32Array, biome_map: PackedByteArray = PackedByteArray()) -> Array:
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
			if _near_spawn(base_x, base_z) or _hush_at(biome_map, base_x, base_z):
				continue
			# Canyon floors are intentionally treeless; dead trunks belong on the
			# high shelves where they read as isolated silhouettes.
			if heights[base_x + base_z * WORLD_X] <= CANYON_FLOOR_MAX:
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
	var center_height := rng.randi_range(10, 12) if landmark else rng.randi_range(6, 8)
	_stamp_shard(output, origin, heights, crystal_id, base_x, base_z, center_height, 2 if landmark else 1, Vector2i.ZERO)
	var shard_count := 3 if landmark else rng.randi_range(2, 3)
	for shard in range(shard_count):
		var angle := rng.randf_range(0.0, TAU)
		var radius := rng.randf_range(2.2, 3.8)
		var shard_x := base_x + roundi(cos(angle) * radius)
		var shard_z := base_z + roundi(sin(angle) * radius)
		if shard_x < 1 or shard_x >= WORLD_X - 1 or shard_z < 1 or shard_z >= WORLD_Z - 1:
			continue
		var shard_height := rng.randi_range(3, 5)
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
				var cell_x := x + wide_x
				var cell_z := z + wide_z
				var cell_y := ground_y + step
				var column_ground := heights[cell_x + cell_z * WORLD_X]
				if cell_y < column_ground:
					continue
				# Leaning shards step into a neighbouring column. Fill that
				# column down to its own surface so the shard stays rooted
				# instead of starting as a floating blade in mid-air.
				for fill_y in range(column_ground, cell_y):
					_set_cell(output, origin, Vector3i(cell_x, fill_y, cell_z), crystal_id)
				_set_cell(output, origin, Vector3i(cell_x, cell_y, cell_z), crystal_id)


# --- Ground scatter ---------------------------------------------------------

static func _stamp_ground_scatter(output: PackedByteArray, origin: Vector3i, world_seed: int, heights: PackedInt32Array, soil_id: int, bloom_id: int, mycelium_id: int, hush_soil_id: int, biome_map: PackedByteArray) -> void:
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
			if heights[center_x + center_z * WORLD_X] <= CANYON_FLOOR_MAX:
				continue
			var hush_patch := _hush_at(biome_map, center_x, center_z)
			var patch_id := mycelium_id if scatter_rng.randf() < (0.62 if hush_patch else 0.3) else bloom_id
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
					var expected_soil := hush_soil_id if _hush_at(biome_map, cell_x, cell_z) else soil_id
					if _get_cell(output, origin, Vector3i(cell_x, ground_y, cell_z)) != expected_soil:
						continue
					_set_cell(output, origin, Vector3i(cell_x, ground_y, cell_z), patch_id)


# --- Ground props ------------------------------------------------------------
# Scattered boulder clusters, fallen logs, and broken wall remnants sit on the
# ash plain so the terrain reads as a lived-in ruin field rather than a bald dune.

static func _stamp_world_props(output: PackedByteArray, origin: Vector3i, world_seed: int, heights: PackedInt32Array, block_ids: Dictionary, biome_map: PackedByteArray = PackedByteArray()) -> void:
	var air_id := int(block_ids[&"air"])
	var stone_id := int(block_ids[&"stone"])
	var wood_id := int(block_ids.get(&"dead_wood", -1))
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
			if _hush_at(biome_map, base_x, base_z):
				continue
			var roll := prop_rng.randf()
			if roll < 0.34:
				_stamp_pebbles(output, origin, heights, prop_rng, base_x, base_z, stone_id, air_id)
			elif roll < 0.74:
				_stamp_boulder(output, origin, heights, prop_rng, base_x, base_z, stone_id, air_id)
			elif roll < 0.90 and wood_id >= 0:
				_stamp_ruin(output, origin, heights, prop_rng, base_x, base_z, stone_id, wood_id, air_id)
			else:
				_stamp_boulder(output, origin, heights, prop_rng, base_x, base_z, stone_id, air_id)


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


# A clustered stack of stone that reads as an eroded boulder rather than a
# lone cube. Blocks are placed per-column against that column's own surface so
# the formation clings to uneven ground.
static func _stamp_boulder(output: PackedByteArray, origin: Vector3i, heights: PackedInt32Array, rng: RandomNumberGenerator, base_x: int, base_z: int, stone_id: int, air_id: int) -> void:
	var width := rng.randi_range(1, 2)
	var height := rng.randi_range(2, 4)
	for level in range(height):
		var radius := width
		if level > 0 and width > 1:
			radius = width - 1
		for offset_z in range(-radius, radius + 1):
			for offset_x in range(-radius, radius + 1):
				if offset_x * offset_x + offset_z * offset_z > radius * radius + 1:
					continue
				if level > 0 and rng.randf() < 0.22:
					continue
				_place_prop_cell(output, origin, heights, base_x + offset_x, base_z + offset_z, 1 + level, stone_id, air_id)
	# A leaning capstone catches the light and keeps the silhouette irregular.
	_place_prop_cell(output, origin, heights, base_x + rng.randi_range(-1, 1), base_z + rng.randi_range(-1, 1), height + 1, stone_id, air_id)


static func _place_prop_cell(output: PackedByteArray, origin: Vector3i, heights: PackedInt32Array, x: int, z: int, offset_y: int, block_id: int, air_id: int) -> void:
	if x < 1 or x >= WORLD_X - 1 or z < 1 or z >= WORLD_Z - 1:
		return
	var cell := Vector3i(x, heights[x + z * WORLD_X] + offset_y, z)
	if cell.y < 1 or cell.y >= WORLD_Y - 1:
		return
	if _get_cell(output, origin, cell) != air_id:
		return
	_set_cell(output, origin, cell, block_id)


# --- Landmark rock spires ----------------------------------------------------
# Three deliberate, widely spaced stone buttes break the horizon. Each is
# stamped from its fixed root so neighbouring chunks rebuild the same blocks.

static func _stamp_spires(output: PackedByteArray, origin: Vector3i, world_seed: int, heights: PackedInt32Array, stone_id: int, air_id: int) -> void:
	for spire: Vector2i in LANDMARK_SPIRES:
		var rng := RandomNumberGenerator.new()
		rng.seed = _column_seed(world_seed, spire.x, spire.y, 0x5A17)
		var base_y := heights[spire.x + spire.y * WORLD_X]
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
					# Root each column at its own surface so the pillar does not
					# float over the slope of its mound.
					var column_ground := heights[cell_x + cell_z * WORLD_X]
					for fill_y in range(maxi(column_ground, y - 5), y):
						_set_cell(output, origin, Vector3i(cell_x, fill_y, cell_z), stone_id)
					_set_cell(output, origin, Vector3i(cell_x, y, cell_z), stone_id)
			if step > 2 and step % 4 == 0:
				x = clampi(x + lean.x, 2, WORLD_X - 3)
				z = clampi(z + lean.y, 2, WORLD_Z - 3)
		_set_cell(output, origin, Vector3i(x, base_y + height + 1, z), stone_id)
		for piece in range(7):
			var angle := rng.randf_range(0.0, TAU)
			var radius := rng.randf_range(3.0, 6.5)
			var rubble_x := spire.x + roundi(cos(angle) * radius)
			var rubble_z := spire.y + roundi(sin(angle) * radius)
			_place_prop_cell(output, origin, heights, rubble_x, rubble_z, 1, stone_id, air_id)


static func _near_landmark(x: int, z: int, radius: int) -> bool:
	for landmark in LANDMARK_TREES:
		if absi(x - landmark.x) <= radius and absi(z - landmark.y) <= radius:
			return true
	for landmark in LANDMARK_CRYSTALS:
		if absi(x - landmark.x) <= radius and absi(z - landmark.y) <= radius:
			return true
	for landmark in LANDMARK_SPIRES:
		if absi(x - landmark.x) <= radius + 4 and absi(z - landmark.y) <= radius + 4:
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


# --- Hushwoods pale trees ---------------------------------------------------

# Voxel trunks and bare branch arms. Each tree is stamped from its grid cell so
# neighbouring chunks reproduce the same blocks without seams.
static func _stamp_hush_trees(output: PackedByteArray, origin: Vector3i, world_seed: int, heights: PackedInt32Array, biome_map: PackedByteArray, wood_id: int) -> void:
	var min_gx := floori(float(origin.x - HUSH_TREE_REACH) / HUSH_TREE_CELL)
	var max_gx := floori(float(origin.x + CHUNK_SIZE - 1 + HUSH_TREE_REACH) / HUSH_TREE_CELL)
	var min_gz := floori(float(origin.z - HUSH_TREE_REACH) / HUSH_TREE_CELL)
	var max_gz := floori(float(origin.z + CHUNK_SIZE - 1 + HUSH_TREE_REACH) / HUSH_TREE_CELL)
	for grid_z in range(min_gz, max_gz + 1):
		for grid_x in range(min_gx, max_gx + 1):
			var tree_rng := RandomNumberGenerator.new()
			tree_rng.seed = _column_seed(world_seed, grid_x, grid_z, 0x6E55)
			if tree_rng.randf() > HUSH_TREE_CHANCE:
				continue
			var base_x := grid_x * HUSH_TREE_CELL + tree_rng.randi_range(1, HUSH_TREE_CELL - 2)
			var base_z := grid_z * HUSH_TREE_CELL + tree_rng.randi_range(1, HUSH_TREE_CELL - 2)
			if base_x < 2 or base_x >= WORLD_X - 2 or base_z < 2 or base_z >= WORLD_Z - 2:
				continue
			if not _hush_at(biome_map, base_x, base_z) or not _flat_enough(heights, base_x, base_z):
				continue
			var base_y := heights[base_x + base_z * WORLD_X]
			if base_y < 15:
				continue
			var height := tree_rng.randi_range(HUSH_TREE_MIN_HEIGHT, HUSH_TREE_MAX_HEIGHT)
			_stamp_hush_tree(output, origin, tree_rng, base_x, base_y, base_z, height, wood_id)


static func _stamp_hush_tree(output: PackedByteArray, origin: Vector3i, rng: RandomNumberGenerator, base_x: int, base_y: int, base_z: int, height: int, wood_id: int) -> void:
	var x := base_x
	var z := base_z
	var lean := Vector2i.ZERO
	if rng.randf() < 0.7:
		lean = Vector2i(rng.randi_range(-1, 1), rng.randi_range(-1, 1))
		if lean == Vector2i.ZERO:
			lean = Vector2i(1, 0)
	for step in range(height):
		var y := base_y + 1 + step
		_set_cell(output, origin, Vector3i(x, y, z), wood_id)
		if step == 0:
			# Root flare: a wider foot keeps the trunks from looking planted on
			# top of the soil like fence posts.
			_set_cell(output, origin, Vector3i(x + lean.x, y, z), wood_id)
			_set_cell(output, origin, Vector3i(x, y, z + lean.y), wood_id)
		if step >= 4 and step <= height - 3 and step % 3 == 2 and rng.randf() < 0.6:
			x = clampi(x + lean.x, 1, WORLD_X - 2)
			z = clampi(z + lean.y, 1, WORLD_Z - 2)
		if step >= 4 and step % 3 == 0 and rng.randf() < 0.75:
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
	# Fork upward at the tip so the arm ends in a twig rather than a floating stub.
	_set_cell(output, origin, Vector3i(x, y + 1, z), wood_id)
	_set_cell(output, origin, Vector3i(x, y + 2, z), wood_id)


static func _hush_at(biome_map: PackedByteArray, x: int, z: int) -> bool:
	if biome_map.is_empty():
		return false
	return biome_map[x + z * WORLD_X] == 1


static func _near_spawn(x: int, z: int) -> bool:
	return absi(x - SPAWN_X) <= 7 and absi(z - SPAWN_Z) <= 7


static func _column_seed(world_seed: int, x: int, z: int, salt: int) -> int:
	var value := world_seed * 1103515245 + x * 73856093 + z * 19349663 + salt
	value = (value ^ (value >> 13)) * 1274126177
	return value & 0x7fffffff
