extends LampEater
class_name BogCrawler

# The Mire variant of the Lamp Eater: the same lantern-hunting brain, but the
# stilt-legged silhouette is crushed down into a flat carapace that scuttles
# across the mud. Physically it slips through gaps a standing LampEater could
# not, and visually it never rises above the fog line.

const BOG_SHELL := Color(0.16, 0.26, 0.10)
const BOG_RIM := Color(0.42, 0.55, 0.22)
const SQUASH_Y := 0.42
const SPREAD := Vector3(1.18, 1.0, 1.10)


func _init() -> void:
	# Small enough to squeeze under one-block ledges while chasing a torch.
	body_half_extents = Vector3(0.34, 0.28, 0.34)


func _create_placeholder_mesh() -> void:
	super._create_placeholder_mesh()
	for child in get_children():
		if not child is MeshInstance3D:
			continue
		child.position = Vector3(child.position.x * SPREAD.x, child.position.y * SQUASH_Y + 0.16, child.position.z * SPREAD.z)
		child.scale = Vector3(SPREAD.x, SQUASH_Y + 0.5, SPREAD.z)
		var material := child.material_override as StandardMaterial3D
		if material == null:
			continue
		if material.emission_energy_multiplier >= 3.0:
			# The lantern glow turns sickly swamp-green.
			material.emission = Color(0.35, 0.75, 0.18)
			material.albedo_color = Color(0.85, 1.0, 0.35)
		else:
			material.albedo_color = material.albedo_color.lerp(BOG_SHELL, 0.55)
			if material.emission_enabled:
				material.emission = material.emission.lerp(BOG_RIM.darkened(0.5), 0.45)
