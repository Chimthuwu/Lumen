extends GloomEnemy
class_name LampEater

var target_light_cell := Vector3i(-1, -1, -1)
var retarget_timer := 0.0
var extinguish_distance := 1.25
var extinguish_seconds := 12.0
var target_radius := 24.0
var target_blocks: Array[StringName] = [&"torch"]

func _update_behavior(delta: float) -> void:
	retarget_timer -= delta
	if retarget_timer <= 0.0:
		retarget_timer = 1.0
		_find_target_light()
	if target_light_cell.x >= 0:
		var target := Vector3(target_light_cell) + Vector3.ONE * 0.5
		var toward := target - position
		if toward.length() <= extinguish_distance:
			if attack_cooldown <= 0.0 and world.extinguish_light_source(target_light_cell, extinguish_seconds):
				attack_cooldown = 2.0
				target_light_cell = Vector3i(-1, -1, -1)
				wish_direction = Vector3.ZERO
				return
			target_light_cell = Vector3i(-1, -1, -1)
			wish_direction = Vector3.ZERO
			return
		if toward.length_squared() > 0.01:
			wish_direction = toward.normalized()
			look_at(Vector3(target.x, position.y, target.z), Vector3.UP)
		return
	super._update_behavior(delta)

func _create_placeholder_mesh() -> void:
	var bone := _make_material(Color(0.085, 0.078, 0.075), Color(0.06, 0.035, 0.02), 0.35)
	var flesh := _make_material(Color(0.035, 0.030, 0.032), Color(0.09, 0.04, 0.02), 0.5)
	var lamp_metal := _make_material(Color(0.10, 0.09, 0.075), Color(0.15, 0.09, 0.03), 0.3)
	var lamp_glow := _make_material(Color(1.0, 0.70, 0.26), Color(1.0, 0.58, 0.16), 5.5)

	# Hunched ribcage over a thin spine.
	_add_part("Spine", Vector3(0.055, 0.62, 0.055), Vector3(0, 0.58, 0.10), Vector3(0.10, 0, 0), bone)
	_add_part("RibCore", Vector3(0.20, 0.30, 0.14), Vector3(0, 0.50, 0.03), Vector3(0.12, 0, 0), flesh)
	for rib in range(4):
		var rib_y := 0.34 + rib * 0.115
		var rib_width := 0.25 + rib * 0.045
		_add_part("RibFront%d" % rib, Vector3(rib_width, 0.030, 0.035), Vector3(0, rib_y, -0.105), Vector3(0, 0, 0.06), bone)
		for side in [-1.0, 1.0]:
			_add_part("RibSide%d" % rib, Vector3(0.030, 0.115, 0.035), Vector3(side * (0.11 + rib * 0.022), rib_y - 0.035, -0.04), Vector3(0, 0, side * -0.30), bone)
			_add_part("RibBack%d" % rib, Vector3(0.115, 0.026, 0.030), Vector3(side * 0.11, rib_y - 0.075, 0.045), Vector3(0, side * 0.35, 0), bone)

	# Long neck and narrow skull.
	_add_part("Neck", Vector3(0.060, 0.24, 0.060), Vector3(0, 0.86, -0.015), Vector3(0.22, 0, 0), bone)
	_add_part("Skull", Vector3(0.195, 0.16, 0.26), Vector3(0, 1.00, -0.065), Vector3(0.18, 0, 0), bone)
	_add_part("Muzzle", Vector3(0.13, 0.075, 0.12), Vector3(0, 0.955, -0.19), Vector3(0.24, 0, 0), flesh)
	for eye_offset in [Vector3(-0.062, 1.015, -0.155), Vector3(0.062, 1.015, -0.155)]:
		_add_part("Eye", Vector3(0.038, 0.024, 0.018), eye_offset, Vector3.ZERO, lamp_glow)

	# Ribcage arms and stilt legs.
	for side in [-1.0, 1.0]:
		_add_part("UpperArm", Vector3(0.040, 0.36, 0.040), Vector3(side * 0.17, 0.58, -0.01), Vector3(0.15, 0, side * 0.18), bone)
		_add_part("Forearm", Vector3(0.032, 0.34, 0.032), Vector3(side * 0.245, 0.31, -0.075), Vector3(-0.42, 0, side * 0.08), bone)
		_add_part("Thigh", Vector3(0.048, 0.34, 0.048), Vector3(side * 0.085, 0.27, 0.04), Vector3(0, 0, side * 0.18), flesh)
		_add_part("Shin", Vector3(0.036, 0.32, 0.036), Vector3(side * 0.105, 0.01, 0.02), Vector3(0, 0, side * 0.04), bone)
		_add_part("Foot", Vector3(0.060, 0.032, 0.15), Vector3(side * 0.11, -0.075, -0.045), Vector3.ZERO, bone)

	# The lantern it feeds: chain, cage and a hot core.
	_add_part("LanternChain", Vector3(0.018, 0.20, 0.018), Vector3(0, 0.50, -0.19), Vector3(0.10, 0, 0), lamp_metal)
	_add_part("LanternTop", Vector3(0.155, 0.035, 0.155), Vector3(0, 0.40, -0.215), Vector3.ZERO, lamp_metal)
	_add_part("LanternCore", Vector3(0.105, 0.145, 0.105), Vector3(0, 0.325, -0.215), Vector3.ZERO, lamp_glow)
	for bar in range(4):
		var angle := TAU * float(bar) / 4.0
		_add_part("LanternBar%d" % bar, Vector3(0.018, 0.16, 0.018), Vector3(cos(angle) * 0.065, 0.325, -0.215 + sin(angle) * 0.065), Vector3.ZERO, lamp_metal)
	_add_part("LanternBase", Vector3(0.14, 0.035, 0.14), Vector3(0, 0.245, -0.215), Vector3.ZERO, lamp_metal)



func _make_material(color: Color, emission: Color, energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = emission
	material.emission_energy_multiplier = energy
	return material


func _add_part(node_name: String, size: Vector3, offset: Vector3, box_rotation: Vector3, material: Material) -> void:
	var box := BoxMesh.new()
	box.size = size
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = box
	instance.material_override = material
	instance.position = offset
	instance.rotation = box_rotation
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)


func _find_target_light() -> void:
	var nearest_distance := INF
	target_light_cell = Vector3i(-1, -1, -1)
	for source in world.static_light_sources:
		var cell: Vector3i = source["cell"]
		if world.extinguished_sources.has(cell):
			continue
		var distance := position.distance_squared_to(Vector3(cell) + Vector3.ONE * 0.5)
		if distance >= nearest_distance or distance > target_radius * target_radius:
			continue
		var block_id := world.get_block_id(cell)
		if block_id <= 0 or block_id >= world.block_defs.size():
			continue
		if not target_blocks.has(world.block_defs[block_id].block_id):
			continue
		nearest_distance = distance
		target_light_cell = cell