class_name BlockLightDef
extends Resource

@export var block_id: StringName
@export_range(1, 15, 1) var attenuation: int = 1
@export var albedo: Color = Color.WHITE
