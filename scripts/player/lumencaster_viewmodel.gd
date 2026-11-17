extends Node3D
class_name LumencasterViewmodel

const CONFIG: LumencasterConfig = preload("res://data/cartridges/lumencaster_config.tres")
const SEGMENT_COUNT := 6

@onready var world: VoxelWorld = owner.get_node_or_null("VoxelWorld") as VoxelWorld

var caster: Lumencaster
var body_material: StandardMaterial3D
var segment_materials: Array[StandardMaterial3D] = []
var muzzle_flash: MeshInstance3D
var flash_material: StandardMaterial3D
var indicator_material: StandardMaterial3D
var cartridge_stripe: MeshInstance3D
var muzzle_ring: MeshInstance3D
var base_position := Vector3.ZERO
var base_rotation := Vector3.ZERO
var recoil := 0.0
var flash_time := 0.0


func _ready() -> void:
	base_position = position
	base_rotation = rotation
	caster = get_parent().get_parent().get_node_or_null("Lumencaster") as Lumencaster
	if caster != null:
		caster.fired.connect(_on_fired)
		caster.cartridge_changed.connect(_on_cartridge_changed)
		caster.projector_toggled.connect(_on_projector_toggled)
	_build_model()
	if caster != null:
		_apply_cartridge(caster.CARTRIDGES[caster.selected_cartridge], caster.projector_mode)


