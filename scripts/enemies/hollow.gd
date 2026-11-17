extends GloomEnemy
class_name Hollow

# The Hollow is a Weeping Angel: it advances only while the player is not
# looking at it. "Looking" means the crosshair is on its body OR the flashlight
# cone is on it, in both cases with a clear voxel line of sight.
const OBSERVE_ANGLE_DEGREES := 3.5
const OBSERVE_RANGE := 32.0
const FLASHLIGHT_OBSERVE_LEVEL := 0.05
const UNOBSERVE_DELAY := 0.20
const SIGHT_STEP := 0.22
const BODY_SAMPLE_HEIGHTS := [1.15, 1.75, 2.30]

const BONE_COLOR := Color(0.52, 0.51, 0.46)
const BONE_DARK := Color(0.31, 0.30, 0.27)
const HOLLOW_DARK := Color(0.055, 0.055, 0.05)
const STATUE_COLOR := Color(0.30, 0.31, 0.29)

var visual_root: Node3D
var observed := false
var unobserve_timer := 0.0
var statue_active := false
var materials: Array[StandardMaterial3D] = []


func _init() -> void:
	max_health = 120.0
	touch_damage = 50.0
	attack_range = 1.8
	attack_interval = 2.0
	move_speed = 1.6
	body_half_extents = Vector3(0.42, 1.35, 0.35)
	dissolve_light_level = 16


func _process(delta: float) -> void:
	if not is_instance_valid(player) or not player.spawned or not world.is_generated:
		return
	observed = is_observed()
	if observed:
		frozen = true
		unobserve_timer = 0.0
	else:
		unobserve_timer += delta
		if unobserve_timer >= UNOBSERVE_DELAY:
			frozen = false
	_update_statue(observed)
	super._process(delta)


func is_observed() -> bool:
	if not is_instance_valid(player) or not world.is_generated:
		return false
	# While driving, the active view is the buggy's chase camera.
	var camera: Camera3D = world.player_camera
	if not is_instance_valid(camera):
		camera = player.camera
	if camera == null:
		return false
	var from := camera.global_position
	var forward := (-camera.global_basis.z).normalized()
	for height in BODY_SAMPLE_HEIGHTS:
		var sample := global_position + Vector3.UP * float(height)
		var offset := sample - from
		var distance := offset.length()
		if distance < 0.25 or distance > OBSERVE_RANGE:
			continue
		var direction := offset / distance
		var angle := acos(clampf(direction.dot(forward), -1.0, 1.0))
		var crosshair_on_body := angle <= deg_to_rad(OBSERVE_ANGLE_DEGREES)
		var in_flashlight := world.get_flashlight_level_at(sample) >= FLASHLIGHT_OBSERVE_LEVEL
		if (crosshair_on_body or in_flashlight) and _has_line_of_sight(from, sample):
			return true
	return false


func _has_line_of_sight(from: Vector3, to: Vector3) -> bool:
	var offset := to - from
	var distance := offset.length()
	if distance < 0.001:
		return true
	var steps := ceili(distance / SIGHT_STEP)
	for step in range(1, steps):
		var point := from + offset * (float(step) / float(steps))
		var cell := Vector3i(floori(point.x), floori(point.y), floori(point.z))
		if not world._inside_world(cell):
			continue
		var block_id := world.get_block_id(cell)
		if block_id != world.air_id and not world.fixture_ids.has(block_id):
			return false
	return true


func _should_dissolve(cell: Vector3i) -> bool:
	return false


func _update_statue(active: bool) -> void:
	if statue_active == active:
		return
	statue_active = active
	for material in materials:
		if active:
			material.albedo_color = STATUE_COLOR
			material.emission = Color(0.16, 0.17, 0.16)
			material.emission_energy_multiplier = 0.12
		else:
			material.albedo_color = material.get_meta("base_albedo", BONE_COLOR)
			material.emission = material.get_meta("base_emission", Color(0.20, 0.20, 0.18))
			material.emission_energy_multiplier = float(material.get_meta("base_energy", 0.35))


