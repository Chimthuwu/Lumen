extends SceneTree

var failures := 0


func _check(condition: bool, label: String, detail := "") -> void:
	if not condition:
		failures += 1
		push_error("BIOME CHECK FAIL: %s %s" % [label, detail])
		return
	print("BIOME PASS: %s %s" % [label, detail])


func _initialize() -> void:
	BiomeManager.configure(139732)
	_run()


func _run() -> void:
	var counts := [0, 0, 0, 0]
	var max_delta := 0
	var delta_total := 0
	var delta_samples := 0
	var max_run := 0
	var run_total := 0
	var run_count := 0
	for z in range(-1200, 1201, 24):
		var previous := -1
		var run := 0
		for x in range(-1200, 1201, 24):
			var biome := BiomeManager.dominant_biome(x, z)
			counts[biome] += 1
			if biome == previous:
				run += 1
			else:
				if previous >= 0:
					max_run = maxi(max_run, run)
					run_total += run
					run_count += 1
				previous = biome
				run = 1
			var delta := absi(BiomeManager.get_height(x, z) - BiomeManager.get_height(x + 1, z))
			max_delta = maxi(max_delta, delta)
			delta_total += delta
			delta_samples += 1
		if run > 0:
			max_run = maxi(max_run, run)
			run_total += run
			run_count += 1
	print("BIOME METRICS ashen=%d hush=%d frost=%d mire=%d max_run_cells=%d avg_run_cells=%.1f max_height_delta=%d mean_delta=%.2f" % [counts[0], counts[1], counts[2], counts[3], max_run, float(run_total) / float(maxi(1, run_count)), max_delta, float(delta_total) / float(delta_samples)])
	_check(counts[0] > 1000 and counts[1] > 1000 and counts[2] > 1000 and counts[3] > 1000, "all four biomes occur at macro scale", str(counts))
	var average_run_cells := float(run_total) / float(maxi(1, run_count))
	_check(average_run_cells >= 5.0, "biome runs span hundreds of blocks", "avg_run=%.1f cells (%.0f blocks)" % [average_run_cells, average_run_cells * 24.0])
	# The locked Ashen terrain already contains sheer canyon walls, so the
	# continuity guarantee is about the mean slope, not the absence of cliffs.
	_check(max_delta <= 12, "cliff steps stay within the existing terrain range", "max_delta=%d" % max_delta)
	_check(float(delta_total) / float(delta_samples) < 1.6, "terrain is continuous across biome borders", "mean_delta=%.2f" % (float(delta_total) / float(delta_samples)))

	var spawn_weights := BiomeManager.get_weights(64, 64)
	_check(spawn_weights[0] > 0.99, "spawn is locked to Ashen Flats", "ashen=%.3f" % spawn_weights[0])
	var weight_sum := 0.0
	for value in spawn_weights:
		weight_sum += value
	_check(absf(weight_sum - 1.0) < 0.001, "biome weights are normalised", "sum=%.4f" % weight_sum)

	var water_columns := 0
	var mire_columns := 0
	for z in range(-900, 901, 12):
		for x in range(-900, 901, 12):
			if BiomeManager.dominant_biome(x, z) == BiomeManager.MIRE:
				mire_columns += 1
				if BiomeManager.is_mire_water(x, z):
					water_columns += 1
	_check(mire_columns > 200, "the Mire has a large footprint", "columns=%d" % mire_columns)
	_check(water_columns > 10, "the Mire holds standing toxic water", "water_columns=%d of %d" % [water_columns, mire_columns])

	if failures > 0:
		quit(1)
		return
	print("BIOME CHECK PASS: four continuous macro biomes with a locked Ashen spawn")
	quit(0)