func _build_model() -> void:
	body_material = _make_material(Color(0.045, 0.050, 0.058))
	var dark := _make_material(Color(0.022, 0.025, 0.031))
	var mid := _make_material(Color(0.11, 0.12, 0.14))
	var glove := _make_material(Color(0.30, 0.35, 0.40))
	glove.roughness = 0.85
	glove.metallic = 0.0
	glove.emission = Color(0.30, 0.35, 0.40) * 0.35
	var glove_light := _make_material(Color(0.41, 0.47, 0.52))
	glove_light.roughness = 0.85
	glove_light.metallic = 0.0
	glove_light.emission = Color(0.41, 0.47, 0.52) * 0.4
	var glove_cuff := _make_material(Color(0.16, 0.19, 0.22))
	glove_cuff.roughness = 0.7
	var sight_metal := _make_material(Color(0.085, 0.095, 0.110))
	sight_metal.roughness = 0.30
	sight_metal.metallic = 0.55
	sight_metal.emission = Color(0.085, 0.095, 0.110) * 0.5

	# Compact receiver with a rounded top cover so it reads less boxy.
	_add_box("Receiver", Vector3(0.150, 0.115, 0.400), Vector3(0, -0.020, -0.040), body_material)
	_add_cylinder("ReceiverTop", 0.060, 0.400, Vector3(0, 0.018, -0.040), body_material, Vector3(PI * 0.5, 0, 0))
	_add_box("LowerReceiver", Vector3(0.118, 0.055, 0.210), Vector3(0, -0.090, 0.000), dark)
	_add_box("SidePlateLeft", Vector3(0.008, 0.060, 0.230), Vector3(-0.075, -0.018, -0.040), mid)
	_add_box("RearCap", Vector3(0.138, 0.120, 0.045), Vector3(0, -0.020, 0.170), dark)
	_add_box("Stock", Vector3(0.136, 0.132, 0.140), Vector3(0, -0.026, 0.225), body_material, Vector3(0.06, 0, 0))
	_add_box("CheekRest", Vector3(0.112, 0.042, 0.170), Vector3(0, 0.048, 0.205), mid, Vector3(0.05, 0, 0))
	_add_cylinder("ButtPad", 0.085, 0.145, Vector3(0, -0.028, 0.298), dark, Vector3(0, 0, PI * 0.5))

	# Thin orange line along the spine, like the reference rifle.
	indicator_material = _make_indicator_material()
	_add_box("TopHousing", Vector3(0.046, 0.010, 0.260), Vector3(0, 0.073, -0.200), dark)
	cartridge_stripe = _add_box("TopPlate", Vector3(0.014, 0.005, 0.790), Vector3(0, 0.080, -0.230), indicator_material)

	# Rotund handguard and barrel, shorter than the old long rifle.
	_add_cylinder("Handguard", 0.058, 0.200, Vector3(0, 0.012, -0.370), mid, Vector3(PI * 0.5, 0, 0))
	_add_box("HandguardRail", Vector3(0.070, 0.020, 0.180), Vector3(0, 0.058, -0.370), dark)
	_add_cylinder("Barrel", 0.030, 0.130, Vector3(0, 0.030, -0.535), dark, Vector3(PI * 0.5, 0, 0))
	_add_cylinder("MuzzleBrake", 0.060, 0.080, Vector3(0, 0.030, -0.615), dark, Vector3(PI * 0.5, 0, 0))

	# Orange muzzle rings around a dark bore.
	muzzle_ring = _add_torus("MuzzleCoilA", 0.050, 0.072, Vector3(0, 0.030, -0.658), indicator_material, Vector3(PI * 0.5, 0, 0))
	_add_torus("MuzzleCoilB", 0.040, 0.058, Vector3(0, 0.030, -0.638), indicator_material, Vector3(PI * 0.5, 0, 0))
	_add_cylinder("MuzzleBore", 0.034, 0.012, Vector3(0, 0.030, -0.662), dark, Vector3(PI * 0.5, 0, 0))

	# Grip, trigger and magazine tucked under the receiver.
	_add_box("Grip", Vector3(0.060, 0.150, 0.075), Vector3(0, -0.135, 0.105), dark, Vector3(-0.28, 0, 0))
	_add_box("GripPanel", Vector3(0.066, 0.088, 0.020), Vector3(0, -0.140, 0.064), mid, Vector3(-0.28, 0, 0))
	_add_box("TriggerGuard", Vector3(0.050, 0.012, 0.075), Vector3(0, -0.094, 0.020), dark)
	_add_box("Trigger", Vector3(0.014, 0.038, 0.016), Vector3(0, -0.064, 0.028), mid, Vector3(-0.22, 0, 0))
	_add_box("Magazine", Vector3(0.058, 0.120, 0.085), Vector3(0, -0.148, -0.080), mid, Vector3(0.18, 0, 0))
	_add_box("MagazineCatch", Vector3(0.064, 0.018, 0.094), Vector3(0, -0.085, -0.080), dark, Vector3(0.18, 0, 0))

	# Cyan Lumen panel low on the visible left flank.
	_add_box("BatteryFrame", Vector3(0.018, 0.076, 0.170), Vector3(-0.069, 0.010, -0.235), dark)
	for index in range(SEGMENT_COUNT):
		var material := _make_glow_material()
		segment_materials.append(material)
		_add_box("LumenCell%d" % index, Vector3(0.016, 0.056, 0.022), Vector3(-0.077, 0.010, -0.302 + index * 0.026), material)
	_add_box("BatteryCap", Vector3(0.024, 0.016, 0.175), Vector3(-0.071, 0.048, -0.235), mid)
	_add_box("BatteryGlint", Vector3(0.017, 0.016, 0.020), Vector3(-0.078, 0.034, -0.300), _make_material(Color(0.82, 1.0, 0.94), false))

	# Ring sight: dark gunmetal aperture with a bevel and a lit bead.
	_add_box("SightBase", Vector3(0.030, 0.060, 0.030), Vector3(0, 0.098, -0.200), dark)
	_add_box("SightNeck", Vector3(0.020, 0.034, 0.020), Vector3(0, 0.118, -0.200), mid)
	_add_torus("Sight", 0.036, 0.058, Vector3(0, 0.172, -0.200), sight_metal, Vector3(PI * 0.5, 0, 0))
	_add_torus("SightBevel", 0.030, 0.036, Vector3(0, 0.172, -0.203), mid, Vector3(PI * 0.5, 0, 0))
	_add_sphere("SightBead", 0.008, Vector3(0, 0.228, -0.200), indicator_material)
	_add_box("FrontPost", Vector3(0.010, 0.026, 0.010), Vector3(0, 0.066, -0.560), dark)

	# Rounded support hand and forearm gripping the handguard.
	var palm := _add_sphere("FrontPalm", 0.085, Vector3(0.030, -0.185, -0.285), glove)
	palm.scale = Vector3(1.05, 1.10, 1.30)
	var knuckles := _add_sphere("FrontKnuckles", 0.055, Vector3(-0.030, -0.170, -0.290), glove_light)
	knuckles.scale = Vector3(0.75, 1.0, 1.35)
	var back := _add_sphere("FrontBack", 0.060, Vector3(0.030, -0.165, -0.275), glove_light)
	back.scale = Vector3(0.60, 1.0, 1.20)
	_add_sphere("FrontThumb", 0.030, Vector3(0.045, -0.115, -0.235), glove_light)
	_add_cylinder("FrontWrist", 0.056, 0.130, Vector3(0.075, -0.245, -0.215), glove, Vector3(PI * 0.5 + 0.55, 0, 0.10))
	_add_cylinder("FrontCuff", 0.068, 0.060, Vector3(0.100, -0.300, -0.150), glove_cuff, Vector3(PI * 0.5 + 0.60, 0, 0.12))
	_add_cylinder("FrontForearm", 0.072, 0.320, Vector3(0.130, -0.340, -0.070), glove, Vector3(PI * 0.5 + 0.62, 0, -0.18))

	flash_material = _make_flash_material()
	muzzle_flash = _add_sphere("MuzzleFlash", 0.100, Vector3(0, 0.030, -0.650), flash_material)
	muzzle_flash.visible = false


func _add_torus(node_name: String, inner_radius: float, outer_radius: float, offset: Vector3, material: Material, mesh_rotation := Vector3.ZERO) -> MeshInstance3D:
	var torus := TorusMesh.new()
	torus.inner_radius = inner_radius
	torus.outer_radius = outer_radius
	torus.rings = 24
	torus.ring_segments = 12
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = torus
	instance.material_override = material
	instance.position = offset
	instance.rotation = mesh_rotation
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return instance


