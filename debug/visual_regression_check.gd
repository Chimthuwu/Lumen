extends SceneTree

# Regression audit for the look of three systems that were not meant to change:
# the Lumencaster viewmodel, the crystal shard mesh, and HUD status messages.

var main: Node
var failures := 0


func _initialize() -> void:
	main = load("res://scenes/world/main.tscn").instantiate()
	root.add_child(main)
	_run.call_deferred()


func _check(condition: bool, label: String, detail := "") -> void:
	if not condition:
		failures += 1
		push_error("VISUAL REGRESSION FAIL: %s %s" % [label, detail])
		return
	print("VISUAL REGRESSION PASS: %s %s" % [label, detail])


func _run() -> void:
	await process_frame
	var player: VoxelPlayer = main.player
	var viewmodel: LumencasterViewmodel = player.get_node_or_null("Camera3D/Viewmodel") as LumencasterViewmodel
	_check(viewmodel != null, "Lumencaster viewmodel is mounted on the camera")
	if viewmodel != null:
		var body := viewmodel.body_material.albedo_color
		_check(body.r < 0.25 and body.g < 0.25 and body.b < 0.25, "gun body is still the dark blocky receiver", str(body))
		_check(viewmodel.get_node_or_null("FrontPalm") != null, "support hand is still visible")
		_check(viewmodel.get_node_or_null("FrontForearm") != null, "forearm is still visible")
		_check(viewmodel.get_node_or_null("TopPlate") != null, "orange top plate is still present")
		var stripe := viewmodel.indicator_material.albedo_color
		_check(stripe.r > 0.7 and stripe.g > 0.25 and stripe.b < 0.35, "top plate reads orange/amber", str(stripe))
		_check(viewmodel.get_node_or_null("MuzzleCoilA") != null, "orange muzzle rings are still present")
		_check(viewmodel.get_child_count() > 30, "receiver remains chunky and detailed", "nodes=%d" % viewmodel.get_child_count())

	# Crystal shard: build one column and inspect its silhouette.
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var uv2 := PackedVector2Array()
	ChunkMesher._append_crystal(vertices, normals, colors, uv2, Vector3.ZERO, Color(0.22, 0.82, 0.64), 1.0, 1, 0.7, 6)
	_check(vertices.size() >= 240, "crystal draws a tall shard plus base splinters", "vertices=%d" % vertices.size())
	var lowest := INF
	var highest := -INF
	var low_width := 0.0
	var high_width := 0.0
	for vertex in vertices:
		lowest = minf(lowest, vertex.y)
		highest = maxf(highest, vertex.y)
		var radial := Vector2(vertex.x - 0.5, vertex.z - 0.5).length()
		if vertex.y <= 0.25:
			low_width = maxf(low_width, radial)
		if vertex.y >= 4.6:
			high_width = maxf(high_width, radial)
	_check(highest - lowest > 5.5, "crystal is a tall jagged shard", "height=%.2f" % (highest - lowest))
	_check(low_width > 0.10 and high_width < low_width * 0.85, "crystal tapers to a sharp tip", "base=%.3f tip=%.3f" % [low_width, high_width])

	# HUD status: plain bright text, never a black box.
	var hud: GameHUD = main.get_node("HUD") as GameHUD
	var caster: Lumencaster = player.get_node("Lumencaster") as Lumencaster
	caster.status_message = "PHOTON BEAM HIT"
	caster.status_time = 2.0
	hud._update_status()
	_check(hud.status_label.visible, "status message becomes visible")
	_check(hud.status_label.text == "PHOTON BEAM HIT", "status text is readable", hud.status_label.text)
	var font_color := hud.status_label.get_theme_color("font_color")
	_check(font_color.a > 0.5 and font_color.get_luminance() > 0.25, "status text is bright, not a black box", str(font_color))
	_check(hud.status_label.get_parent() == hud, "status has no opaque background panel")
	_check(hud.status_label.get_theme_stylebox("normal") == null or hud.status_label.get_theme_stylebox("normal") is StyleBoxEmpty, "status label has no filled style box")
	var hint_style := hud.hint_panel.get_theme_stylebox("panel") as StyleBoxFlat
	_check(hint_style != null and hint_style.bg_color.a < 1.0, "context hint panel stays translucent", str(hint_style.bg_color) if hint_style != null else "missing")

	if failures > 0:
		quit(1)
		return
	print("VISUAL REGRESSION CHECK PASS: gun, crystals and HUD unchanged")
	quit(0)
