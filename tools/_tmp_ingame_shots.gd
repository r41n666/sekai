extends Node
## 临时截图（验证后删除）：武器握持（手骨跟随）/ 第一人称武器 / 各模型面部。
## 运行：xvfb-run -a /tmp/godotbin/Godot_v4.7.2-stable_linux.x86_64 --path . res://tools/_tmp_ingame_shots.tscn --rendering-driver opengl3

const OUT_DIR := "/tmp/ingame_shots"
const MODELS := [
	["miku", "res://assets/models/miku/miku.glb"],
	["navy", "res://assets/models/miku_navy/miku_navy.glb"],
	["maid", "res://assets/models/miku_maid/miku_maid.glb"],
]
const WEAPONS := [
	["Rifle", "res://scenes/weapons/rifle.tscn"],
	["USP", "res://scenes/weapons/usp.tscn"],
	["Knife", "res://scenes/weapons/knife.tscn"],
	["Grenade", "res://scenes/weapons/grenade.tscn"],
]

var _cam: Camera3D
var _model: MikuModel
var _weapons := {}
var _clay: StandardMaterial3D
var _drive_pose := false


func _ready() -> void:
	_run()


func _process(delta: float) -> void:
	# 驱动程序化姿态（游戏里由 player.gd 每帧调），否则模型停在 T-pose
	if _model != null and _drive_pose:
		_model.update_animation(delta, 0.0, 0.0, false, true)


## 取 MikuModel 下加载进来的模型节点（不能按名字找：节点名可能被 Godot 去重成 Miku2）
func _loaded_model_node() -> Node:
	for child in _model.get_children():
		if child.name == "Placeholder" or child.name == "WeaponMount":
			continue
		return child
	return null


