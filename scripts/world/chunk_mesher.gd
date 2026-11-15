extends RefCounted
class_name ChunkMesher

const CHUNK_SIZE := 16
const PADDED_SIZE := 18
const FACE_DIRECTIONS := [
	Vector3i(1, 0, 0), Vector3i(-1, 0, 0),
	Vector3i(0, 1, 0), Vector3i(0, -1, 0),
	Vector3i(0, 0, 1), Vector3i(0, 0, -1)
]
const FACE_NORMALS := [
	Vector3.RIGHT, Vector3.LEFT, Vector3.UP,
	Vector3.DOWN, Vector3.BACK, Vector3.FORWARD
]
const FACE_CORNERS := [
	[Vector3(1, 0, 0), Vector3(1, 1, 0), Vector3(1, 1, 1), Vector3(1, 0, 1)],
	[Vector3(0, 0, 1), Vector3(0, 1, 1), Vector3(0, 1, 0), Vector3(0, 0, 0)],
	[Vector3(0, 1, 1), Vector3(1, 1, 1), Vector3(1, 1, 0), Vector3(0, 1, 0)],
	[Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1)],
	[Vector3(1, 0, 1), Vector3(1, 1, 1), Vector3(0, 1, 1), Vector3(0, 0, 1)],
	[Vector3(0, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0), Vector3(1, 0, 0)]
]

static func build(snapshot: PackedByteArray, light_snapshot: PackedByteArray, palette: PackedColorArray, air_id: int) -> Dictionary:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	for z in range(CHUNK_SIZE):
		for y in range(CHUNK_SIZE):
			for x in range(CHUNK_SIZE):
				var cell_index := (x + 1) + (y + 1) * PADDED_SIZE + (z + 1) * PADDED_SIZE * PADDED_SIZE
				var block_id := int(snapshot[cell_index])
				if block_id == air_id:
					continue
				for face in range(6):
					var direction: Vector3i = FACE_DIRECTIONS[face]
					var neighbor_index := cell_index + direction.x + direction.y * PADDED_SIZE + direction.z * PADDED_SIZE * PADDED_SIZE
					if snapshot[neighbor_index] != air_id:
						continue
					var face_light := maxi(int(light_snapshot[cell_index]), int(light_snapshot[neighbor_index]))
					var face_color: Color = palette[block_id]
					face_color.a = float(face_light) / 15.0
					_append_face(vertices, normals, colors, Vector3i(x, y, z), face, face_color)
	return {"vertices": vertices, "normals": normals, "colors": colors}

static func _append_face(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, cell: Vector3i, face: int, color: Color) -> void:
	var corners: Array = FACE_CORNERS[face]
	for corner_index in [0, 1, 2, 0, 2, 3]:
		vertices.append(Vector3(cell) + corners[corner_index])
		normals.append(FACE_NORMALS[face])
		colors.append(color)
