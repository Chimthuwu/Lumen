extends Node3D
class_name DuneBuggy

signal entered
signal exited

const GRAVITY := 20.0
const FIXED_STEP := 1.0 / 120.0
const MAX_STEP_TIME := 0.06
const COLLISION_EPSILON := 0.001

const MAX_SPEED := 22.0
const REVERSE_SPEED := 7.0
const ENGINE_ACCEL := 15.0
const BRAKE_ACCEL := 28.0
const COAST_DRAG := 2.6
const AIR_DRAG := 0.18
const STEER_LOW_SPEED := 2.1
const STEER_HIGH_SPEED := 0.85
const GRIP := 9.0
const HANDBRAKE_GRIP := 1.6
const DRIFT_YAW_BOOST := 1.45

const WHEEL_RADIUS := 0.36
const HALF_TRACK := 0.86
const FRONT_Z := -1.0
const REAR_Z := 1.0
const CHASSIS_HALF_EXTENTS := Vector3(1.05, 0.42, 1.35)
const CHASSIS_CENTER_OFFSET := 0.55
const RIDE_HEIGHT := 0.08
const GROUND_SPRING := 58.0
const GROUND_DAMPING := 9.5
const PROBE_UP := 1.35
const PROBE_DOWN := 3.2

const INTERACT_RADIUS := 3.8
const CAMERA_DISTANCE := 6.4
const CAMERA_LOOK_HEIGHT := 1.05
const CAMERA_TARGET_AHEAD := 2.2
const CAMERA_TRANSITION_TIME := 0.45
const LOOK_SENSITIVITY := 0.0022

# Chunk-readiness governor: the buggy must never outrun the streaming world.
# A look-ahead probe soft-caps speed; a missing chunk under the chassis hard
# freezes physics until the engine catches up.
const GOVERNOR_STEP := 4.0
const GOVERNOR_SAMPLES := 4
const GOVERNOR_REACH := 16.0
const GOVERNOR_SPEED_PER_METRE := 2.2

var world: VoxelWorld
var player: VoxelPlayer
var caster: Lumencaster
var camera: Camera3D
var model: Node3D
var wheel_pivots: Array[Node3D] = []
var wheel_spins: Array[Node3D] = []

var velocity := Vector3.ZERO
var yaw := 0.0
var pitch := 0.0
var roll := 0.0
var grounded := false
var driver := false
var parked_ready := false
var saved_placement := false
var physics_accumulator := 0.0
var wheel_ground := PackedFloat32Array()
var wheel_contact := PackedByteArray()
var wheel_compression := PackedFloat32Array()
var wheel_visual := PackedFloat32Array()
var steer_visual := 0.0
var spin := 0.0

var camera_yaw := 0.0
var camera_pitch := -0.22
var camera_mode := 0
var camera_transition := 0.0
var transition_from := Transform3D.IDENTITY
var last_mouse_time := 0.0
var was_flashlight := true

var governor_speed_cap := INF
var stream_frozen := false

var test_mode := false
var test_throttle := 0.0
var test_steer := 0.0
var test_handbrake := false

const CAMERA_OFF := 0
const CAMERA_ENTER := 1
const CAMERA_CHASE := 2
const CAMERA_EXIT := 3


func _ready() -> void:
	world = get_parent().get_node("VoxelWorld") as VoxelWorld
	player = get_parent().get_node("Player") as VoxelPlayer
	caster = player.get_node_or_null("Lumencaster") as Lumencaster
	wheel_ground.resize(4)
	wheel_contact.resize(4)
	wheel_compression.resize(4)
	wheel_visual.resize(4)
	_build_model()
	_build_camera()


func _process(delta: float) -> void:
	if not parked_ready:
		if world.is_generated and player.spawned:
			_park()
		return
	if not driver:
		_update_interaction_prompt()
	_update_camera(delta)
	_update_wheel_visuals(delta)
	if driver:
		player.position = global_position + Vector3.UP * 0.45


