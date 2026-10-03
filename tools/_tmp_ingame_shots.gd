extends Node
## 临时截图（验证后删除）：武器握持姿态 / 人机外观（手工搭 rig，相机完全可控）。
## 运行：xvfb-run -a godot --path . res://tools/_tmp_ingame_shots.tscn --rendering-driver opengl3

const OUT_DIR := "/tmp/ingame_shots"

var _cam: Camera3D

func _ready() -> void:
	_run()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_setup_env()
	_cam = Camera3D.new()
	_cam.current = true
	add_child(_cam)

	# 角色 rig：MikuModel + 四个武器（与 player.tscn 结构一致）
	# 注意：先把整棵子树搭好再进场，否则 MikuModel._ready 找不到 Placeholder / WeaponMount
	var rig := Node3D.new()
	rig.name = "PlayerRig"
	var model := Node3D.new()
	model.name = "MikuModel"
	model.set_script(load("res://scripts/entities/miku_model.gd"))
	model.position = Vector3(0, 0.9, 0)
	rig.add_child(model)
	var capsule := MeshInstance3D.new()
	capsule.name = "Placeholder"
	var cap_mesh := CapsuleMesh.new()
	cap_mesh.radius = 0.4
	cap_mesh.height = 1.8
	capsule.mesh = cap_mesh
	model.add_child(capsule)
	var mount := Node3D.new()
	mount.name = "WeaponMount"
	mount.position = Vector3(0.24, 0.32, 0.28)
	model.add_child(mount)
	var weapons := {}
	for entry in [["Rifle", "res://scenes/weapons/rifle.tscn"], ["USP", "res://scenes/weapons/usp.tscn"],
			["Knife", "res://scenes/weapons/knife.tscn"], ["Grenade", "res://scenes/weapons/grenade.tscn"]]:
		var inst := (load(entry[1]) as PackedScene).instantiate() as Node3D
		inst.name = entry[0]
		inst.visible = false
		inst.set_process(false)
		inst.set_physics_process(false)
		mount.add_child(inst)
		weapons[entry[0]] = inst
	add_child(rig)
	for i in 20:
		await get_tree().process_frame
	await _wait(1.0)
	print("[dbg] model_loaded=", model.get("model_loaded"), " placeholder_visible=", capsule.visible)
	for c in model.get_children():
		if c is Node3D:
			print("[dbg] child %s visible=%s pos=%s scale=%s" % [c.name, c.visible, c.position, c.scale])

	# 角色朝向：+Z 侧 / -Z 侧各来一张（判断模型正面）
	_aim(Vector3(0, 1.15, 0) + Vector3(0.9, 0.35, 2.2), Vector3(0, 1.05, 0))
	await _capture("char_front_z_plus")
	_aim(Vector3(0, 1.15, 0) + Vector3(0.9, 0.35, -2.2), Vector3(0, 1.05, 0))
	await _capture("char_front_z_minus")

	# 每个武器：切可见 + 右侧近景 / 背后视角
	for key in weapons:
		for other in weapons:
			weapons[other].visible = other == key
		await _wait(0.2)
		var focus := Vector3(0, 1.15, 0)
		var right := Vector3.RIGHT
		var front := Vector3.BACK # 约定正面
		_aim(focus + front * 0.9 + right * 1.1 + Vector3(0, 0.25, 0), focus + front * 0.3 + right * 0.4)
		await _capture("%s_right" % key)
		_aim(focus - front * 2.2 + right * 0.8 + Vector3(0, 0.45, 0), focus + front * 0.3)
		await _capture("%s_back" % key)
	for other in weapons:
		weapons[other].visible = other == "Rifle"

	# 人机外观（初音模型），并排站位、进场后立刻关物理
	var bot_spots := [
		["miku_navy", "res://assets/models/miku_navy/miku_navy.glb", Vector3(-0.9, 0, 0)],
		["miku_maid", "res://assets/models/miku_maid/miku_maid.glb", Vector3(0.9, 0, 0)],
	]
	var bots: Array[Node3D] = []
	for entry in bot_spots:
		var bot := (load("res://scenes/bot.tscn") as PackedScene).instantiate() as Node3D
		bot.set("model_path", entry[1])
		add_child(bot)
		await get_tree().process_frame
		bot.set_physics_process(false)
		bot.set_process(false)
		bot.global_position = entry[2]
		bots.append(bot)
	await _wait(1.0)
	print("[dbg] 人机位置：", bots[0].global_position, " / ", bots[1].global_position)
	for b in bots:
		var mm := b.get_node_or_null("MikuModel")
		print("[dbg] 人机 MikuModel 子节点（loaded=%s）：" % mm.get("model_loaded"))
		for c in mm.get_children():
			if c is Node3D:
				print("[dbg]    %s visible=%s scale=%s" % [c.name, c.visible, c.scale])
	rig.visible = false # 人机截图时先把玩家藏起来，避免混在一起
	_aim(Vector3(0, 1.5, 4.0), Vector3(0, 0.95, 0))
	await _capture("bots_miku")
	_aim(Vector3(1.9, 1.6, 2.4), Vector3(0.9, 1.0, 0))
	await _capture("bot_maid_close")
	_aim(Vector3(-1.9, 1.6, 2.4), Vector3(-0.9, 1.0, 0))
	await _capture("bot_navy_close")

	print("[shot] 全部完成")
	get_tree().quit()

func _setup_env() -> void:
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.16, 0.19, 0.24)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.75, 0.8, 0.85)
	e.ambient_light_energy = 1.1
	env.environment = e
	add_child(env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -35, 0)
	light.light_energy = 1.7
	add_child(light)
	var floor_mesh := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(20, 20)
	floor_mesh.mesh = plane
	add_child(floor_mesh)

func _aim(from: Vector3, to: Vector3) -> void:
	_cam.global_position = from
	_cam.look_at(to, Vector3.UP)
	_cam.make_current()

func _capture(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [OUT_DIR, tag]
	img.save_png(path)
	print("[shot] 已保存 ", path)

func _wait(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame