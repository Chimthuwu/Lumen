extends Node3D

const SaveSystem = preload("res://scripts/save/save_manager.gd")

@onready var world = $VoxelWorld
@onready var player = $Player
@onready var debug_label: Label = $HUD/DebugReadout

var debug_visible := true
var pause_due_to_focus := false


func _ready() -> void:
	world.process_mode = Node.PROCESS_MODE_PAUSABLE
	player.process_mode = Node.PROCESS_MODE_PAUSABLE
	$HUD.process_mode = Node.PROCESS_MODE_ALWAYS
	debug_label.visible = true


func _process(_delta: float) -> void:
	if Input.is_action_just_pressed("toggle_debug"):
		debug_visible = not debug_visible
		debug_label.visible = debug_visible
	if Input.is_action_just_pressed("save_world") and world.is_generated:
		SaveSystem.save_world(world, player.position)
	if Input.is_action_just_pressed("load_world") and world.is_generated:
		var save_data := SaveSystem.load_world(world.world_seed, world.BLOCK_VOLUME)
		if not save_data.is_empty() and world.restore_save(save_data):
			var saved_position: Array = save_data["metadata"].get("player_position", [])
			if saved_position.size() == 3:
				player.position = Vector3(saved_position[0], saved_position[1], saved_position[2])
	debug_label.text = _debug_text()


func _debug_text() -> String:
	var draw_calls := int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME))
	var generated: int = world.generated_chunk_count
	var meshed: int = world.meshed_chunk_count
	var block_total: int = world.blocks.size() if world.is_generated else 0
	var light_cell := Vector3i(floori(player.camera.global_position.x), floori(player.camera.global_position.y), floori(player.camera.global_position.z))
	var hit: Dictionary = player._voxel_raycast(7.0)
	if not hit.is_empty():
		light_cell = hit["previous_air"]
	var light_level: int = world.get_light_level(light_cell) if world.is_generated else 0
	return "LUMENFALL M2 | FPS %d | Draw calls %d | LIGHT_LEVEL %d\nChunks %d/256 generated, %d/256 meshed, %d/256 lit | blocks %d\nStatic lights %d | flashlight dynamic in shader | WASD move | Shift sprint | Space jump | LMB break | RMB place | K save | J load | F HUD" % [Engine.get_frames_per_second(), draw_calls, light_level, generated, meshed, world.initialized_light_chunks, block_total, world.static_light_sources.size()]

func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		pause_due_to_focus = true
		get_tree().paused = true
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN and pause_due_to_focus:
		pause_due_to_focus = false
		get_tree().paused = false