func _physics_process(delta: float) -> void:
	if not parked_ready:
		return
	var throttle := 0.0
	var steer := 0.0
	var handbrake := false
	if driver:
		if test_mode:
			throttle = test_throttle
			steer = test_steer
			handbrake = test_handbrake
		else:
			throttle = Input.get_axis("move_back", "move_forward")
			steer = Input.get_axis("move_left", "move_right")
			handbrake = Input.is_action_pressed("sprint")
		_update_stream_governor()
		if stream_frozen:
			# The ground under the chassis is not ready yet; hold the buggy
			# in place instead of letting it tumble through frontier air.
			velocity = Vector3.ZERO
			physics_accumulator = 0.0
			return
	else:
		governor_speed_cap = INF
		stream_frozen = false
	physics_accumulator = minf(physics_accumulator + delta, MAX_STEP_TIME)
	var steps := 0
	while physics_accumulator >= FIXED_STEP and steps < 8:
		_simulate_step(FIXED_STEP, throttle, steer, handbrake)
		physics_accumulator -= FIXED_STEP
		steps += 1
	if driver:
		player.position = global_position + Vector3.UP * 0.45


# Publishes a generation focus ~2 chunks ahead so the engine streams the road
# before the wheels get there, then caps speed by how far ready terrain
# actually extends in front of the car.
func _update_stream_governor() -> void:
	var forward := _flat_forward()
	var speed := absf(velocity.dot(forward))
	var reach := maxf(GOVERNOR_REACH, speed * 2.0)
	world.set_generation_focus(Vector3i(
		floori(position.x + forward.x * reach),
		floori(position.y),
		floori(position.z + forward.z * reach)))
	var chassis := world._chunk_of(Vector3i(floori(position.x), floori(position.y), floori(position.z)))
	if not world.is_chunk_ready(chassis):
		if not stream_frozen and caster != null:
			caster.show_context_hint("TERRAIN STREAMING - BUGGY HELD", 1.5)
		stream_frozen = true
		governor_speed_cap = 0.0
		return
	stream_frozen = false
	var ready_distance := GOVERNOR_REACH + GOVERNOR_STEP
	for sample in range(1, GOVERNOR_SAMPLES + 1):
		var probe := position + forward * (float(sample) * GOVERNOR_STEP)
		var probe_chunk := world._chunk_of(Vector3i(floori(probe.x), floori(probe.y), floori(probe.z)))
		if not world.is_chunk_ready(probe_chunk):
			ready_distance = float(sample - 1) * GOVERNOR_STEP
			break
	governor_speed_cap = clampf(ready_distance * GOVERNOR_SPEED_PER_METRE, 0.0, MAX_SPEED)


func _unhandled_input(event: InputEvent) -> void:
	if not parked_ready:
		return
	if event.is_action_pressed("interact") and not event.echo:
		if driver:
			exit_vehicle()
		elif _player_in_range():
			enter_vehicle()
		get_viewport().set_input_as_handled()
		return
	if driver and event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		camera_yaw -= event.relative.x * LOOK_SENSITIVITY
		camera_pitch = clampf(camera_pitch - event.relative.y * LOOK_SENSITIVITY, -0.62, 0.28)
		last_mouse_time = _now()


# --- Driving -----------------------------------------------------------------