## 右手骨骼当前的世界坐标（用于对比 rest / 姿态）
func _hand_position() -> Vector3:
	var loaded := _loaded_model_node()
	var skeleton: Skeleton3D = _model._find_skeleton(loaded) if loaded != null else null
	if skeleton == null:
		return Vector3.ZERO
	var hand := _model._find_hand_bone(skeleton)
	if hand == "":
		return Vector3.ZERO
	var idx := skeleton.find_bone(hand)
	return skeleton.global_transform * skeleton.get_bone_global_pose(idx).origin


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_setup_env()
	_clay = StandardMaterial3D.new()
	_clay.albedo_color = Color(0.82, 0.82, 0.86)
	_clay.roughness = 0.55

	# 角色 rig（与 player.tscn 结构一致：MikuModel + Placeholder + WeaponMount + 四把武器）
	var rig := Node3D.new()
	rig.name = "PlayerRig"
	_model = MikuModel.new()
	_model.name = "MikuModel"
	_model.position = Vector3(0, 0.9, 0)
	rig.add_child(_model)
	var capsule := MeshInstance3D.new()
	capsule.name = "Placeholder"
	var cap_mesh := CapsuleMesh.new()
	cap_mesh.radius = 0.4
	cap_mesh.height = 1.8
	capsule.mesh = cap_mesh
	_model.add_child(capsule)
	var mount := Node3D.new()
	mount.name = "WeaponMount"
	mount.position = Vector3(0.24, 0.32, 0.28)
	_model.add_child(mount)
	for entry in WEAPONS:
		var inst := (load(entry[1]) as PackedScene).instantiate() as Node3D
		inst.name = entry[0]
		inst.visible = false
		inst.set_process(false)
		inst.set_physics_process(false)
		mount.add_child(inst)
		_weapons[entry[0]] = inst
	add_child(rig)

	_cam = Camera3D.new()
	_cam.current = true
	add_child(_cam)

	for i in 20:
		await get_tree().process_frame
	await _wait(0.5)

	for entry in MODELS:
		_drive_pose = false
		var ok: bool = _model.load_model(entry[1])
		_model.set_holding_weapon(true)
		await _wait(0.35) # 先量一次 rest（T-pose）
		var rest_hand := _hand_position()
		_drive_pose = true
		await _wait(0.8) # 再量一次程序化姿态
		var loaded := _loaded_model_node()
		var skeleton: Skeleton3D = _model._find_skeleton(loaded) if loaded != null else null
		var hand := _model._find_hand_bone(skeleton) if skeleton != null else "(无骨架)"
		var mount_node := _model.get_node("WeaponMount") as Node3D
		print("[shot] %s 载入=%s 手骨=%s rest手骨=%s" % [entry[0], ok, hand, rest_hand])
		# 手骨世界坐标 vs 挂点世界坐标（判定握持是否悬空）
		if skeleton != null and hand != "":
			var idx := skeleton.find_bone(hand)
			var hand_world: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(idx).origin
			print("[shot]   手骨位置=%s 武器挂点位置=%s 距离=%.3f" % [
				hand_world, mount_node.global_position, hand_world.distance_to(mount_node.global_position)])
		# 面部特写（彩色，诊断贴图 / 眼睛）+ 全身（看姿态）
		await _shot_face(entry[0])
		_aim(Vector3(1.5, 1.5, 2.3), Vector3(0, 1.0, 0))
		await _capture("%s_body_front" % entry[0])
		_aim(Vector3(2.4, 1.4, 0.2), Vector3(0, 1.0, 0))
		await _capture("%s_body_side" % entry[0])
		# 握持：灰模出图（避免把真实枪械贴图喂给渲染）
		_set_clay(true)
		for weapon_entry in [["Rifle", Vector3(-0.7, 0.45, 0.9)], ["Knife", Vector3(-0.55, 0.3, 0.6)]]:
			for other in _weapons:
				_weapons[other].visible = other == weapon_entry[0]
			await _wait(0.2)
			await _shot_hand(entry[0], weapon_entry[0], weapon_entry[1])
		_set_clay(false)
		print("[shot] %s 拍完" % entry[0])

	# 第一人称：模型隐藏后武器必须贴着相机可见
	_model.load_model(MODELS[0][1])
	await _wait(0.5)
	_model.set_first_person(true)
	_model.view_camera = _cam
	for weapon_entry in [["Rifle", 0.0], ["Knife", 0.0]]:
		for other in _weapons:
			_weapons[other].visible = other == weapon_entry[0]
		_cam.global_position = Vector3(0, 1.6, 0)
		_cam.rotation = Vector3.ZERO
		_cam.make_current()
		await _wait(0.3)
		await _capture("first_person_%s" % weapon_entry[0])
		var gun: Node3D = _weapons[weapon_entry[0]]
		print("[shot] 第一人称 %s：可见=%s 世界坐标=%s" % [
			weapon_entry[0], gun.is_visible_in_tree(), gun.global_position])
	_model.set_first_person(false)
	await _wait(0.3)
	print("[shot] 全部完成")
	get_tree().quit()


func _shot_face(model_tag: String) -> void:
	var head := _model.global_position + Vector3(0, 0.78, 0) # 模型高 1.75，脚在 -0.9
	_aim(head + Vector3(0.06, 0.02, 0.5), head)
	await _capture("%s_face_front" % model_tag)
	_aim(head + Vector3(0.06, 0.02, -0.5), head)
	await _capture("%s_face_back" % model_tag)


func _shot_hand(model_tag: String, weapon_tag: String, offset: Vector3) -> void:
	var mount := _model.get_node("WeaponMount") as Node3D
	var focus: Vector3 = mount.global_position
	_aim(focus + offset, focus)
	await _capture("%s_%s_hand" % [model_tag, weapon_tag])
	_aim(focus + Vector3(-0.5, 0.9, -1.9), focus + Vector3(0, -0.2, 0))
	await _capture("%s_%s_back" % [model_tag, weapon_tag])


func _set_clay(on: bool) -> void:
	for key in _weapons:
		for mesh in _collect_meshes(_weapons[key]):
			mesh.material_override = _clay if on else null


func _collect_meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_collect_meshes(child))
	return out


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
	img.save_png("%s/%s.png" % [OUT_DIR, tag])


func _wait(seconds: float) -> void:
	var until := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < until:
		await get_tree().process_frame