extends SceneTree

# Gameplay-side integration check: biome spawn tables, new enemy variants,
# buggy chunk-readiness governor, HUD biome indicator, and save policy.

var main: Node
var failures := 0


func _check(condition: bool, label: String, detail := "") -> void:
	if not condition:
		failures += 1
		push_error("GAMEPLAY CHECK FAIL: %s %s" % [label, detail])
		return
	print("GAMEPLAY PASS: %s %s" % [label, detail])


func _initialize() -> void:
	main = load("res://scenes/world/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _wait_frames(count: int) -> void:
	for _i in range(count):
		await process_frame


func _run() -> void:
	var world: VoxelWorld = main.world
	var frames := 0
	while not world.is_generated and frames < 1800:
		await process_frame
		frames += 1
	_check(world.is_generated, "world ready", "frames=%d" % frames)
	if not world.is_generated:
		quit(1)
		return

	# --- Biome spawn tables (pure config) ---
	var config: EnemyConfig = preload("res://data/world/enemy_config.tres")
	var allowed := [
		[EnemyConfig.KIND_GLOOMLING, EnemyConfig.KIND_LAMP_EATER],
		[EnemyConfig.KIND_GLOOMLING, EnemyConfig.KIND_HOLLOW],
		[EnemyConfig.KIND_GLOOMLING, EnemyConfig.KIND_FROST_STALKER],
		[EnemyConfig.KIND_LAMP_EATER, EnemyConfig.KIND_BOG_CRAWLER],
	]
	for biome in range(4):
		var rolled := {}
		for step in range(100):
			rolled[config.roll_kind(biome, float(step) / 100.0)] = true
		var only_table := true
		for key in rolled.keys():
			if not allowed[biome].has(key):
				only_table = false
		_check(only_table and rolled.size() == allowed[biome].size(), "biome %d rolls exactly its table" % biome, str(rolled.keys()))

	# --- Enemy variants ---
	var director: EnemyDirector = main.enemy_director
	var stalker: GloomEnemy = director._make_enemy(EnemyConfig.KIND_FROST_STALKER)
	main.add_child(stalker)
	_check(stalker is Gloomling, "Frost Stalker reuses Gloomling logic")
	_check(is_equal_approx(stalker.move_speed, config.frost_stalker_speed) and stalker.move_speed > config.gloomling_speed, "Frost Stalker is faster", "speed=%.1f" % stalker.move_speed)
	var icy := false
	for child in stalker.visual_root.get_children():
		var material := child.material_override as StandardMaterial3D
		if material != null and material.emission_energy_multiplier >= 6.0 and material.emission.b > material.emission.r:
			icy = true
	_check(icy, "Frost Stalker glow parts are blue-tinted")
	stalker.queue_free()

	var crawler: GloomEnemy = director._make_enemy(EnemyConfig.KIND_BOG_CRAWLER)
	main.add_child(crawler)
	_check(crawler is LampEater, "Bog Crawler reuses Lamp Eater logic")
	_check(crawler.body_half_extents.y < 0.35, "Bog Crawler is low-slung (crawls)", "half_y=%.2f" % crawler.body_half_extents.y)
	crawler.queue_free()
	await _wait_frames(3)

	# --- Buggy governor ---
	var buggy: DuneBuggy = main.buggy
	await _wait_frames(2)
	if not buggy.parked_ready:
		_check(false, "buggy parked before governor test")
		quit(1)
		return
	var saved_position := buggy.position
	buggy.position = Vector3(64.5, float(world.spawn_height() + 1), 64.5)
	buggy.velocity = Vector3.ZERO
	buggy._update_stream_governor()
	_check(not buggy.stream_frozen and buggy.governor_speed_cap > 0.0, "governor allows driving over ready terrain", "cap=%.1f" % buggy.governor_speed_cap)
	_check(world._focus_is_fresh(), "governor published a generation focus")
	buggy.position = Vector3(9000.5, 40.0, 9000.5)
	buggy._update_stream_governor()
	_check(buggy.stream_frozen and buggy.governor_speed_cap == 0.0, "governor hard-freezes over missing chunks")
	buggy.position = saved_position
	buggy.velocity = Vector3.ZERO
	buggy.stream_frozen = false

	# --- HUD biome indicator ---
	var hud: GameHUD = main.get_node("HUD")
	await _wait_frames(2)
	hud._update_biome(0.016)
	_check(hud.last_biome >= 0 and hud.biome_label.text != "", "HUD shows the persistent biome tag", hud.biome_label.text)
	_check(not hud.biome_intro_label.visible, "no crossing banner on first read")
	var player_home: Vector3 = main.player.position
	var home_biome := world.get_biome_at(Vector3i(floori(player_home.x), 0, floori(player_home.z)))
	var found := false
	var away := Vector3.ZERO
	for step in range(1, 60):
		for eighths in range(8):
			var angle := TAU * float(eighths) / 8.0
			var x := floori(player_home.x + cos(angle) * float(step) * 40.0)
			var z := floori(player_home.z + sin(angle) * float(step) * 40.0)
			if world.get_biome_at(Vector3i(x, 0, z)) != home_biome:
				away = Vector3(float(x) + 0.5, 40.0, float(z) + 0.5)
				found = true
				break
		if found:
			break
	_check(found, "a neighbouring biome column exists for the crossing test")
	main.player.position = away
	hud._update_biome(0.016)
	_check(hud.biome_intro_label.visible and hud.biome_intro_label.text.begins_with("ENTERING:"), "crossing shows ENTERING banner", hud.biome_intro_label.text)
	main.player.position = player_home
	hud.last_biome = world.get_biome_at(Vector3i(floori(player_home.x), 0, floori(player_home.z)))
	hud.biome_intro_time = 0.0

	# --- Save policy ---
	_check(WorldSave.SAVE_VERSION == 3 and WorldSave.FORMAT_CHANGED_MESSAGE == "World format changed — starting fresh", "save format v3 with the approved rejection message")
	var legacy_dir := "user://worlds/991"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(legacy_dir))
	var legacy := FileAccess.open(legacy_dir.path_join("metadata.json"), FileAccess.WRITE)
	legacy.store_string(JSON.stringify({"save_version": 1, "seed": 991}))
	legacy.close()
	_check(WorldSave.load_world(991, world).is_empty(), "v1 saves are rejected outright")
	DirAccess.remove_absolute(ProjectSettings.globalize_path(legacy_dir))

	if failures > 0:
		quit(1)
		return
	print("GAMEPLAY INTEGRATION CHECK PASS: biomes, enemies, governor, HUD and saves integrated")
	quit(0)
