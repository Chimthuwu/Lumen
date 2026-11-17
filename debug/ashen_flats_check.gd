extends SceneTree

# Headless audit of the Ashen Flats redesign: canyon depth and coverage, gravel
# floors, rock cliffs, landmark spires, sparse vegetation and intact Hushwoods.

var main: Node
var failures := 0


func _initialize() -> void:
	main = load("res://scenes/world/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _check(condition: bool, label: String, detail := "") -> void:
	if not condition:
		failures += 1
		push_error("ASHEN CHECK FAIL: %s %s" % [label, detail])
		return
	print("ASHEN CHECK PASS: %s %s" % [label, detail])


func _run() -> void:
	while not main.world.is_generated:
		await process_frame
	var world: VoxelWorld = main.world
	var heights: PackedInt32Array = world.heights
	var biome_map: PackedByteArray = world.biome_map
	var width := WorldGenerator.WORLD_X
	var biome_hush := 0
	var canyon_columns := 0
	var ashen_canyon := 0
	var deep_columns := 0
	var cliff_columns := 0
	var height_total := 0
	for z in range(width):
		for x in range(width):
			var here: int = heights[x + z * width]
			height_total += here
			var biome: int = biome_map[x + z * width]
			if biome == 1:
				biome_hush += 1
			if here <= WorldGenerator.CANYON_FLOOR_MAX:
				canyon_columns += 1
				if biome == 0:
					ashen_canyon += 1
				if here <= 16:
					deep_columns += 1
			var slope := 0
			if x > 0:
				slope = maxi(slope, absi(here - heights[x - 1 + z * width]))
			if x < width - 1:
				slope = maxi(slope, absi(here - heights[x + 1 + z * width]))
			if z > 0:
				slope = maxi(slope, absi(here - heights[x + (z - 1) * width]))
			if z < width - 1:
				slope = maxi(slope, absi(here - heights[x + (z + 1) * width]))
			if slope >= 3:
				cliff_columns += 1

	var gravel_id: int = world.block_ids[&"canyon_gravel"]
	var stone_id: int = world.block_ids[&"stone"]
	var gravel_blocks := 0
	var stone_blocks := 0
	for index in range(world.blocks.size()):
		var block_id: int = world.blocks[index]
		if block_id == gravel_id:
			gravel_blocks += 1
		elif block_id == stone_id:
			stone_blocks += 1

	var vegetation: WorldVegetation = world.vegetation
	var reeds := vegetation.get_node_or_null("Reeds")
	var grass_node := vegetation.get_node_or_null("AshGrass")

	var spawn_height: int = heights[WorldGenerator.SPAWN_X + WorldGenerator.SPAWN_Z * width]
	var spawn_flat := true
	for z in range(WorldGenerator.SPAWN_Z - 4, WorldGenerator.SPAWN_Z + 5):
		for x in range(WorldGenerator.SPAWN_X - 4, WorldGenerator.SPAWN_X + 5):
			if heights[x + z * width] != spawn_height:
				spawn_flat = false

	print("ASHEN METRICS: hush_columns=%d canyon_columns=%d ashen_canyon=%d deep_columns=%d cliffs=%d gravel_blocks=%d stone_blocks=%d trees=%d tufts=%d mean_height=%.1f" % [biome_hush, canyon_columns, ashen_canyon, deep_columns, cliff_columns, gravel_blocks, stone_blocks, vegetation.tree_count, vegetation.grass_count, float(height_total) / float(width * width)])

	_check(reeds == null, "tall reed MultiMesh is gone")
	_check(grass_node != null, "sparse ash tuft layer still exists")
	_check(vegetation.tree_count <= 40, "dead trees are landmarks rather than clutter", "trees=%d" % vegetation.tree_count)
	_check(vegetation.grass_count <= 220, "ground cover is sparse", "tufts=%d" % vegetation.grass_count)
	_check(biome_hush >= 1500, "Hushwoods biome is intact", "columns=%d" % biome_hush)
	_check(ashen_canyon >= 800, "Ashen Flats has broad canyon floors", "columns=%d" % ashen_canyon)
	_check(deep_columns >= 400, "canyons cut deeply into the flats", "depth<=16 columns=%d" % deep_columns)
	_check(cliff_columns >= 90, "rocky cliff walls exist", "slope>=3 columns=%d" % cliff_columns)
	_check(gravel_blocks >= 700, "canyon floors expose gravel", "blocks=%d" % gravel_blocks)
	_check(spawn_flat, "spawn basin is still flat", "height=%d" % spawn_height)

	for spire in WorldGenerator.LANDMARK_SPIRES:
		var base_y: int = heights[spire.x + spire.y * width]
		var tallest := 0
		for offset_z in range(-2, 3):
			for offset_x in range(-2, 3):
				var cell_x: int = spire.x + offset_x
				var cell_z: int = spire.y + offset_z
				for y in range(base_y + 1, base_y + 13):
					if world.get_block_id(Vector3i(cell_x, y, cell_z)) == stone_id:
						tallest = maxi(tallest, y - base_y)
		_check(tallest >= 4, "landmark spire rises at %s" % str(spire), "height=%d" % tallest)

	var gravel_floor := 0
	for z in range(1, width - 1, 2):
		for x in range(1, width - 1, 2):
			var top: int = heights[x + z * width]
			if world.get_block_id(Vector3i(x, top, z)) == gravel_id:
				gravel_floor += 1
	_check(gravel_floor >= 150, "gravel is exposed across the canyon floors", "surface_cells=%d" % gravel_floor)

	if failures > 0:
		quit(1)
		return
	print("ASHEN FLATS CHECK PASS: canyon terrain, rock detail and sparse cover verified")
	quit(0)
