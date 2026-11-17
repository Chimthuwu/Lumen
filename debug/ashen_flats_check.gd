extends SceneTree

# Headless audit of the Ashen Flats redesign against the streaming engine:
# canyon depth/coverage, gravel floors, rock cliffs, landmark spires, sparse
# vegetation and the locked Ashen spawn basin.

const SAMPLE := 128

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
	var canyon_columns := 0
	var ashen_canyon := 0
	var deep_columns := 0
	var cliff_columns := 0
	var height_total := 0
	var ashen_columns := 0
	for z in range(SAMPLE):
		for x in range(SAMPLE):
			var here: int = world.get_surface_height(x, z)
			height_total += here
			if world.get_biome_at(Vector3i(x, 0, z)) == BiomeManager.ASHEN:
				ashen_columns += 1
			if world.is_canyon_floor(x, z):
				canyon_columns += 1
				if here <= 16:
					deep_columns += 1
			var slope := absi(here - world.get_surface_height(x + 1, z))
			slope = maxi(slope, absi(here - world.get_surface_height(x, z + 1)))
			if slope >= 3:
				cliff_columns += 1

	var gravel_id: int = world.block_ids[&"canyon_gravel"]
	var stone_id: int = world.block_ids[&"stone"]
	var gravel_blocks := 0
	var stone_blocks := 0
	for key in world.chunk_records.keys():
		var record: Dictionary = world.chunk_records[key]
		for block_id in record["blocks"]:
			if int(block_id) == gravel_id:
				gravel_blocks += 1
			elif int(block_id) == stone_id:
				stone_blocks += 1

	var vegetation: WorldVegetation = world.vegetation
	var spawn_height: int = world.get_surface_height(WorldGenerator.SPAWN_X, WorldGenerator.SPAWN_Z)
	var spawn_flat := true
	for z in range(WorldGenerator.SPAWN_Z - 4, WorldGenerator.SPAWN_Z + 5):
		for x in range(WorldGenerator.SPAWN_X - 4, WorldGenerator.SPAWN_X + 5):
			if Vector2(float(x - WorldGenerator.SPAWN_X), float(z - WorldGenerator.SPAWN_Z)).length() <= WorldGenerator.SPAWN_CLEAR_RADIUS:
				if world.get_surface_height(x, z) != spawn_height:
					spawn_flat = false

	print("ASHEN METRICS: ashen_columns=%d canyon_columns=%d deep_columns=%d cliffs=%d gravel_blocks=%d stone_blocks=%d trees=%d tufts=%d mean_height=%.1f" % [ashen_columns, canyon_columns, deep_columns, cliff_columns, gravel_blocks, stone_blocks, vegetation.tree_count, vegetation.grass_count, float(height_total) / float(SAMPLE * SAMPLE)])

	_check(vegetation.get_node_or_null("Reeds") == null, "tall reed MultiMesh is gone")
	_check(vegetation.get_node_or_null("AshGrass") != null, "sparse ash tuft layer still exists")
	_check(vegetation.tree_count <= 80, "dead trees are landmarks rather than clutter", "trees=%d" % vegetation.tree_count)
	_check(vegetation.grass_count <= 700, "ground cover is sparse", "tufts=%d" % vegetation.grass_count)
	_check(ashen_columns == SAMPLE * SAMPLE, "spawn region is locked to Ashen Flats", "columns=%d" % ashen_columns)
	_check(canyon_columns >= 800, "Ashen Flats has broad canyon floors", "columns=%d" % canyon_columns)
	_check(deep_columns >= 400, "canyons cut deeply into the flats", "depth<=16 columns=%d" % deep_columns)
	_check(cliff_columns >= 90, "rocky cliff walls exist", "slope>=3 columns=%d" % cliff_columns)
	_check(gravel_blocks >= 700, "canyon floors expose gravel", "blocks=%d" % gravel_blocks)
	_check(spawn_flat, "spawn basin is still flat", "height=%d" % spawn_height)
	_check(not world.is_canyon_floor(WorldGenerator.SPAWN_X, WorldGenerator.SPAWN_Z), "spawn is not inside a canyon cut")

	for spire in WorldGenerator.LANDMARK_SPIRES:
		var base_y: int = world.get_surface_height(spire.x, spire.y)
		var tallest := 0
		for offset_z in range(-2, 3):
			for offset_x in range(-2, 3):
				var cell_x: int = spire.x + offset_x
				var cell_z: int = spire.y + offset_z
				for y in range(base_y + 1, base_y + 13):
					if world.get_block_id(Vector3i(cell_x, y, cell_z)) == stone_id:
						tallest = maxi(tallest, y - base_y)
		_check(tallest >= 4, "landmark spire rises at %s" % str(spire), "height=%d" % tallest)

	# Flood fill the heightfield the way the player moves: four neighbours, no
	# step taller than one block. The canyon must be enterable, not a diorama.
	var reachable := PackedByteArray()
	reachable.resize(SAMPLE * SAMPLE)
	reachable.fill(0)
	var queue := PackedInt32Array([WorldGenerator.SPAWN_X + WorldGenerator.SPAWN_Z * SAMPLE])
	reachable[queue[0]] = 1
	var head := 0
	var reachable_canyon := 0
	while head < queue.size():
		var cell_index := queue[head]
		head += 1
		var cell_x := cell_index % SAMPLE
		var cell_z := int(cell_index / SAMPLE)
		if world.is_canyon_floor(cell_x, cell_z):
			reachable_canyon += 1
		for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var next_x: int = cell_x + offset.x
			var next_z: int = cell_z + offset.y
			if next_x < 0 or next_x >= SAMPLE or next_z < 0 or next_z >= SAMPLE:
				continue
			var next_index := next_x + next_z * SAMPLE
			if reachable[next_index] == 1:
				continue
			if absi(world.get_surface_height(next_x, next_z) - world.get_surface_height(cell_x, cell_z)) > 1:
				continue
			reachable[next_index] = 1
			queue.append(next_index)

	var gravel_floor := 0
	for z in range(1, SAMPLE - 1, 2):
		for x in range(1, SAMPLE - 1, 2):
			var top: int = world.get_surface_height(x, z)
			if world.get_block_id(Vector3i(x, top, z)) == gravel_id:
				gravel_floor += 1
	_check(gravel_floor >= 150, "gravel is exposed across the canyon floors", "surface_cells=%d" % gravel_floor)
	_check(reachable_canyon >= 200, "canyon floors are reachable on foot from spawn", "reachable_floor_columns=%d of %d" % [reachable_canyon, canyon_columns])

	if failures > 0:
		quit(1)
		return
	print("ASHEN FLATS CHECK PASS: canyon terrain, rock detail and sparse cover verified")
	quit(0)