func _add_box(node_name: String, size: Vector3, offset: Vector3, material: Material, box_rotation := Vector3.ZERO) -> MeshInstance3D:
	var box := BoxMesh.new()
	box.size = size
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = box
	instance.material_override = material
	instance.position = offset
	instance.rotation = box_rotation
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return instance


func _add_cylinder(node_name: String, radius: float, height: float, offset: Vector3, material: Material, mesh_rotation := Vector3.ZERO) -> MeshInstance3D:
	var cylinder := CylinderMesh.new()
	cylinder.top_radius = radius
	cylinder.bottom_radius = radius
	cylinder.height = height
	cylinder.radial_segments = 16
	cylinder.rings = 1
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = cylinder
	instance.material_override = material
	instance.position = offset
	instance.rotation = mesh_rotation
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return instance


func _add_sphere(node_name: String, radius: float, offset: Vector3, material: Material) -> MeshInstance3D:
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 12
	sphere.rings = 6
	var instance := MeshInstance3D.new()
	instance.name = node_name
	instance.mesh = sphere
	instance.material_override = material
	instance.position = offset
	instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(instance)
	return instance


func _make_material(color: Color, shaded := true) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	if shaded:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
		material.roughness = 0.52
		material.metallic = 0.18
		material.emission_enabled = true
		material.emission = color * 0.25
	else:
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return material


func _make_glow_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(0.05, 0.30, 0.28)
	material.emission_enabled = true
	material.emission = Color(0.25, 1.0, 0.86)
	material.emission_energy_multiplier = 2.5
	return material


func _make_indicator_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.46, 0.07)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.40, 0.04)
	material.emission_energy_multiplier = 0.9
	return material


func _apply_cartridge(cartridge: CartridgeDef, projector: bool) -> void:
	if indicator_material == null:
		return
	var tint := Color(0.15, 0.9, 1.0) if projector else cartridge.accent_color
	indicator_material.albedo_color = tint
	indicator_material.emission = tint
	indicator_material.emission_energy_multiplier = 1.6 if projector else 1.35
	if cartridge_stripe != null:
		cartridge_stripe.visible = not projector
	if muzzle_ring != null:
		muzzle_ring.visible = true
	if flash_material != null:
		flash_material.emission = tint.lerp(Color.WHITE, 0.45)
		flash_material.albedo_color = tint.lerp(Color.WHITE, 0.65)


func _make_flash_material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = Color(1.0, 0.97, 0.80)
	material.emission_enabled = true
	material.emission = Color(1.0, 0.86, 0.48)
	material.emission_energy_multiplier = 9.0
	return material


func _process(delta: float) -> void:
	var ratio := 0.0
	if is_instance_valid(caster):
		ratio = clampf(caster.reserve / CONFIG.reserve_capacity, 0.0, 1.0)
	_update_reserve_cells(ratio)
	_update_body_light()
	recoil = lerpf(recoil, 0.0, 1.0 - exp(-delta * 11.0))
	flash_time = maxf(0.0, flash_time - delta)
	if muzzle_flash != null:
		muzzle_flash.visible = flash_time > 0.0
	var shake := sin(float(Time.get_ticks_msec()) * 0.045) * recoil * 0.02
	position = base_position + Vector3(0.0, recoil * 0.018, recoil * 0.07)
	rotation = base_rotation + Vector3(recoil * 0.22, shake, 0.0)


func _update_reserve_cells(ratio: float) -> void:
	var lit := 0 if ratio <= 0.001 else ceili(ratio * float(SEGMENT_COUNT))
	for index in range(segment_materials.size()):
		var material := segment_materials[index]
		var on := index < lit
		material.albedo_color = Color(0.12, 0.62, 0.56) if on else Color(0.03, 0.07, 0.06)
		material.emission_energy_multiplier = 2.5 if on else 0.0


func _update_body_light() -> void:
	if body_material == null or world == null or not world.is_generated:
		return
	var camera := get_parent() as Camera3D
	if camera == null:
		return
	var cell := Vector3i(floori(camera.global_position.x), floori(camera.global_position.y), floori(camera.global_position.z))
	var light := clampf(maxf(float(world.get_light_level(cell)) / 15.0, world.get_flashlight_level_at(camera.global_position)), 0.0, 1.0)
	body_material.albedo_color = Color(0.035, 0.038, 0.045).lerp(Color(0.16, 0.17, 0.19), light)


func _on_cartridge_changed(_index: int, cartridge: CartridgeDef) -> void:
	_apply_cartridge(cartridge, false)


func _on_projector_toggled(active: bool) -> void:
	if caster == null or indicator_material == null:
		return
	_apply_cartridge(caster.CARTRIDGES[caster.selected_cartridge], active)


func _on_fired(_cartridge_id: StringName, kick: float) -> void:
	recoil = minf(1.25, recoil + kick * 1.25)
	flash_time = 0.07
	if muzzle_flash != null:
		muzzle_flash.scale = Vector3.ONE * randf_range(0.95, 1.35)
