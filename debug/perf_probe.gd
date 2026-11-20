extends SceneTree

# Frame-time probe for the streaming world. Run WITH rendering (no --headless):
#   ./Godot_v4.7.2-stable_win64_console.exe --path . -s debug/perf_probe.gd
# It waits for the spawn backlog to settle, measures idle frames, then drags the
# player 320 blocks through fresh terrain so streaming and region rebuilds show
# up as spikes.

const WARMUP_FRAMES := 90
const IDLE_FRAMES := 300
const TRAVEL_DISTANCE := 320.0
const TRAVEL_SPEED := 8.0
const SETTLE_TIMEOUT := 4000
const SLOW_MS := 6.0

var main: Node
var world: VoxelWorld
var player: VoxelPlayer
var vegetation: WorldVegetation
var water: ToxicWater

var phase := "boot"
var frame_index := 0
var samples: Array[float] = []
var slow: Array[Dictionary] = []
var last_center := Vector2i(1 << 30, 1 << 30)
var travel_direction := Vector3(1.0, 0.0, 0.35).normalized()
var travel_start := Vector3.ZERO
var max_draw_calls := 0
var max_objects := 0
var done := false


func _initialize() -> void:
	Engine.max_fps = 0
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_ALWAYS_ON_TOP, true)
	DisplayServer.window_move_to_foreground()
	main = load("res://scenes/world/main.tscn").instantiate()
	root.add_child(main)
	main.process_mode = Node.PROCESS_MODE_ALWAYS
	world = main.get_node("VoxelWorld") as VoxelWorld
	player = main.get_node("Player") as VoxelPlayer
	player.set_physics_process(false)
	player.set_process(false)


func _process(delta: float) -> bool:
	if done:
		return true
	# main.gd pauses on focus loss; keep the probe running regardless.
	root.get_tree().paused = false
	frame_index += 1
	if not world.is_generated:
		return false
	if phase == "boot":
		# Grab decoration nodes only after the world's _ready has built them.
		vegetation = world.vegetation
		water = world.water
		phase = "settle"
		frame_index = 0
		DisplayServer.window_move_to_foreground()
		print("PROBE spawn ready at frame %d: loaded=%d lit=%d meshed=%d" % [world.generated_chunk_count, world.chunk_records.size(), world.initialized_light_chunks, world.meshed_chunk_count])
		return false
	if phase == "settle":
		var settled := world.generation_queue.is_empty() and world.light_queue.is_empty() and not world.has_active_light and world.mesh_queue.is_empty() and world.generation_results.is_empty() and world.mesh_results.is_empty()
		if not settled and frame_index < SETTLE_TIMEOUT:
			return false
		phase = "warmup"
		frame_index = 0
		print("PROBE settled at frame %d: loaded=%d lit=%d meshed=%d gen=%d light=%d mesh=%d cpus=%d" % [Engine.get_frames_drawn(), world.chunk_records.size(), world.initialized_light_chunks, world.meshed_chunk_count, world.generation_queue.size(), world.light_queue.size(), world.mesh_queue.size(), OS.get_processor_count()])
		return false
	if phase == "warmup":
		if frame_index >= WARMUP_FRAMES:
			phase = "idle"
			frame_index = 0
			samples.clear()
			slow.clear()
			max_draw_calls = 0
			max_objects = 0
		return false
	if phase == "idle":
		_sample(delta)
		if frame_index >= IDLE_FRAMES:
			_report("IDLE")
			phase = "travel"
			frame_index = 0
			samples.clear()
			slow.clear()
			max_draw_calls = 0
			max_objects = 0
			last_center = world.stream_center
			travel_start = player.position
		return false
	if phase == "travel":
		player.position += travel_direction * TRAVEL_SPEED * delta
		player.global_position = player.position
		_sample(delta)
		if player.position.distance_to(travel_start) >= TRAVEL_DISTANCE:
			_report("TRAVEL")
			done = true
			return true
	return false


func _sample(delta: float) -> void:
	var ms := delta * 1000.0
	samples.append(ms)
	max_draw_calls = maxi(max_draw_calls, int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	max_objects = maxi(max_objects, int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)))
	var chunk_changed := world.stream_center != last_center
	# Record every frame (not just >SLOW_MS) so the report is computed from the
	# same samples as the percentiles.
	if slow.size() < 8000:
		var veg_center := vegetation.region_center if is_instance_valid(vegetation) else Vector2i.ZERO
		var water_center := water.region_center if is_instance_valid(water) else Vector2i.ZERO
		slow.append({
			"ms": ms,
			"frame": frame_index,
			"loaded": world.chunk_records.size(),
			"gen_queue": world.generation_queue.size(),
			"light_queue": world.light_queue.size(),
			"mesh_queue": world.mesh_queue.size(),
			"chunk_changed": chunk_changed,
			"biome": BiomeManager.dominant_biome(floori(player.position.x), floori(player.position.z)),
			"x": player.position.x,
			"veg_center": veg_center,
			"water_center": water_center,
			"perf": world.perf_usec.duplicate(),
		})
	last_center = world.stream_center


func _report(label: String) -> void:
	var sorted_samples := samples.duplicate()
	sorted_samples.sort()
	var total := 0.0
	for value in samples:
		total += value
	var spikes: Array[Dictionary] = []
	var total_slow := 0.0
	for entry in slow:
		if float(entry["ms"]) > SLOW_MS:
			spikes.append(entry)
			total_slow += float(entry["ms"])
	spikes.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["ms"]) > float(b["ms"]))
	print("PROBE %s frames=%d avg=%.2fms p50=%.2f p95=%.2f p99=%.2f max=%.2f max_draw=%d max_objects=%d" % [
		label,
		samples.size(),
		total / maxf(float(samples.size()), 1.0),
		_percentile(sorted_samples, 0.50),
		_percentile(sorted_samples, 0.95),
		_percentile(sorted_samples, 0.99),
		_percentile(sorted_samples, 1.0),
		max_draw_calls,
		max_objects,
	])
	print("PROBE %s slow_frames=%d slow_time=%.0fms loaded=%d" % [label, spikes.size(), total_slow, world.chunk_records.size()])
	var shown := 0
	for entry in spikes:
		if shown >= 15:
			break
		var perf: Dictionary = entry["perf"]
		print("  slow %.1fms frame=%d x=%.0f loaded=%d gen=%d light=%d mesh=%d | stream=%d veg=%d gen=%d install=%d light=%d(pad=%d begin=%d) mesh=%d(commit=%d snap=%d src=%d)" % [
			entry["ms"], entry["frame"], entry["x"], entry["loaded"],
			entry["gen_queue"], entry["light_queue"], entry["mesh_queue"],
			perf["stream"], perf["vegetation"], perf["generation"], perf["install"],
			perf["light"], perf["light_pad"], perf["light_begin"],
			perf["mesh"], perf["commit"], perf["snapshot"], perf["sources"],
		])
		shown += 1


func _percentile(sorted_values: Array[float], fraction: float) -> float:
	if sorted_values.is_empty():
		return 0.0
	var index := clampi(roundi(fraction * float(sorted_values.size() - 1)), 0, sorted_values.size() - 1)
	return sorted_values[index]
