extends RefCounted
class_name WorldGenerator

const WORLD_X := 128
const WORLD_Y := 64
const WORLD_Z := 128
const CHUNK_SIZE := 16
const CHUNKS_X := 8
const CHUNKS_Y := 4
const CHUNKS_Z := 8


static func build_maps(world_seed: int) -> Dictionary:
	var terrain_noise := FastNoiseLite.new()
	terrain_noise.seed = world_seed
	terrain_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	terrain_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	terrain_noise.fractal_octaves = 4
	terrain_noise.frequency = 0.018
	var detail_noise := FastNoiseLite.new()
	detail_noise.seed = world_seed ^ 0x51A7
	detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	detail_noise.fractal_octaves = 2
	detail_noise.frequency = 0.055
	var heights := PackedInt32Array()
	heights.resize(WORLD_X * WORLD_Z)
	var biome_map := PackedByteArray()
	biome_map.resize(WORLD_X * WORLD_Z)
	biome_map.fill(0)
	for z in range(WORLD_Z):
		for x in range(WORLD_X):
			var height_value := 21.0 + terrain_noise.get_noise_2d(float(x), float(z)) * 7.0
			height_value += detail_noise.get_noise_2d(float(x), float(z)) * 2.0
			heights[x + z * WORLD_X] = clampi(roundi(height_value), 10, 38)
	return {"heights": heights, "biome_map": biome_map}


static func generate_chunk(chunk_index: int, world_seed: int, heights: PackedInt32Array, block_ids: Dictionary) -> PackedByteArray:
	var chunk_x := chunk_index % CHUNKS_X
	var chunk_z := int(chunk_index / CHUNKS_X) % CHUNKS_Z
	var chunk_y := int(chunk_index / (CHUNKS_X * CHUNKS_Z))
	var origin_x := chunk_x * CHUNK_SIZE
	var origin_y := chunk_y * CHUNK_SIZE
	var origin_z := chunk_z * CHUNK_SIZE
	var chunk_seed := int((world_seed * 1103515245 + chunk_x * 73856093 + chunk_y * 19349663 + chunk_z * 83492791) & 0x7fffffff)
	var rng := RandomNumberGenerator.new()
	rng.seed = chunk_seed
	var cave_noise := FastNoiseLite.new()
	cave_noise.seed = world_seed ^ 0x2C79
	cave_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	cave_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	cave_noise.fractal_octaves = 2
	cave_noise.frequency = 0.075
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
				elif world_y == surface_y:
					block_id = block_ids[&"ashen_soil"]
				elif world_y >= surface_y - 4:
					block_id = block_ids[&"dirt"]
				else:
					block_id = block_ids[&"stone"]
					if world_y < 12 and cave_noise.get_noise_3d(float(world_x), float(world_y), float(world_z)) > 0.48:
						block_id = block_ids[&"air"]
					elif rng.randf() < 0.0025:
						block_id = block_ids[&"lumen_crystal"] if rng.randf() < 0.08 else block_ids[&"iron_ore"]
				var local_index := x + y * CHUNK_SIZE + z * CHUNK_SIZE * CHUNK_SIZE
				output[local_index] = block_id
	return output