func _simulate_step(delta: float, throttle: float, steer_input: float, handbrake: bool) -> void:
	_probe_wheels()
	var forward := _flat_forward()
	var right := Basis(Vector3.UP, yaw) * Vector3.RIGHT
	var longitudinal := velocity.dot(forward)
	var lateral := velocity.dot(right)
	var contacts := 0
	for index in range(4):
		if wheel_contact[index] == 1:
			contacts += 1
	grounded = contacts > 0

	var slope_forward := 0.0
	if grounded:
		var ground_sum := 0.0
		for index in range(4):
			if wheel_contact[index] == 1:
				ground_sum += wheel_ground[index]
		var target_y := ground_sum / float(contacts) + RIDE_HEIGHT
		# Spring-damper ride height: bumps push the chassis, drops let it fall.
		var spring := (target_y - position.y) * GROUND_SPRING - velocity.y * GROUND_DAMPING
		velocity.y += spring * delta
		var front_height := _pair_height(0, 1)
		var rear_height := _pair_height(2, 3)
		var left_height := _pair_height(0, 2)
		var right_height := _pair_height(1, 3)
		var pitch_target := atan2(front_height - rear_height, absf(FRONT_Z) + absf(REAR_Z))
		var roll_target := -atan2(left_height - right_height, HALF_TRACK * 2.0)
		var tilt_blend := 1.0 - exp(-delta * 11.0)
		pitch = lerpf(pitch, pitch_target, tilt_blend)
		roll = lerpf(roll, roll_target, tilt_blend)
		var slope_normal := Vector3(0.0, 1.0, 0.0)
		slope_normal.x = -(right_height - left_height) / (HALF_TRACK * 2.0)
		slope_normal.z = -(rear_height - front_height) / (absf(FRONT_Z) + absf(REAR_Z))
		slope_normal = slope_normal.normalized()
		var gravity_vector := Vector3(0.0, -GRAVITY, 0.0)
		var tangent := gravity_vector - slope_normal * gravity_vector.dot(slope_normal)
		slope_forward = tangent.dot(forward)
		longitudinal += tangent.dot(right) * delta
	else:
		velocity.y -= GRAVITY * delta
		var settle := 1.0 - exp(-delta * 3.0)
		pitch = lerpf(pitch, 0.0, settle)
		roll = lerpf(roll, 0.0, settle)

	# Steering is speed-sensitive and reverses when backing up.
	var speed_ratio := clampf(absf(longitudinal) / MAX_SPEED, 0.0, 1.0)
	var steer_rate := lerpf(STEER_LOW_SPEED, STEER_HIGH_SPEED, speed_ratio)
	if grounded:
		var steer_direction := 1.0 if longitudinal >= 0.0 else -1.0
		var drift := DRIFT_YAW_BOOST if handbrake and absf(longitudinal) > 5.0 else 1.0
		yaw -= steer_input * steer_rate * drift * steer_direction * delta
		steer_visual = lerpf(steer_visual, steer_input * 0.42, 1.0 - exp(-delta * 8.0))
	else:
		steer_visual = lerpf(steer_visual, 0.0, 1.0 - exp(-delta * 4.0))
	forward = _flat_forward()
	right = Basis(Vector3.UP, yaw) * Vector3.RIGHT

	var accel := 0.0
	if throttle > 0.01:
		accel = ENGINE_ACCEL * throttle
	elif throttle < -0.01:
		if longitudinal > 0.6:
			accel = -BRAKE_ACCEL * absf(throttle)
		else:
			accel = ENGINE_ACCEL * throttle * 0.55
	elif grounded:
		longitudinal = move_toward(longitudinal, 0.0, COAST_DRAG * delta)
	longitudinal += (accel + slope_forward * 0.85) * delta
	longitudinal = clampf(longitudinal, -REVERSE_SPEED, minf(MAX_SPEED, governor_speed_cap))

	var grip := HANDBRAKE_GRIP if handbrake else GRIP
	if not grounded:
		grip *= 0.15
	lateral = move_toward(lateral, 0.0, grip * delta * maxf(1.0, absf(lateral)))
	lateral *= 1.0 - minf(1.0, AIR_DRAG * delta)

	velocity.x = forward.x * longitudinal + right.x * lateral
	velocity.z = forward.z * longitudinal + right.z * lateral

	var displacement := velocity * delta
	var collided := PackedByteArray([0, 0, 0])
	for axis in [0, 2, 1]:
		var amount := _sweep_axis(axis, displacement[axis])
		if axis != 1 and collided[axis] == 0 and absf(displacement[axis]) > 0.0:
			# One-block ledge step-up, matching the player's traversal rules.
			# Compare magnitudes: the sweep result is signed for reverse motion.
			if absf(_sweep_axis(axis, displacement[axis])) < absf(displacement[axis]) - COLLISION_EPSILON:
				var saved_y := position.y
				var up_amount := _sweep_axis(1, 1.01)
				if up_amount >= 1.01 - COLLISION_EPSILON:
					position.y += up_amount
					var retry := _sweep_axis(axis, displacement[axis])
					if absf(retry) >= absf(displacement[axis]) - COLLISION_EPSILON:
						amount = retry
					else:
						position.y = saved_y
				else:
					position.y = saved_y
		position[axis] += amount
		if axis == 1 and absf(amount) < absf(displacement[axis]) - COLLISION_EPSILON:
			collided[axis] = 1
			velocity.y = 0.0
		elif axis != 1 and absf(amount) < absf(displacement[axis]) - COLLISION_EPSILON:
			collided[axis] = 1
			# Scrub speed into a wall instead of sliding at full pace.
			velocity.x *= 0.35
			velocity.z *= 0.35
			longitudinal *= 0.35
			lateral *= 0.35

	rotation = Vector3(pitch, yaw, roll)
	spin -= longitudinal / WHEEL_RADIUS * delta


