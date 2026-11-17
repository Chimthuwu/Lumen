extends Node3D
class_name GloomEnemy

const GRAVITY := 20.0
const COLLISION_EPSILON := 0.001
const FIXED_STEP := 1.0 / 60.0
const MAX_STEP_TIME := 0.05

@export var move_speed := 2.2
@export var max_health := 20.0
@export var touch_damage := 5.0
@export var attack_range := 1.3
@export var attack_interval := 1.0
@export var dissolve_light_level := 12
@export var body_half_extents := Vector3(0.30, 0.60, 0.30)

var health := 20.0
var world: VoxelWorld
var player: VoxelPlayer
var attack_cooldown := 0.0
var dissolve_timer := 0.0
var velocity := Vector3.ZERO
var on_floor := false
var frozen := false
var wish_direction := Vector3.ZERO
var axis_collided := PackedByteArray([0, 0, 0])
var physics_accumulator := 0.0

func _ready() -> void:
	add_to_group("enemies")
	health = max_health
	var root := get_tree().current_scene
	if root == null:
		root = get_parent()
	world = root.get_node("VoxelWorld") as VoxelWorld
	player = root.get_node("Player") as VoxelPlayer
	_create_placeholder_mesh()

func _process(delta: float) -> void:
	if not is_instance_valid(player) or not player.spawned or not world.is_generated:
		return
	attack_cooldown = maxf(0.0, attack_cooldown - delta)
	var cell := Vector3i(floori(position.x), floori(position.y + 0.2), floori(position.z))
	if _should_dissolve(cell):
		dissolve_timer += delta
		if dissolve_timer >= 0.65:
			_on_dissolve()
			queue_free()
		return
	dissolve_timer = 0.0
	if frozen:
		wish_direction = Vector3.ZERO
		return
	_update_behavior(delta)
	var toward := player.position - position
	if toward.length() <= attack_range and attack_cooldown <= 0.0:
		player.take_damage(touch_damage)
		attack_cooldown = attack_interval

func _physics_process(delta: float) -> void:
	if not is_instance_valid(player) or not player.spawned or not world.is_generated:
		return
	# Fixed substeps keep a frame hitch from tunnelling a small enemy through a
	# one-block wall.
	physics_accumulator = minf(physics_accumulator + delta, MAX_STEP_TIME)
	while physics_accumulator >= FIXED_STEP:
		_simulate_step(FIXED_STEP)
		physics_accumulator -= FIXED_STEP

func _simulate_step(delta: float) -> void:
	var flat := wish_direction if not frozen else Vector3.ZERO
	flat.y = 0.0
	if flat.length_squared() > 0.0001:
		flat = flat.normalized()
	velocity.x = flat.x * move_speed
	velocity.z = flat.z * move_speed
	velocity.y -= GRAVITY * delta
	var was_on_floor := on_floor
	on_floor = false
	axis_collided.fill(0)
	var displacement := velocity * delta
	for axis in [0, 2, 1]:
		var amount := _sweep_axis(axis, displacement[axis])
		if axis != 1 and axis_collided[axis] != 0 and was_on_floor and absf(displacement[axis]) > 0.0:
			var saved_y := position.y
			var up_amount := _sweep_axis(1, 1.01)
			if up_amount >= 1.01 - COLLISION_EPSILON:
				position.y += up_amount
				axis_collided[axis] = 0
				amount = _sweep_axis(axis, displacement[axis])
				if axis_collided[axis] != 0:
					position.y = saved_y
					amount = 0.0
			else:
				position.y = saved_y
		position[axis] += amount
		if axis_collided[axis] != 0:
			velocity[axis] = 0.0
	if axis_collided[1] == 1:
		on_floor = true

func _sweep_axis(axis: int, motion: float) -> float:
	if absf(motion) < 0.000001:
		return 0.0
	var center := position + Vector3(0.0, body_half_extents.y, 0.0)
	var end_center := center
	end_center[axis] += motion
	var start_min := center - body_half_extents
	var end_min := end_center - body_half_extents
	var start_max := center + body_half_extents
	var end_max := end_center + body_half_extents
	var low := Vector3i(floori(minf(start_min.x, end_min.x)), floori(minf(start_min.y, end_min.y)), floori(minf(start_min.z, end_min.z)))
	var high := Vector3i(floori(maxf(start_max.x, end_max.x)), floori(maxf(start_max.y, end_max.y)), floori(maxf(start_max.z, end_max.z)))
	var allowed := motion
	for z in range(low.z, high.z + 1):
		for y in range(low.y, high.y + 1):
			for x in range(low.x, high.x + 1):
				var cell := Vector3i(x, y, z)
				if not world.is_solid(cell) or not _overlaps_other_axes(center, cell, axis):
					continue
				if motion > 0.0:
					var gap := float(cell[axis]) - (center[axis] + body_half_extents[axis])
					if gap >= -COLLISION_EPSILON and gap < allowed:
						allowed = maxf(0.0, gap - COLLISION_EPSILON)
						axis_collided[axis] = 1
				elif motion < 0.0:
					var gap := (center[axis] - body_half_extents[axis]) - float(cell[axis] + 1)
					if gap >= -COLLISION_EPSILON and -gap < -allowed:
						allowed = -maxf(0.0, gap - COLLISION_EPSILON)
						axis_collided[axis] = 1
	return allowed

func _overlaps_other_axes(center: Vector3, cell: Vector3i, ignored_axis: int) -> bool:
	for axis in range(3):
		if axis == ignored_axis:
			continue
		if center[axis] + body_half_extents[axis] <= float(cell[axis]) + COLLISION_EPSILON:
			return false
		if center[axis] - body_half_extents[axis] >= float(cell[axis] + 1) - COLLISION_EPSILON:
			return false
	return true

func _should_dissolve(cell: Vector3i) -> bool:
	return false

func _on_dissolve() -> void:
	pass

func _update_behavior(delta: float) -> void:
	var target := player.position
	var flat := target - position
	flat.y = 0.0
	if flat.length_squared() > 0.01:
		wish_direction = flat.normalized()
		look_at(Vector3(target.x, position.y, target.z), Vector3.UP)
	else:
		wish_direction = Vector3.ZERO

func apply_damage(amount: float) -> void:
	health -= amount
	if health <= 0.0:
		queue_free()

func _create_placeholder_mesh() -> void:
	var mesh_instance := MeshInstance3D.new()
	var mesh := SphereMesh.new()
	mesh.radius = 0.32
	mesh.height = 0.7
	mesh_instance.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.34, 0.08, 0.42)
	mesh_instance.material_override = material
	add_child(mesh_instance)
