extends Node3D
class_name VoxelChunk

var mesh_instance: MeshInstance3D
var chunk_coords := Vector3i.ZERO


func configure(coords: Vector3i, origin: Vector3, material: Material) -> void:
	chunk_coords = coords
	position = origin
	mesh_instance = MeshInstance3D.new()
	mesh_instance.name = "Mesh"
	mesh_instance.material_override = material
	# Terrain receives the directional shadow map but must not cast into it:
	# self-shadowing a heightfield made of unshaded cubes produces acne bands.		mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mesh_instance)
	# No per-chunk physics body: the player, buggy and enemies all resolve the
	# voxel grid through VoxelWorld.is_solid(). Cooking a ConcavePolygonShape3D
	# for every 16^3 chunk was the largest main-thread cost in streaming.


func install_geometry(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, uv2: PackedVector2Array) -> void:
	if vertices.is_empty():
		mesh_instance.mesh = null
		return
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh_instance.mesh = mesh