func _pair_height(a: int, b: int) -> float:
	var total := 0.0
	var count := 0
	if wheel_contact[a] == 1:
		total += wheel_ground[a]
		count += 1
	if wheel_contact[b] == 1:
		total += wheel_ground[b]
		count += 1
	if count == 0:
		return position.y
	return total / float(count)


func _probe_wheels() -> void:
	var forward := _flat_forward()
	var right := Basis(Vector3.UP, yaw) * Vector3.RIGHT
	var offsets := [
		Vector3(-HALF_TRACK, 0.0, FRONT_Z),
		Vector3(HALF_TRACK, 0.0, FRONT_Z),
		Vector3(-HALF_TRACK, 0.0, REAR_Z),
		Vector3(HALF_TRACK, 0.0, REAR_Z)
	]
	for index in range(4):
		var local: Vector3 = offsets[index]
		var world_x := position.x + right.x * local.x - forward.x * local.z
		var world_z := position.z + right.z * local.x - forward.z * local.z
		var ground := _ground_under(world_x, world_z)
		if ground.is_empty():
			wheel_contact[index] = 0
			wheel_ground[index] = position.y
			wheel_compression[index] = 0.0
			continue
		wheel_contact[index] = 1
		var height: float = ground["height"]
		wheel_ground[index] = height
		wheel_compression[index] = clampf(position.y + PROBE_UP - height, 0.0, 1.2)


func _ground_under(world_x: float, world_z: float) -> Dictionary:
	var cell_x := floori(world_x)
	var cell_z := floori(world_z)
	var start_y := floori(position.y + PROBE_UP)
	var end_y := floori(position.y - PROBE_DOWN)
	var cell_y := start_y
	while cell_y >= end_y:
		if world.is_solid(Vector3i(cell_x, cell_y, cell_z)):
			var surface := float(cell_y + 1)
			# A wall rising past the chassis is not drivable ground.
			if surface <= position.y + 0.55:
				return {"height": surface}
			return {}
		cell_y -= 1
	return {}


func _sweep_axis(axis: int, motion: float) -> float:
	if absf(motion) < 0.000001:
		return 0.0
	var center := position + Vector3(0.0, CHASSIS_CENTER_OFFSET, 0.0)
	var end_center := center
	end_center[axis] += motion
	var start_min := center - CHASSIS_HALF_EXTENTS
	var end_min := end_center - CHASSIS_HALF_EXTENTS
	var start_max := center + CHASSIS_HALF_EXTENTS
	var end_max := end_center + CHASSIS_HALF_EXTENTS
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
					var gap := float(cell[axis]) - (center[axis] + CHASSIS_HALF_EXTENTS[axis])
					if gap >= -COLLISION_EPSILON and gap < allowed:
						allowed = maxf(0.0, gap - COLLISION_EPSILON)
				elif motion < 0.0:
					var gap := (center[axis] - CHASSIS_HALF_EXTENTS[axis]) - float(cell[axis] + 1)
					if gap >= -COLLISION_EPSILON and -gap < -allowed:
						allowed = -maxf(0.0, gap - COLLISION_EPSILON)
	return allowed


func _overlaps_other_axes(center: Vector3, cell: Vector3i, ignored_axis: int) -> bool:
	for axis in range(3):
		if axis == ignored_axis:
			continue
		if center[axis] + CHASSIS_HALF_EXTENTS[axis] <= float(cell[axis]) + COLLISION_EPSILON:
			return false
		if center[axis] - CHASSIS_HALF_EXTENTS[axis] >= float(cell[axis] + 1) - COLLISION_EPSILON:
			return false
	return true


func _flat_forward() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw)).normalized()


# --- Enter and exit -----------------------------------------------------------

func _player_in_range() -> bool:
	if not player.spawned:
		return false
	return player.global_position.distance_to(global_position + Vector3.UP * 0.6) <= INTERACT_RADIUS


