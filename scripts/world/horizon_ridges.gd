extends Node3D
class_name HorizonRidges

const RIDGE_SHADER := preload("res://shaders/horizon_ridge.gdshader")
const SEGMENTS := 160
const CENTER := Vector2(64.0, 64.0)
const DISK_INNER := 96.0
const DISK_OUTER := 340.0

# Three stacked silhouettes: the nearer ridge is darker and more detailed, the
# farther ones climb higher and wash toward the sky so the horizon has depth.
const LAYERS := [
	{"radius": 120.0, "base": 18.0, "amps": Vector3(9.0, 4.0, 3.0), "phase": 0.7},
	{"radius": 152.0, "base": 27.0, "amps": Vector3(13.0, 5.0, 3.6), "phase": 2.3},
	{"radius": 196.0, "base": 36.0, "amps": Vector3(17.0, 6.5, 4.2), "phase": 4.9},
]

var materials: Array[ShaderMaterial] = []
var haze_material: ShaderMaterial
var world_seed := 0


func build(seed_value: int) -> void:
	world_seed = seed_value
	for layer_index in range(LAYERS.size()):
		var layer: Dictionary = LAYERS[layer_index]
		var material := ShaderMaterial.new()
		material.shader = RIDGE_SHADER
		materials.append(material)

		var instance := MeshInstance3D.new()
		instance.name = "Ridge_%d" % layer_index
		instance.mesh = _build_ring(layer, layer_index)
		instance.material_override = material
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(instance)

	haze_material = ShaderMaterial.new()
	haze_material.shader = RIDGE_SHADER
	var haze := MeshInstance3D.new()
	haze.name = "HorizonHaze"
	haze.mesh = _build_haze_disk()
	haze.material_override = haze_material
	haze.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(haze)


func set_atmosphere(top_color: Color, horizon_color: Color, daylight: float, twilight: float) -> void:
	var night_ridge := Color(0.04, 0.05, 0.09)
	for layer_index in range(materials.size()):
		var day_ridge := Color(0.15, 0.17, 0.22).lerp(top_color, 0.08 + 0.05 * float(layer_index))
		var ridge := night_ridge.lerp(day_ridge, daylight)
		# Twilight warms the nearest silhouette, the way low sun catches a range.
		ridge = ridge.lerp(horizon_color, twilight * 0.20)
		materials[layer_index].set_shader_parameter("ridge_color", ridge)
		materials[layer_index].set_shader_parameter("haze_color", horizon_color)
		materials[layer_index].set_shader_parameter("haze_strength", 0.66 - 0.10 * float(layer_index))
	if haze_material != null:
		var haze_tint := horizon_color.darkened(0.10)
		haze_material.set_shader_parameter("ridge_color", haze_tint)
		haze_material.set_shader_parameter("haze_color", haze_tint)
		haze_material.set_shader_parameter("haze_strength", 1.0)


func _build_ring(layer: Dictionary, layer_index: int) -> ArrayMesh:
	var radius: float = layer["radius"]
	var base_height: float = layer["base"]
	var amps: Vector3 = layer["amps"]
	var phase: float = layer["phase"] + float(world_seed % 997) * 0.013
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for segment in range(SEGMENTS):
		var angle_a := TAU * float(segment) / float(SEGMENTS)
		var angle_b := TAU * float(segment + 1) / float(SEGMENTS)
		# Lower rings get more small-scale teeth; far rings read as broad masses.
		var detail := 1.0 - float(layer_index) * 0.25
		var peak_a := _ridge_height(angle_a, base_height, amps, phase, detail)
		var peak_b := _ridge_height(angle_b, base_height, amps, phase, detail)
		var a_low := _ring_point(angle_a, radius, 0.0)
		var a_high := _ring_point(angle_a, radius, peak_a)
		var b_low := _ring_point(angle_b, radius, 0.0)
		var b_high := _ring_point(angle_b, radius, peak_b)
		# Vertex color: 0 at the foot, 1 at the crest.
		surface.set_color(Color(0.0, 0.0, 0.0))
		surface.add_vertex(a_low)
		surface.set_color(Color(1.0, 1.0, 1.0))
		surface.add_vertex(a_high)
		surface.set_color(Color(1.0, 1.0, 1.0))
		surface.add_vertex(b_high)
		surface.set_color(Color(0.0, 0.0, 0.0))
		surface.add_vertex(a_low)
		surface.set_color(Color(1.0, 1.0, 1.0))
		surface.add_vertex(b_high)
		surface.set_color(Color(0.0, 0.0, 0.0))
		surface.add_vertex(b_low)
	return surface.commit()


func _ridge_height(angle: float, base_height: float, amps: Vector3, phase: float, detail: float) -> float:
	var broad := sin(angle * 3.0 + phase) * amps.x
	var mid := sin(angle * 7.0 + phase * 1.7) * amps.y
	var fine := sin(angle * 19.0 + phase * 0.6) * amps.z * detail
	var teeth := sin(angle * 47.0 + phase * 2.3) * amps.z * 0.35 * detail
	return maxf(base_height * 0.35, base_height + broad + mid + fine + teeth)


func _ring_point(angle: float, radius: float, y: float) -> Vector3:
	return Vector3(CENTER.x + cos(angle) * radius, y, CENTER.y + sin(angle) * radius)


func _build_haze_disk() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	for segment in range(SEGMENTS):
		var angle_a := TAU * float(segment) / float(SEGMENTS)
		var angle_b := TAU * float(segment + 1) / float(SEGMENTS)
		var inner_a := Vector3(CENTER.x + cos(angle_a) * DISK_INNER, 0.0, CENTER.y + sin(angle_a) * DISK_INNER)
		var inner_b := Vector3(CENTER.x + cos(angle_b) * DISK_INNER, 0.0, CENTER.y + sin(angle_b) * DISK_INNER)
		var outer_a := Vector3(CENTER.x + cos(angle_a) * DISK_OUTER, 0.0, CENTER.y + sin(angle_a) * DISK_OUTER)
		var outer_b := Vector3(CENTER.x + cos(angle_b) * DISK_OUTER, 0.0, CENTER.y + sin(angle_b) * DISK_OUTER)
		for point in [inner_a, outer_a, outer_b, inner_a, outer_b, inner_b]:
			surface.set_color(Color(0.0, 0.0, 0.0))
			surface.add_vertex(point)
	return surface.commit()
