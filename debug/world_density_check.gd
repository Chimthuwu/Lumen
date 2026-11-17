extends SceneTree

# Density audit for the redesigned Ashen Flats: rock detail is present, while
# grass, reeds and shrub props stay out of the barren canyon palette.

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
		push_error("DENSITY CHECK FAIL: %s %s" % [label, detail])
		return
	print("DENSITY PASS: %s %s" % [label, detail])


func _run() -> void:
	while not main.world.is_generated:
		await process_frame
	var world: VoxelWorld = main.world
	var stone_id: int = world.block_ids[&"stone"]
	var bloom_id: int = world.block_ids[&"pale_bloom"]
	var mycelium_id: int = world.block_ids[&"mycelium"]
	var wood_id: int = world.block_ids[&"dead_wood"]

	var stone_props := 0
	var shrubs := 0
	var log_cells := 0
	for z in range(1, SAMPLE - 1):
		for x in range(1, SAMPLE - 1):
			var top: int = world.get_surface_height(x, z) + 1
			var block_id: int = world.get_block_id(Vector3i(x, top, z))
			if block_id == stone_id:
				stone_props += 1
			elif block_id == bloom_id or block_id == mycelium_id:
				shrubs += 1
			elif block_id == wood_id:
				var sideways := world.get_block_id(Vector3i(x + 1, top, z)) == wood_id or world.get_block_id(Vector3i(x, top, z + 1)) == wood_id
				if sideways:
					log_cells += 1

	_check(stone_props >= 40, "boulders and ruin stone sit above the ground", "cells=%d" % stone_props)
	_check(shrubs <= 8, "shrub props no longer crowd the flats", "cells=%d" % shrubs)
	_check(log_cells <= 4, "fallen logs no longer litter the flats", "cells=%d" % log_cells)
	_check(world.vegetation.get_node_or_null("Reeds") == null, "reed MultiMesh was removed")

	# Props are stamped from a seeded grid, so a chunk must rebuild byte-identically.
	var first := WorldGenerator.generate_chunk(Vector3i(0, 0, 0), 139732, world.block_ids)
	var second := WorldGenerator.generate_chunk(Vector3i(0, 0, 0), 139732, world.block_ids)
	_check(first == second, "prop stamping is deterministic", "bytes=%d" % first.size())

	if failures > 0:
		quit(1)
		return
	print("WORLD DENSITY CHECK PASS: rock detail present, vegetation sparse and deterministic")
	quit(0)