func enter_vehicle() -> bool:
	if driver or not parked_ready or not player.spawned:
		return false
	driver = true
	player.driving = true
	player.velocity = Vector3.ZERO
	player.on_floor = false
	player.visible = false
	was_flashlight = world.flashlight_enabled
	world.set_flashlight_enabled(false)
	world.player_camera = camera
	transition_from = player.camera.global_transform
	camera_transition = 0.0
	camera_mode = CAMERA_ENTER
	camera_yaw = yaw
	camera_pitch = -0.22
	camera.global_transform = transition_from
	player.camera.current = false
	camera.current = true
	velocity = Vector3.ZERO
	if caster != null:
		caster.stop_action_state()
		caster.show_context_hint("E  EXIT VEHICLE", 1.6)
	entered.emit()
	return true


func exit_vehicle() -> void:
	if not driver:
		return
	if velocity.length() > 1.6:
		if caster != null:
			caster.show_context_hint("STOP TO EXIT", 1.1)
		return
	var spot := _find_exit_spot()
	driver = false
	player.driving = false
	player.position = spot
	player.velocity = Vector3.ZERO
	player.on_floor = false
	player.visible = true
	velocity = Vector3.ZERO
	world.set_flashlight_enabled(was_flashlight)
	world.player_camera = player.camera
	transition_from = camera.global_transform
	camera_transition = 0.0
	camera_mode = CAMERA_EXIT
	exited.emit()


func _find_exit_spot() -> Vector3:
	var right := Basis(Vector3.UP, yaw) * Vector3.RIGHT
	var forward := _flat_forward()
	var candidates := [
		global_position - right * 2.1,
		global_position + right * 2.1,
		global_position + forward * 2.7,
		global_position - forward * 2.7
	]
	for candidate in candidates:
		var cell_x := floori(candidate.x)
		var cell_z := floori(candidate.z)
		var start_y := floori(position.y + 2.2)
		for y in range(start_y, start_y - 5, -1):
			var cell := Vector3i(cell_x, y, cell_z)
			if not world.is_solid(cell):
				continue
			if world.is_solid(cell + Vector3i.UP) or world.is_solid(cell + Vector3i.UP * 2):
				break
			return Vector3(cell_x + 0.5, float(y + 1) + 0.02, cell_z + 0.5)
	return global_position + Vector3.UP * 0.2


func get_exit_position() -> Vector3:
	return _find_exit_spot()


func _update_interaction_prompt() -> void:
	if caster == null or not is_instance_valid(caster):
		return
	if caster.hint_time > 0.01:
		return
	if _player_in_range():
		caster.show_context_hint("E   DRIVE DUNE BUGGY", 0.2)


# --- Camera -------------------------------------------------------------------

func _build_camera() -> void:
	camera = Camera3D.new()
	camera.name = "BuggyCamera"
	camera.fov = 75.0
	camera.near = 0.05
	camera.top_level = true
	camera.current = false
	add_child(camera)


func _update_camera(delta: float) -> void:
	if camera_mode == CAMERA_OFF:
		return
	if driver and camera_mode == CAMERA_CHASE:
		if _now() - last_mouse_time > 1.4 and absf(velocity.length()) > 3.0:
			camera_yaw = lerp_angle(camera_yaw, yaw, 1.0 - exp(-delta * 1.6))
	var desired := _desired_chase_transform()
	if camera_mode == CAMERA_EXIT:
		# Ease back to the first-person camera that owns the player again.
		desired = player.camera.global_transform
	if camera_mode == CAMERA_ENTER or camera_mode == CAMERA_EXIT:
		camera_transition += delta
		var alpha := clampf(camera_transition / CAMERA_TRANSITION_TIME, 0.0, 1.0)
		alpha = alpha * alpha * (3.0 - 2.0 * alpha)
		camera.global_transform = transition_from.interpolate_with(desired, alpha)
		if camera_transition >= CAMERA_TRANSITION_TIME:
			if camera_mode == CAMERA_ENTER:
				camera_mode = CAMERA_CHASE
			else:
				camera_mode = CAMERA_OFF
				camera.current = false
				player.camera.current = true
		return
	var blend := 1.0 - exp(-delta * 9.0)
	camera.global_transform = camera.global_transform.interpolate_with(desired, blend)