func _make_part_material(color: Color, emission: Color, energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = emission
	material.emission_energy_multiplier = energy
	material.set_meta("base_albedo", color)
	material.set_meta("base_emission", emission)
	material.set_meta("base_energy", energy)
	materials.append(material)
	return material


func _create_placeholder_mesh() -> void:
	visual_root = Node3D.new()
	visual_root.name = "Visual"
	add_child(visual_root)
	var bone := _make_part_material(BONE_COLOR, Color(0.20, 0.20, 0.18), 0.35)
	var dark := _make_part_material(BONE_DARK, Color(0.05, 0.05, 0.04), 0.15)
	var void_material := _make_part_material(HOLLOW_DARK, Color.BLACK, 0.0)

	# Long stilt legs and a narrow pelvis.
	for side in [-1.0, 1.0]:
		_add_part("Foot", Vector3(0.16, 0.09, 0.36), Vector3(side * 0.15, 0.045, -0.07), Vector3.ZERO, dark)
		_add_part("Shin", Vector3(0.115, 0.62, 0.115), Vector3(side * 0.15, 0.36, 0.0), Vector3(0.02, 0, side * 0.02), bone)
		_add_part("Knee", Vector3(0.16, 0.14, 0.16), Vector3(side * 0.15, 0.70, -0.02), Vector3.ZERO, dark)
		_add_part("Thigh", Vector3(0.15, 0.62, 0.15), Vector3(side * 0.16, 1.02, 0.0), Vector3(-0.03, 0, side * -0.03), bone)
	_add_part("Pelvis", Vector3(0.44, 0.22, 0.26), Vector3(0, 1.32, 0.0), Vector3.ZERO, dark)

	# Sunken torso, shoulders, bowed head.
	_add_part("Spine", Vector3(0.26, 0.58, 0.22), Vector3(0, 1.62, 0.02), Vector3(0.06, 0, 0), bone)
	_add_part("Ribs", Vector3(0.42, 0.22, 0.26), Vector3(0, 1.80, -0.02), Vector3(0.10, 0, 0), dark)
	_add_part("Chest", Vector3(0.48, 0.36, 0.28), Vector3(0, 1.94, -0.02), Vector3(0.08, 0, 0), bone)
	_add_part("Shoulders", Vector3(0.72, 0.11, 0.24), Vector3(0, 2.10, 0.01), Vector3.ZERO, bone)
	_add_part("Neck", Vector3(0.11, 0.18, 0.11), Vector3(0, 2.20, -0.02), Vector3(0.18, 0, 0), dark)
	_add_part("Head", Vector3(0.27, 0.34, 0.28), Vector3(0, 2.34, -0.06), Vector3(0.22, 0, 0.03), bone)
	_add_part("Veil", Vector3(0.31, 0.30, 0.10), Vector3(0, 2.42, 0.10), Vector3(-0.10, 0, 0), dark)
	for side in [-1.0, 1.0]:
		# Deep sockets: two dark recesses instead of eyes.
		_add_part("Socket", Vector3(0.075, 0.035, 0.02), Vector3(side * 0.075, 2.37, -0.195), Vector3(0.20, 0, 0), void_material)
		_add_part("Cheek", Vector3(0.05, 0.17, 0.04), Vector3(side * 0.14, 2.27, -0.16), Vector3(0.15, 0, 0), dark)

	# Overlong arms hanging past the knees.
	for side in [-1.0, 1.0]:
		_add_part("UpperArm", Vector3(0.095, 0.66, 0.095), Vector3(side * 0.36, 1.83, 0.0), Vector3(0.03, 0, side * 0.06), bone)
		_add_part("Elbow", Vector3(0.13, 0.11, 0.13), Vector3(side * 0.38, 1.49, -0.01), Vector3.ZERO, dark)
		_add_part("Forearm", Vector3(0.075, 0.72, 0.075), Vector3(side * 0.38, 1.13, -0.03), Vector3(-0.04, 0, side * 0.02), bone)
		_add_part("Hand", Vector3(0.115, 0.22, 0.10), Vector3(side * 0.38, 0.68, -0.05), Vector3(-0.05, 0, 0), dark)
		for finger in range(3):
			var finger_x: float = float(side) * (0.33 + finger * 0.05)
			_add_part("Finger", Vector3(0.022, 0.26, 0.022), Vector3(finger_x, 0.50, -0.07), Vector3(-0.12, 0, 0), bone)


func _add_part(node_name: String, size: Vector3, offset: Vector3, part_rotation: Vector3, material: Material) -> void:
	var box := BoxMesh.new()
	box.size = size
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = box
	instance.material_override = material
	instance.position = offset
	instance.rotation = part_rotation
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	visual_root.add_child(instance)
