extends Gloomling
class_name FrostStalker

# Frostfall variant of the Gloomling: same dissolve-in-light brain and limb
# silhouette, re-tinted to glacier blue. The director gives it a higher move
# speed from EnemyConfig.

const ICY_FLESH := Color(0.30, 0.42, 0.58)
const ICY_BONE := Color(0.66, 0.80, 0.92)
const ICY_GLOW := Color(0.45, 0.85, 1.0)


func _create_placeholder_mesh() -> void:
	super._create_placeholder_mesh()
	for child in visual_root.get_children():
		if not child is MeshInstance3D:
			continue
		var material := child.material_override as StandardMaterial3D
		if material == null or not material.emission_enabled:
			continue
		if material.emission_energy_multiplier >= 3.0:
			# The red glow parts (eyes, teeth, claws) become icy phosphor.
			material.albedo_color = ICY_GLOW
			material.emission = ICY_GLOW
			material.emission_energy_multiplier = 7.0
		elif material.albedo_color.get_luminance() < 0.15:
			material.albedo_color = material.albedo_color.lerp(ICY_FLESH, 0.65)
			material.emission = material.emission.lerp(ICY_FLESH.darkened(0.4), 0.6)
		else:
			material.albedo_color = material.albedo_color.lerp(ICY_BONE, 0.6)
			material.emission = material.emission.lerp(ICY_FLESH.darkened(0.2), 0.5)


func _on_dissolve() -> void:
	Vfx.burst(get_parent() as Node3D, global_position + Vector3.UP * 0.2, Color(0.20, 0.45, 0.60), Vector3.UP, 18, 1.8, 0.11, 0.75, 0.25)
