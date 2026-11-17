extends SceneTree

# Standalone verification of the four biome palettes. It calls WorldGenerator
# directly with a hand-built block-id table, so it needs no world scene, no
# chunk streaming and no worker threads.

const SEED := 139732
const CHUNK := 16

const BLOCK_IDS := {
	&"air": 0,
	&"stone": 1,
	&"ashen_soil": 2,
	&"canyon_gravel": 3,
	&"mycelium": 4,
	&"dead_wood": 5,
	&"pale_wood": 6,
	&"lumen_crystal": 7,
	&"iron_ore": 8,
	&"torch": 9,
	&"frost_snow": 10,
	&"frost_ice": 11,
	&"mire_mud": 12,
	&"toxic_silt": 13,
	&"rotted_ashen_soil": 14,
}

const BLOCK_RESOURCES := {
	&"frost_snow": "res://data/blocks/frost_snow.tres",
	&"frost_ice": "res://data/blocks/frost_ice.tres",
	&"mire_mud": "res://data/blocks/mire_mud.tres",
	&"toxic_silt": "res://data/blocks/toxic_silt.tres",
}

const SURFACE_MARKERS := {
	BiomeManager.ASHEN: [&"ashen_soil", &"canyon_gravel", &"stone"],
	BiomeManager.HUSH: [&"mycelium"],
	BiomeManager.FROST: [&"frost_snow", &"frost_ice"],
	BiomeManager.MIRE: [&"mire_mud", &"toxic_silt"],
}

var failures := 0


func _check(condition: bool, label: String, detail := "") -> void:
	if not condition:
		failures += 1
		push_error("BIOME SURFACE FAIL: %s %s" % [label, detail])
		return
	print("BIOME SURFACE PASS: %s %s" % [label, detail])


func _initialize() -> void:
	BiomeManager.configure(SEED)
	_run()


func _run() -> void:
	# The four new block definitions must load with the ids the generator asks for.
	var albedos: Array[Color] = []
	for block_name in BLOCK_RESOURCES:
		var definition := load(BLOCK_RESOURCES[block_name]) as BlockLightDef
		_check(definition != null, "block resource loads", str(block_name))
		if definition == null:
			continue
		_check(definition.block_id == block_name, "block resource id matches", "%s -> %s" % [block_name, definition.block_id])
		albedos.append(definition.albedo)
	for first in range(albedos.size()):
		for second in range(first + 1, albedos.size()):
			_check(not albedos[first].is_equal_approx(albedos[second]), "biome surfaces use distinct colours", "%d vs %d" % [first, second])

	for biome in [BiomeManager.ASHEN, BiomeManager.HUSH, BiomeManager.FROST, BiomeManager.MIRE]:
		var chunk := _find_biome_chunk(biome)
		_check(chunk.x != 1 << 20, "biome exists within the survey area", BiomeManager.biome_name(biome))
		if chunk.x == 1 << 20:
			continue
		var center_height: int = BiomeManager.get_height(chunk.x * CHUNK + 8, chunk.y * CHUNK + 8)
		var chunk_y := clampi(center_height / CHUNK, 0, 3)
		var blocks := WorldGenerator.generate_chunk(Vector3i(chunk.x, chunk_y, chunk.y), SEED, BLOCK_IDS)
		_check(blocks.size() == CHUNK * CHUNK * CHUNK, "chunk generates full volume", BiomeManager.biome_name(biome))

		var marker_ids: Array[int] = []
		for marker in SURFACE_MARKERS[biome]:
			marker_ids.append(int(BLOCK_IDS[marker]))
		var matching := 0
		var checked_columns := 0
		for local_z in range(CHUNK):
			for local_x in range(CHUNK):
				var world_x := chunk.x * CHUNK + local_x
				var world_z := chunk.y * CHUNK + local_z
				var surface_y: int = BiomeManager.get_height(world_x, world_z)
				if surface_y / CHUNK != chunk_y:
					continue
				checked_columns += 1
				var top_id := int(blocks[local_x + (surface_y - chunk_y * CHUNK) * CHUNK + local_z * CHUNK * CHUNK])
				if marker_ids.has(top_id):
					matching += 1
		_check(checked_columns > 0, "sampled columns land in the generated chunk", BiomeManager.biome_name(biome))
		# Hushwoods and Frostfall should be almost entirely on their own palette;
		# Ashen and the Mire keep blended border columns in the same chunk.
		var ratio := float(matching) / float(maxi(1, checked_columns))
		var minimum := 0.5 if biome == BiomeManager.ASHEN or biome == BiomeManager.MIRE else 0.8
		_check(ratio >= minimum, "surface palette matches biome", "%s: %d/%d (%.2f)" % [BiomeManager.biome_name(biome), matching, checked_columns, ratio])

		var again := WorldGenerator.generate_chunk(Vector3i(chunk.x, chunk_y, chunk.y), SEED, BLOCK_IDS)
		_check(blocks == again, "chunk generation is deterministic", BiomeManager.biome_name(biome))

	if failures > 0:
		quit(1)
		return
	print("BIOME SURFACE CHECK PASS: four biome palettes generate without a world or streaming")
	quit(0)


func _find_biome_chunk(target: int) -> Vector2i:
	for grid_z in range(-40, 41):
		for grid_x in range(-40, 41):
			if BiomeManager.dominant_biome(grid_x * CHUNK + 8, grid_z * CHUNK + 8) != target:
				continue
			var weights := BiomeManager.get_weights(grid_x * CHUNK + 8, grid_z * CHUNK + 8)
			if weights[target] > 0.85:
				return Vector2i(grid_x, grid_z)
			if target == BiomeManager.ASHEN and Vector2i(grid_x, grid_z) == Vector2i(4, 4):
				return Vector2i(grid_x, grid_z)
	return Vector2i(1 << 20, 1 << 20)