func _desired_chase_transform() -> Transform3D:
	var focus := global_position + Vector3.UP * CAMERA_LOOK_HEIGHT
	var orbit := Basis(Vector3.UP, camera_yaw) * Basis(Vector3.RIGHT, camera_pitch)
	var offset := orbit * Vector3(0.0, 0.0, CAMERA_DISTANCE)
	var direction := offset.normalized()
	var distance := offset.length()
	var obstruction := _raycast_distance(focus, direction, distance)
	if obstruction < distance:
		distance = maxf(1.6, obstruction - 0.25)
	var origin := focus + direction * distance + Vector3.UP * 0.18
	var look_target := focus + _flat_forward() * CAMERA_TARGET_AHEAD
	var basis := Basis.looking_at((look_target - origin).normalized(), Vector3.UP)
	return Transform3D(basis, origin)


func _raycast_distance(from: Vector3, direction: Vector3, max_distance: float) -> float:
	var steps := ceili(max_distance / 0.2)
	for step_index in range(1, steps + 1):
		var distance := float(step_index) * 0.2
		var point := from + direction * distance
		if world.is_solid(Vector3i(floori(point.x), floori(point.y), floori(point.z))):
			return distance
	return max_distance


func _now() -> float:
	return float(Time.get_ticks_msec()) * 0.001


# --- Parking and save ---------------------------------------------------------

func _park() -> void:
	if saved_placement:
		parked_ready = true
		return
	var found := false
	var spawn_cell := world.spawn_origin
	for radius in range(5, 19):
		if found:
			break
		for step in range(16):
			var angle := TAU * float(step) / 16.0
			var x := spawn_cell.x + roundi(cos(angle) * float(radius))
			var z := spawn_cell.z + roundi(sin(angle) * float(radius))
			if not _can_park_at(x, z):
				continue
			position = Vector3(float(x) + 0.5, float(world.get_surface_height(x, z) + 1), float(z) + 0.5)
			yaw = angle + PI * 0.5
			rotation = Vector3(0.0, yaw, 0.0)
			found = true
			break
	if not found:
		var fallback_x := spawn_cell.x + 5
		var fallback_z := spawn_cell.z
		position = Vector3(float(fallback_x) + 0.5, float(world.get_surface_height(fallback_x, fallback_z) + 1), float(fallback_z) + 0.5)
	parked_ready = true
	if caster != null:
		caster.show_context_hint("DUNE BUGGY WAITING EAST OF CAMP\nWALK CLOSE AND PRESS E", 4.5)


func _can_park_at(x: int, z: int) -> bool:
	if world.is_canyon_floor(x, z):
		return false
	var height := world.get_surface_height(x, z)
	for offset_z in range(-1, 2):
		for offset_x in range(-1, 2):
			var cell_x := x + offset_x
			var cell_z := z + offset_z
			if not world._inside_world(Vector3i(cell_x, height + 1, cell_z)):
				return false
			if world.get_surface_height(cell_x, cell_z) != height:
				return false
			if world.is_solid(Vector3i(cell_x, height + 1, cell_z)):
				return false
			if world.is_solid(Vector3i(cell_x, height + 2, cell_z)):
				return false
	return absi(x - world.spawn_origin.x) > 2 or absi(z - world.spawn_origin.z) > 2


func to_save_data() -> Dictionary:
	return {
		"position": [position.x, position.y, position.z],
		"yaw": yaw,
		"driving": driver
	}


func apply_save_data(data: Dictionary) -> void:
	if data.is_empty() or not data.has("position"):
		return
	if driver:
		exit_vehicle()
	var saved_position: Array = data["position"]
	if saved_position.size() == 3:
		position = Vector3(float(saved_position[0]), float(saved_position[1]), float(saved_position[2]))
	yaw = float(data.get("yaw", yaw))
	rotation = Vector3(0.0, yaw, 0.0)
	velocity = Vector3.ZERO
	parked_ready = true
	saved_placement = true


# --- Procedural model ---------------------------------------------------------

