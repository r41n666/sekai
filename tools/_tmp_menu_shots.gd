extends Node
## 临时截图（验证后删除）：Esc 菜单（角色列表 + 武器皮肤 + 3D 检视）。
## 运行：xvfb-run -a /tmp/godotbin/Godot_v4.7.2-stable_linux.x86_64 --path . res://tools/_tmp_menu_shots.tscn --rendering-driver opengl3

const OUT_DIR := "/tmp/menu_shots"

var _menu: GameMenu


func _ready() -> void:
	_run()


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var main := (load("res://scenes/main.tscn") as PackedScene).instantiate()
	add_child(main)
	await _wait(1.5)
	for ui in get_tree().get_nodes_in_group("game_ui"):
		if ui is GameMenu:
			_menu = ui
	if _menu == null:
		print("[menu] 找不到 GameMenu")
		get_tree().quit(1)
		return
	_menu.open_ui()
	await _wait(0.8)
	await _capture("menu_default")
	print("[menu] 打开菜单，预览节点=%s" % _menu.get_node("Panel/HBox/RightVBox/Preview").get_child_count())

	_menu._select_skin("gamma_doppler")
	await _wait(0.6)
	await _capture("menu_rifle_gamma")

	# 固定角度对比：默认 vs 伽玛多普勒（排查「预览像一条细线」是不是只是角度太偏）
	var pivot: Node3D = _menu.get_node("Panel/HBox/RightVBox/Preview")._pivot
	pivot.rotation.y = deg_to_rad(150.0)
	_menu._select_skin("")
	await _wait(0.3)
	await _capture("menu_rifle_angle_default")
	_menu._select_skin("gamma_doppler")
	await _wait(0.3)
	pivot.rotation.y = deg_to_rad(150.0)
	await _capture("menu_rifle_angle_gamma")

	_menu._select_slot("Knife")
	await _wait(0.6)
	await _capture("menu_knife_gamma")

	_menu._select_skin("fade")
	await _wait(0.6)
	await _capture("menu_knife_fade")

	_menu._select_slot("Grenade")
	await _wait(0.6)
	await _capture("menu_grenade_blue")
	_menu._select_skin("blue_steel")
	await _wait(0.6)
	await _capture("menu_grenade_bluesteel")

	# 关掉菜单，看手上的武器是不是也换上了皮肤（第三人称）
	_menu.close_ui()
	await _wait(0.8)
	await _capture("ingame_after_skin")
	print("[menu] 完成")
	get_tree().quit()


func _capture(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [OUT_DIR, tag])


func _wait(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame