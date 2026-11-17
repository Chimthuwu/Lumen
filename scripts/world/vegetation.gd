extends Node3D
class_name WorldVegetation

const VEGETATION_SHADER := preload("res://shaders/vegetation.gdshader")
const ARCHETYPE_COUNT := 6
const ARCHETYPE_SEED := 4111
const GRASS_CELL := 3
const GRASS_CHANCE := 0.055
const CANYON_FLOOR_MAX := 19
const BARK_DARK := Color(0.16, 0.12, 0.11)
const BARK_LIGHT := Color(0.58, 0.49, 0.40)
const GRASS_DARK := Color(0.20, 0.18, 0.155)
const GRASS_LIGHT := Color(0.38, 0.34, 0.28)

var tree_meshes: Array[ArrayMesh] = []
var tree_materials: Array[ShaderMaterial] = []
var materials: Array[ShaderMaterial] = []
var tree_instances: Array[MultiMeshInstance3D] = []
var tree_multimeshes: Array[MultiMesh] = []
var grass_instance: MultiMeshInstance3D
var tree_sites: Array = []
var site_slots: Dictionary = {}
var tree_count := 0
var grass_count := 0


func configure(world_bounds: AABB) -> void:
	for index in range(ARCHETYPE_COUNT):
		tree_meshes.append(_build_archetype(index))
		tree_materials.append(_make_material(0.0))
		tree_multimeshes.append(MultiMesh.new())
		var instance := MultiMeshInstance3D.new()
		instance.name = "Trees_%d" % index
		instance.multimesh = tree_multimeshes[index]
		instance.material_override = tree_materials[index]
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		instance.custom_aabb = world_bounds
		instance.visibility_range_end = 0.0
		add_child(instance)
		tree_instances.append(instance)

	grass_instance = _make_cover_instance("AshGrass", _build_grass_mesh(), 0.10)


func build_instances(sites: Array, heights: PackedInt32Array, world_seed: int, biome_map: PackedByteArray = PackedByteArray()) -> void:
	tree_sites = sites
	var per_archetype: Array = []
	for index in range(ARCHETYPE_COUNT):
		per_archetype.append([])
	site_slots.clear()
	for site in sites:
		var rng := RandomNumberGenerator.new()
		rng.seed = int(site["seed"])
		var archetype := rng.randi_range(0, ARCHETYPE_COUNT - 1)
		var landmark := bool(site["landmark"])
		var scale_value := rng.randf_range(1.5, 1.9) if landmark else rng.randf_range(1.0, 1.32)
		var rotation := rng.randf_range(0.0, TAU)
		var position := Vector3(float(site["x"]) + 0.5, float(site["y"]) + 1.0, float(site["z"]) + 0.5)
		var transform := Transform3D(Basis(Vector3.UP, rotation).scaled(Vector3(scale_value, scale_value * rng.randf_range(0.95, 1.12), scale_value)), position)
		per_archetype[archetype].append(transform)

	for archetype in range(ARCHETYPE_COUNT):
		var transforms: Array = per_archetype[archetype]
		var multimesh := tree_multimeshes[archetype]
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.mesh = tree_meshes[archetype]
		multimesh.instance_count = transforms.size()
		for index in range(transforms.size()):
			multimesh.set_instance_transform(index, transforms[index])

	# Site slots are built in the same order as each archetype's transforms so a
	# mined stump can hide its own tree without touching the rest of the batch.
	var archetype_cursor := PackedInt32Array()
	archetype_cursor.resize(ARCHETYPE_COUNT)
	archetype_cursor.fill(0)
	tree_count = 0
	for site in sites:
		var rng := RandomNumberGenerator.new()
		rng.seed = int(site["seed"])
		var archetype := rng.randi_range(0, ARCHETYPE_COUNT - 1)
		site_slots[Vector3i(int(site["x"]), int(site["y"]), int(site["z"]))] = {
			"archetype": archetype,
			"index": archetype_cursor[archetype]
		}
		archetype_cursor[archetype] += 1
		tree_count += 1

	_build_ground_cover(heights, world_seed, biome_map)


func set_sun(direction: Vector3, color: Color, strength: float) -> void:
	for material in materials:
		material.set_shader_parameter("sun_direction", direction.normalized())
		material.set_shader_parameter("sun_color", Vector3(color.r, color.g, color.b))
		material.set_shader_parameter("sun_strength", clampf(strength, 0.0, 1.0))


func set_ambient_level(level: float) -> void:
	for material in materials:
		material.set_shader_parameter("ambient_sky_level", clampf(level, 0.0, 1.0))


func hide_tree_at(stump_cell: Vector3i) -> void:
	if not site_slots.has(stump_cell):
		return
	var slot: Dictionary = site_slots[stump_cell]
	var multimesh: MultiMesh = tree_multimeshes[int(slot["archetype"])]
	var index := int(slot["index"])
	if index < 0 or index >= multimesh.instance_count:
		return
	multimesh.set_instance_transform(index, Transform3D(Basis().scaled(Vector3.ZERO), Vector3(0.0, -1000.0, 0.0)))


# --- Tree archetypes --------------------------------------------------------

func _build_archetype(index: int) -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = ARCHETYPE_SEED + index * 7919
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.set_smooth_group(-1)
	match index:
		0:
			_build_tall_tree(st, rng)
		1:
			_build_leaning_tree(st, rng)
		2:
			_build_gnarled_tree(st, rng)
		3:
			_build_snag(st, rng)
		4:
			_build_forked_tree(st, rng)
		_:
			_build_sparse_tree(st, rng)
	st.generate_normals()
	return st.commit()


func _build_tall_tree(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var height := 10.2
	var points := _add_trunk(st, rng, height, 0.42, 0.13, Vector3(0.4, 0.0, 0.2), 4, 5)
	_add_roots(st, rng, 0.45)
	for branch in range(4):
		var origin: Vector3 = points[rng.randi_range(1, points.size() - 1)]
		var angle := rng.randf_range(0.0, TAU)
		var direction := Vector3(cos(angle), rng.randf_range(0.4, 0.9), sin(angle))
		_add_branch(st, rng, origin, direction, rng.randf_range(1.9, 3.0), 0.12, height)
	for spike in range(2):
		var direction := Vector3(rng.randf_range(-0.6, 0.6), 1.0, rng.randf_range(-0.6, 0.6))
		_add_limb(st, points[points.size() - 1], points[points.size() - 1] + direction.normalized() * rng.randf_range(0.8, 1.6), 0.09, 0.02, 4, 0.95, 1.0)


func _build_leaning_tree(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var height := 8.8
	var points := _add_trunk(st, rng, height, 0.5, 0.14, Vector3(2.1, 0.0, 0.7), 4, 5)
	_add_roots(st, rng, 0.55)
	for branch in range(5):
		var origin: Vector3 = points[rng.randi_range(1, points.size() - 1)]
		var direction := Vector3(rng.randf_range(0.5, 1.1), rng.randf_range(0.15, 0.65), rng.randf_range(-0.7, 0.7))
		var length := rng.randf_range(2.0, 3.4)
		_add_branch(st, rng, origin, direction, length, 0.13, height)
	var top: Vector3 = points[points.size() - 1]
	_add_limb(st, top, top + Vector3(0.9, 1.4, 0.2), 0.1, 0.02, 4, 0.95, 1.0)


func _build_gnarled_tree(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var height := 7.6
	var points := _add_trunk(st, rng, height, 0.55, 0.16, Vector3(0.9, 0.0, 0.75), 5, 5)
	_add_roots(st, rng, 0.6)
	for branch in range(7):
		var origin: Vector3 = points[rng.randi_range(1, points.size() - 1)]
		var angle := rng.randf_range(0.0, TAU)
		var direction := Vector3(cos(angle), rng.randf_range(0.2, 0.8), sin(angle))
		var length := rng.randf_range(1.6, 3.2)
		_add_branch(st, rng, origin, direction, length, 0.11, height, true)
	var top: Vector3 = points[points.size() - 1]
	_add_limb(st, top, top + Vector3(-0.5, 1.1, 0.3), 0.09, 0.02, 4, 0.95, 1.0)


func _build_snag(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var height := 4.4
	var points := _add_trunk(st, rng, height, 0.62, 0.28, Vector3(0.25, 0.0, -0.2), 3, 5)
	_add_roots(st, rng, 0.68)
	for spike in range(3):
		var top: Vector3 = points[points.size() - 1]
		var direction := Vector3(rng.randf_range(-0.7, 0.7), 1.0, rng.randf_range(-0.7, 0.7))
		_add_limb(st, top, top + direction.normalized() * rng.randf_range(0.5, 1.3), 0.17, 0.02, 4, 0.85, 1.0)
	for stub in range(2):
		var origin: Vector3 = points[rng.randi_range(1, points.size() - 1)]
		var angle := rng.randf_range(0.0, TAU)
		_add_limb(st, origin, origin + Vector3(cos(angle), 0.25, sin(angle)) * rng.randf_range(0.5, 1.1), 0.14, 0.04, 4, 0.5, 0.7)


func _build_forked_tree(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var base := Vector3.ZERO
	_add_roots(st, rng, 0.5)
	for side_index in range(2):
		var side := -1.0 if side_index == 0 else 1.0
		var direction := Vector3(0.75 * side, 0.0, rng.randf_range(-0.3, 0.3))
		var points := _add_trunk(st, rng, 7.8, 0.34, 0.1, direction * 1.5, 4, 5, base + Vector3(0.12 * side, 0.0, 0.0))
		for branch in range(2):
			var origin: Vector3 = points[rng.randi_range(1, points.size() - 1)]
			var angle := rng.randf_range(-1.0, 1.0)
			_add_branch(st, rng, origin, Vector3(cos(angle), rng.randf_range(0.35, 0.8), sin(angle)), rng.randf_range(1.6, 2.6), 0.1, 7.8)


func _build_sparse_tree(st: SurfaceTool, rng: RandomNumberGenerator) -> void:
	var height := 6.4
	var points := _add_trunk(st, rng, height, 0.26, 0.07, Vector3(-0.5, 0.0, 0.4), 4, 4)
	_add_roots(st, rng, 0.3)
	for branch in range(3):
		var origin: Vector3 = points[rng.randi_range(2, points.size() - 1)]
		var angle := rng.randf_range(0.0, TAU)
		var direction := Vector3(cos(angle), rng.randf_range(0.5, 0.9), sin(angle))
		_add_branch(st, rng, origin, direction, rng.randf_range(2.2, 3.6), 0.07, height)


# --- Mesh construction helpers ----------------------------------------------

func _add_trunk(st: SurfaceTool, rng: RandomNumberGenerator, height: float, base_radius: float, tip_radius: float, lean: Vector3, segments: int, sides: int, base := Vector3.ZERO) -> Array[Vector3]:
	var points: Array[Vector3] = [base]
	var position := base
	var step_height := height / float(segments)
	for segment in range(segments):
		var t0 := float(segment) / float(segments)
		var t1 := float(segment + 1) / float(segments)
		var step := Vector3(
			lean.x / float(segments) + rng.randf_range(-0.10, 0.10),
			step_height,
			lean.z / float(segments) + rng.randf_range(-0.10, 0.10)
		)
		var next := position + step
		_add_limb(st, position, next, lerpf(base_radius, tip_radius, t0), lerpf(base_radius, tip_radius, t1), sides, t0, t1)
		points.append(next)
		position = next
	return points


func _add_branch(st: SurfaceTool, rng: RandomNumberGenerator, origin: Vector3, direction: Vector3, length: float, radius: float, tree_height: float, sub_branches := false) -> void:
	var dir := direction.normalized()
	var mid := origin + dir * length * 0.55 + Vector3.UP * length * 0.18
	var tip := mid + (dir + Vector3.UP * rng.randf_range(-0.1, 0.35)).normalized() * length * 0.45 + Vector3.DOWN * rng.randf_range(0.0, 0.55)
	var mid_height := clampf(mid.y / tree_height, 0.0, 1.0)
	var tip_height := clampf(tip.y / tree_height, 0.0, 1.0)
	var origin_height := clampf(origin.y / tree_height, 0.0, 1.0)
	_add_limb(st, origin, mid, radius, radius * 0.6, 4, origin_height, mid_height)
	_add_limb(st, mid, tip, radius * 0.6, 0.015, 4, mid_height, tip_height)
	if sub_branches and rng.randf() < 0.6:
		var angle := rng.randf_range(0.0, TAU)
		var sub_dir := Vector3(cos(angle), rng.randf_range(0.3, 0.8), sin(angle))
		var sub_tip := mid + sub_dir.normalized() * length * 0.55
		_add_limb(st, mid, sub_tip, radius * 0.45, 0.012, 4, mid_height, clampf(sub_tip.y / tree_height, 0.0, 1.0))


func _add_roots(st: SurfaceTool, rng: RandomNumberGenerator, radius: float) -> void:
	for root in range(4):
		var angle := TAU * float(root) / 4.0 + rng.randf_range(-0.3, 0.3)
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		var start := direction * radius * 0.35 + Vector3.UP * 0.65
		var end := direction * radius * rng.randf_range(1.5, 2.0) + Vector3(0.0, 0.05, 0.0)
		_add_limb(st, start, end, radius * 0.42, 0.02, 4, 0.1, 0.0)


func _add_limb(st: SurfaceTool, from: Vector3, to: Vector3, radius_from: float, radius_to: float, sides: int, height_from: float, height_to: float) -> void:
	var axis := (to - from)
	if axis.length_squared() < 0.000001:
		return
	axis = axis.normalized()
	var reference := Vector3.UP if absf(axis.y) < 0.92 else Vector3.RIGHT
	var side := axis.cross(reference).normalized()
	var forward := axis.cross(side).normalized()
	var from_ring: Array[Vector3] = []
	var to_ring: Array[Vector3] = []
	for index in range(sides):
		var angle := TAU * float(index) / float(sides)
		var offset := side * cos(angle) + forward * sin(angle)
		from_ring.append(from + offset * radius_from)
		to_ring.append(to + offset * radius_to)
	var from_color := _bark_color(height_from)
	var to_color := _bark_color(height_to)
	for index in range(sides):
		var next := (index + 1) % sides
		_add_triangle(st, from_ring[index], to_ring[index], to_ring[next], from_color, to_color, to_color)
		_add_triangle(st, from_ring[index], to_ring[next], from_ring[next], from_color, to_color, from_color)
	var center_color := _bark_color(height_to)
	for index in range(sides):
		var next := (index + 1) % sides
		_add_triangle(st, to, to_ring[next], to_ring[index], center_color, to_color, to_color)


func _add_triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, color_a: Color, color_b: Color, color_c: Color) -> void:
	var normal := (b - a).cross(c - a)
	if normal.length_squared() > 0.000001:
		normal = normal.normalized()
	st.set_normal(normal)
	st.set_color(color_a)
	st.add_vertex(a)
	st.set_normal(normal)
	st.set_color(color_b)
	st.add_vertex(b)
	st.set_normal(normal)
	st.set_color(color_c)
	st.add_vertex(c)


func _bark_color(height: float) -> Color:
	var color := BARK_DARK.lerp(BARK_LIGHT, clampf(height, 0.0, 1.0))
	color.a = clampf(height, 0.0, 1.0)
	return color


# --- Ground cover -----------------------------------------------------------

func _build_grass_mesh() -> ArrayMesh:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7717
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var blade_count := 4
	var height_range := Vector2(0.04, 0.11)
	for blade in range(blade_count):
		var angle := rng.randf_range(0.0, TAU)
		var spread := rng.randf_range(0.0, 0.10)
		var base := Vector3(cos(angle) * spread, 0.0, sin(angle) * spread)
		var direction := Vector3(cos(angle + rng.randf_range(-0.5, 0.5)), 0.0, sin(angle + rng.randf_range(-0.5, 0.5)))
		var width := rng.randf_range(0.018, 0.04)
		var height := rng.randf_range(height_range.x, height_range.y)
		var bend := rng.randf_range(0.08, 0.28) * height
		_add_blade(st, base, direction, width, height, bend, GRASS_DARK, GRASS_LIGHT)
	return st.commit()


func _add_blade(st: SurfaceTool, base: Vector3, direction: Vector3, width: float, height: float, bend: float, dark: Color, light: Color) -> void:
	var across := Vector3(-direction.z, 0.0, direction.x) * width
	var mid := base + Vector3.UP * height * 0.55 + direction * bend * 0.5
	var tip := base + Vector3.UP * height + direction * bend
	var bottom_a := base - across
	var bottom_b := base + across
	var mid_a := mid - across * 0.6
	var mid_b := mid + across * 0.6
	var bottom_color := dark
	bottom_color.a = 0.0
	var mid_color := dark.lerp(light, 0.55)
	mid_color.a = 0.55
	var tip_color := light
	tip_color.a = 1.0
	_grass_triangle(st, bottom_a, bottom_color, mid_a, mid_color, mid_b, mid_color)
	_grass_triangle(st, bottom_a, bottom_color, mid_b, mid_color, bottom_b, bottom_color)
	_grass_triangle(st, mid_a, mid_color, tip, tip_color, mid_b, mid_color)


func _grass_triangle(st: SurfaceTool, a: Vector3, color_a: Color, b: Vector3, color_b: Color, c: Vector3, color_c: Color) -> void:
	st.set_normal(Vector3.UP)
	st.set_color(color_a)
	st.add_vertex(a)
	st.set_normal(Vector3.UP)
	st.set_color(color_b)
	st.add_vertex(b)
	st.set_normal(Vector3.UP)
	st.set_color(color_c)
	st.add_vertex(c)


func _make_cover_instance(node_name: String, mesh: ArrayMesh, wind: float) -> MultiMeshInstance3D:
	var material := _make_material(wind)
	material.set_shader_parameter("ground_cover", 1.0)
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	var instance := MultiMeshInstance3D.new()
	instance.name = node_name
	instance.multimesh = multimesh
	instance.material_override = material
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# No visibility range: one MultiMesh covers the whole map, and range
	# culling is measured from the world-centred AABB, which would hide every
	# instance as soon as the camera left the map centre.
	instance.custom_aabb = AABB(Vector3(-8.0, -8.0, -8.0), Vector3(144.0, 96.0, 144.0))
	add_child(instance)
	return instance


func _make_material(wind: float) -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = VEGETATION_SHADER
	material.set_shader_parameter("wind_strength", wind)
	material.set_shader_parameter("wind_speed", 1.7)
	material.set_shader_parameter("sky_tint", Vector3(0.74, 0.84, 1.0))
	material.set_shader_parameter("sun_strength", 0.0)
	material.set_shader_parameter("ambient_sky_level", 0.0)
	materials.append(material)
	return material


func _build_ground_cover(heights: PackedInt32Array, world_seed: int, biome_map: PackedByteArray = PackedByteArray()) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = world_seed ^ 0x51A5
	var grass_transforms: Array[Transform3D] = []
	for z in range(1, 127, GRASS_CELL):
		for x in range(1, 127, GRASS_CELL):
			if absi(x - 64) <= 6 and absi(z - 64) <= 6:
				continue
			# Hushwoods floor is bare dark soil; ash grass would break the palette.
			if not biome_map.is_empty() and biome_map[x + z * 128] == 1:
				continue
			if rng.randf() > GRASS_CHANCE:
				continue
			var ground := heights[x + z * 128]
			# Canyon floors stay bare gravel; only dry, flat shelves keep tufts.
			if ground <= CANYON_FLOOR_MAX:
				continue
			if absi(heights[x + 1 + z * 128] - ground) > 1 or absi(heights[x - 1 + z * 128] - ground) > 1:
				continue
			if absi(heights[x + (z + 1) * 128] - ground) > 1 or absi(heights[x + (z - 1) * 128] - ground) > 1:
				continue
			var position := Vector3(float(x) + rng.randf_range(0.15, 0.85), float(ground) + 1.0, float(z) + rng.randf_range(0.15, 0.85))
			var scale_value := rng.randf_range(0.45, 0.85)
			var rotation := rng.randf_range(0.0, TAU)
			var basis := Basis(Vector3.UP, rotation).scaled(Vector3(scale_value, scale_value * rng.randf_range(0.8, 1.3), scale_value))
			grass_transforms.append(Transform3D(basis, position))
	_fill_cover(grass_instance, grass_transforms)
	grass_count = grass_transforms.size()


func _fill_cover(instance: MultiMeshInstance3D, transforms: Array[Transform3D]) -> void:
	var multimesh := instance.multimesh
	multimesh.instance_count = transforms.size()
	for index in range(transforms.size()):
		multimesh.set_instance_transform(index, transforms[index])