func _build_model() -> void:
	model = Node3D.new()
	model.name = "Model"
	add_child(model)

	var body := _material(Color(0.46, 0.36, 0.22), 0.62, 0.22)
	var body_light := _material(Color(0.62, 0.50, 0.30), 0.58, 0.18)
	var frame := _material(Color(0.09, 0.095, 0.10), 0.48, 0.55)
	var seat_mat := _material(Color(0.10, 0.095, 0.09), 0.9, 0.0)
	var tyre := _material(Color(0.045, 0.045, 0.048), 0.95, 0.0)
	var hub := _material(Color(0.36, 0.34, 0.29), 0.42, 0.6)
	var lamp := _emissive_material(Color(1.0, 0.62, 0.22), 2.4)

	# Low, long chassis with a raised nose and exposed running gear.
	_add_box(model, "FloorPan", Vector3(1.38, 0.12, 1.75), Vector3(0, 0.34, 0.05), frame)
	_add_box(model, "Chassis", Vector3(1.42, 0.30, 2.15), Vector3(0, 0.52, 0.05), body)
	_add_box(model, "Nose", Vector3(1.18, 0.20, 0.62), Vector3(0, 0.64, -1.14), body_light, Vector3(-0.16, 0, 0))
	_add_box(model, "NoseLip", Vector3(1.30, 0.10, 0.18), Vector3(0, 0.52, -1.40), body)
	_add_box(model, "Bumper", Vector3(1.62, 0.11, 0.14), Vector3(0, 0.38, -1.44), frame)
	_add_box(model, "RearDeck", Vector3(1.10, 0.28, 0.55), Vector3(0, 0.70, 0.98), body)
	_add_box(model, "EngineBlock", Vector3(0.62, 0.30, 0.34), Vector3(0, 0.88, 0.96), frame)
	_add_box(model, "SideRailLeft", Vector3(0.10, 0.16, 1.85), Vector3(-0.72, 0.70, 0.02), body_light)
	_add_box(model, "SideRailRight", Vector3(0.10, 0.16, 1.85), Vector3(0.72, 0.70, 0.02), body_light)
	_add_box(model, "SkidPlate", Vector3(1.05, 0.06, 0.70), Vector3(0, 0.26, -1.05), frame, Vector3(-0.2, 0, 0))

	# Exposed axles with long-travel suspension arms.
	for axle_z in [FRONT_Z, REAR_Z]:
		_add_cylinder(model, "Axle_%d" % int(axle_z * 10.0), 0.055, 1.98, Vector3(0, 0.34, axle_z), frame, Vector3(0, 0, PI * 0.5))
		for side in [-1.0, 1.0]:
			_add_box(model, "SuspArm", Vector3(0.52, 0.06, 0.10), Vector3(side * 0.43, 0.38, axle_z), frame, Vector3(0, 0, side * 0.22))

	# Open cockpit: seat, steering column and wheel.
	_add_box(model, "SeatBase", Vector3(0.56, 0.10, 0.48), Vector3(-0.10, 0.72, 0.26), seat_mat)
	_add_box(model, "SeatBack", Vector3(0.56, 0.56, 0.11), Vector3(-0.10, 0.98, 0.52), seat_mat, Vector3(0.14, 0, 0))
	_add_cylinder(model, "SteeringColumn", 0.035, 0.48, Vector3(-0.10, 0.90, -0.32), frame, Vector3(1.05, 0, 0))
	_add_torus(model, "SteeringWheel", 0.09, 0.17, Vector3(-0.10, 1.09, -0.15), frame, Vector3(1.05, 0, 0))
	_add_box(model, "Dash", Vector3(1.02, 0.12, 0.16), Vector3(0, 0.80, -0.64), frame, Vector3(-0.22, 0, 0))

	# Roll cage over the open cockpit.
	for side in [-1.0, 1.0]:
		_add_box(model, "CageFront", Vector3(0.065, 0.64, 0.065), Vector3(side * 0.60, 1.02, -0.52), frame)
		_add_box(model, "CageRear", Vector3(0.065, 0.64, 0.065), Vector3(side * 0.60, 1.02, 0.52), frame)
		_add_box(model, "CageRail", Vector3(0.065, 0.065, 1.14), Vector3(side * 0.60, 1.33, 0.0), frame)
	_add_box(model, "CageCross", Vector3(1.26, 0.065, 0.065), Vector3(0, 1.33, -0.52), frame)
	_add_box(model, "CageBrace", Vector3(1.26, 0.055, 0.055), Vector3(0, 1.20, 0.52), frame)

	# Headlights and tail lamps.
	for side in [-1.0, 1.0]:
		_add_box(model, "Headlight", Vector3(0.17, 0.11, 0.05), Vector3(side * 0.40, 0.70, -1.44), lamp)
		_add_box(model, "Taillight", Vector3(0.10, 0.07, 0.04), Vector3(side * 0.44, 0.78, 1.26), lamp)

	# Spare wheel mounted on the rear deck.
	_add_cylinder(model, "SpareTyre", WHEEL_RADIUS, 0.24, Vector3(0, 0.96, 1.28), tyre, Vector3(PI * 0.5, 0, 0))
	_add_cylinder(model, "SpareHub", 0.13, 0.26, Vector3(0, 0.96, 1.28), hub, Vector3(PI * 0.5, 0, 0))

	# Four wheels: a steering pivot around Y, a spin node around X, then the tyre.
	var wheel_positions := [
		Vector3(-HALF_TRACK, WHEEL_RADIUS, FRONT_Z),
		Vector3(HALF_TRACK, WHEEL_RADIUS, FRONT_Z),
		Vector3(-HALF_TRACK, WHEEL_RADIUS, REAR_Z),
		Vector3(HALF_TRACK, WHEEL_RADIUS, REAR_Z)
	]
	var wheel_names := ["Wheel_FL", "Wheel_FR", "Wheel_RL", "Wheel_RR"]
	for index in range(4):
		var pivot := Node3D.new()
		pivot.name = wheel_names[index]
		pivot.position = wheel_positions[index]
		model.add_child(pivot)
		wheel_pivots.append(pivot)
		var spin_node := Node3D.new()
		spin_node.name = "Spin"
		pivot.add_child(spin_node)
		wheel_spins.append(spin_node)
		_add_cylinder(spin_node, "Tyre", WHEEL_RADIUS, 0.26, Vector3.ZERO, tyre, Vector3(0, 0, PI * 0.5))
		_add_cylinder(spin_node, "Hub", 0.14, 0.28, Vector3.ZERO, hub, Vector3(0, 0, PI * 0.5))
		for spoke in range(4):
			var spoke_angle := TAU * float(spoke) / 4.0
			var spoke_pos := Vector3(0.0, sin(spoke_angle) * 0.20, cos(spoke_angle) * 0.20)
			_add_box(spin_node, "Spoke", Vector3(0.28, 0.045, 0.045), spoke_pos, frame, Vector3(spoke_angle, 0, 0))


