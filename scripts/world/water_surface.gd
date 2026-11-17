extends Node3D
class_name ToxicWater

# Flat translucent water plane for The Mire. Rebuilt per loaded region instead
# of per block type, which keeps the chunk mesher untouched.

const WATER_LEVEL := BiomeManager.WATER_LEVEL

var mesh_instance: MeshInstance3D
var material: StandardMaterial3D
var region_center := Vector2i(1 << 30, 1 << 30)
var region_radius := 0


func _ready() -> void:
	material = StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color(0.16, 0.36, 0.24, 0.58)
	material.cull_mode = BaseMaterial3D.CULL_DISABLED
	mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "ToxicWaterSurface"
	mesh_instance.material_override = material
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh_instance)


func clear() -> void:
	region_center = Vector2i(1 << 30, 1 << 30)
	region_radius = 0
	if mesh_instance != null:
		mesh_instance.mesh = null
		mesh_instance.visible = false


func update_region(center: Vector2i, radius: int) -> void:
	if center == region_center and radius == region_radius and mesh_instance.mesh != null:
		return
	region_center = center
	region_radius = radius
	if mesh_instance == null:
		return
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var y := float(WATER_LEVEL + 1)
	var quads := 0
	for z in range(center.y * 16 - radius, center.y * 16 + radius):
		for x in range(center.x * 16 - radius, center.x * 16 + radius):
			if not BiomeManager.is_mire_water(x, z):
				continue
			var offset := Vector3(float(x), 0.0, float(z))
			var a := offset + Vector3(0.0, y, 0.0)
			var b := offset + Vector3(1.0, y, 0.0)
			var c := offset + Vector3(1.0, y, 1.0)
			var d := offset + Vector3(0.0, y, 1.0)
			for point in [a, b, c, a, c, d]:
				surface.add_vertex(point)
			quads += 1
	mesh_instance.mesh = surface.commit() if quads > 0 else null
	mesh_instance.visible = quads > 0
