extends GloomEnemy
class_name Gloomling

var visual_root: Node3D
var bob_time := 0.0


func _should_dissolve(cell: Vector3i) -> bool:
	return world.get_light_level(cell) >= dissolve_light_level or world.get_flashlight_level_at(position + Vector3.UP * 0.5) >= 0.65


func _process(delta: float) -> void:
	bob_time += delta
	if visual_root != null:
		visual_root.position.y = sin(bob_time * 4.2) * 0.07
	super._process(delta)


func _create_placeholder_mesh() -> void:
	visual_root = Node3D.new()
	visual_root.name = "Visual"
	add_child(visual_root)
	var flesh := _make_limb_material(Color(0.045, 0.035, 0.055), Color(0.10, 0.02, 0.16), 0.9)
	var bone := _make_limb_material(Color(0.11, 0.095, 0.10), Color(0.05, 0.01, 0.07), 0.4)
	var glow := _make_limb_material(Color(1.0, 0.12, 0.18), Color(1.0, 0.06, 0.12), 6.0)

	_add_limb_box("Torso", Vector3(0.27, 0.42, 0.21), Vector3(0, 0.62, 0), Vector3(0.14, 0, 0), flesh)
	_add_limb_box("Chest", Vector3(0.21, 0.18, 0.16), Vector3(0, 0.74, -0.09), Vector3(0.28, 0, 0), bone)
	_add_limb_box("Neck", Vector3(0.075, 0.15, 0.075), Vector3(0, 0.88, -0.01), Vector3(0.18, 0, 0), flesh)
	_add_limb_box("Head", Vector3(0.235, 0.20, 0.235), Vector3(0, 1.00, -0.035), Vector3(0.18, 0, 0), flesh)
	_add_limb_box("Jaw", Vector3(0.17, 0.055, 0.13), Vector3(0, 0.90, -0.11), Vector3(0.30, 0, 0), bone)
	for tooth in range(3):
		_add_limb_box("Tooth%d" % tooth, Vector3(0.020, 0.036, 0.012), Vector3(-0.045 + tooth * 0.045, 0.925, -0.175), Vector3(0.25, 0, 0), glow)
	for eye_offset in [Vector3(-0.070, 1.015, -0.145), Vector3(0.070, 1.015, -0.145)]:
		_add_limb_box("Eye", Vector3(0.052, 0.032, 0.020), eye_offset, Vector3.ZERO, glow)

	# Four long, broken-looking arms with a second elbow segment.
	for side in [-1.0, 1.0]:
		for arm in range(2):
			var shoulder := Vector3(side * (0.16 + arm * 0.015), 0.80 - arm * 0.05, 0.01 + arm * 0.045)
			_add_limb_box("UpperArm", Vector3(0.042, 0.32, 0.042), shoulder + Vector3(side * 0.045, -0.15, 0.0), Vector3(0.18, 0, side * 0.24), flesh)
			var elbow := shoulder + Vector3(side * 0.12, -0.31, -0.03)
			_add_limb_box("Forearm", Vector3(0.032, 0.30, 0.032), elbow + Vector3(0, -0.14, -0.05), Vector3(-0.28, 0, side * 0.10), bone)
			_add_limb_box("Claw", Vector3(0.022, 0.09, 0.022), elbow + Vector3(0, -0.30, -0.10), Vector3(-0.45, 0, 0), glow)

	# Four spindly legs, knees bent outwards.
	for side in [-1.0, 1.0]:
		for leg in range(2):
			var hip := Vector3(side * (0.10 + leg * 0.02), 0.46, 0.02 + leg * 0.06)
			_add_limb_box("Thigh", Vector3(0.050, 0.34, 0.050), hip + Vector3(side * 0.055, -0.15, 0), Vector3(0.10, 0, side * 0.28), flesh)
			_add_limb_box("Shin", Vector3(0.038, 0.30, 0.038), hip + Vector3(side * 0.12, -0.42, -0.03), Vector3(-0.12, 0, side * 0.08), bone)
			_add_limb_box("Foot", Vector3(0.055, 0.035, 0.13), hip + Vector3(side * 0.13, -0.58, -0.08), Vector3.ZERO, bone)


func _make_limb_material(color: Color, emission: Color, energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = emission
	material.emission_energy_multiplier = energy
	return material


func _add_limb_box(node_name: String, size: Vector3, offset: Vector3, box_rotation: Vector3, material: Material) -> void:
	var box := BoxMesh.new()
	box.size = size
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = box
	instance.material_override = material
	instance.position = offset
	instance.rotation = box_rotation
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visual_root.add_child(instance)


func _on_dissolve() -> void:
	Vfx.burst(get_parent() as Node3D, global_position + Vector3.UP * 0.2, Color(0.07, 0.03, 0.10), Vector3.UP, 18, 1.8, 0.11, 0.75, 0.25)