func _update_wheel_visuals(delta: float) -> void:
	for index in range(4):
		var pivot := wheel_pivots[index]
		var front := index < 2
		pivot.rotation.y = steer_visual if front else 0.0
		var target_offset := 0.0
		if wheel_contact[index] == 1:
			target_offset = clampf(wheel_ground[index] - position.y, -0.12, 0.18)
		wheel_visual[index] = lerpf(wheel_visual[index], target_offset, 1.0 - exp(-delta * 14.0))
		pivot.position.y = WHEEL_RADIUS + wheel_visual[index]
		wheel_spins[index].rotation.x = spin


func _material(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	return material


func _emissive_material(color: Color, energy: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = energy
	return material


func _add_box(parent: Node3D, node_name: String, size: Vector3, offset: Vector3, material: Material, box_rotation := Vector3.ZERO) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = size
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = box
	instance.material_override = material
	instance.position = offset
	instance.rotation = box_rotation
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)
	return instance


func _add_cylinder(parent: Node3D, node_name: String, radius: float, height: float, offset: Vector3, material: Material, mesh_rotation := Vector3.ZERO) -> MeshInstance3D:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = height
	cylinder.radial_segments = 14
	cylinder.rings = 1
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = cylinder
	instance.material_override = material
	instance.position = offset
	instance.rotation = mesh_rotation
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)
	return instance


func _add_torus(parent: Node3D, node_name: String, inner_radius: float, outer_radius: float, offset: Vector3, material: Material, mesh_rotation := Vector3.ZERO) -> MeshInstance3D:
	var torus := TorusMesh.new()
	torus.inner_radius = inner_radius
	torus.outer_radius = outer_radius
	torus.rings = 16
	torus.ring_segments = 8
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = torus
	instance.material_override = material
	instance.position = offset
	instance.rotation = mesh_rotation
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	parent.add_child(instance)
	return instance
