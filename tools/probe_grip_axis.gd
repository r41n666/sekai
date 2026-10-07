extends Node3D
## [临时探针 v4] 骨棒可视化判「掌心朝向」——隐藏全部网格，只画关节点。
##
## v1~v3 已测：手指沿局部 +Y；绕**局部 X** 才在掌背平面内弯（绕 Z 是侧摆）。
## v4：隐藏网格 → 无遮挡；画关节球 + 掌心平面；拍 静止 / -X / +X（左右手）。
## 判据（人眼）：指尖朝**拇指所在一侧**收拢 = 对（掌心）。
##
## 用法：godot --path . --rendering-driver vulkan --resolution 760x600 res://tools/probe_grip_axis.tscn

const CAT := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const OUT := "C:/Users/Administrator/WorkBuddy/Worktrees/sekai/master-230e4f32/tmp_spike"

const FINGERS := ["index", "middle", "ring", "little"]
const JOINTS := ["proximal", "intermediate", "distal"]
const BEND := 0.9

var _sk: Skeleton3D
var _names: PackedStringArray
var _frames := 0
var _idx := {}
var _rest_rot := {}
var _markers: Node3D
var _mat := {}


func _ready() -> void:
	var cam := Camera3D.new()
	cam.name = "Cam"
	cam.current = true
	cam.fov = 30.0
	add_child(cam)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, 30, 0)
	light.light_energy = 2.0
	add_child(light)
	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.10, 0.12, 0.16)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.85, 0.85, 0.9)
	e.ambient_light_energy = 1.0
	we.environment = e
	add_child(we)

	var inst: Node = (load(CAT) as PackedScene).instantiate()
	add_child(inst)
	_sk = _find_skeleton(inst)
	for a in _find_all_anim(inst):
		(a as AnimationPlayer).stop()
		(a as AnimationPlayer).active = false
	for m in _all_meshes(inst):
		(m as MeshInstance3D).visible = false # 只留骨棒
	_names = PackedStringArray()
	for i in _sk.get_bone_count():
		_names.append(_sk.get_bone_name(i))
	for i in _sk.get_bone_count():
		_rest_rot[i] = _sk.get_bone_rest(i).basis
	for side in ["l", "r"]:
		_idx["hand_%s" % side] = _find_part("hand", "", side)
		for f in FINGERS + ["thumb"]:
			for j in JOINTS:
				_idx["%s_%s_%s" % [f, j, side]] = _find_part(f, j, side)
	_mat = {
		"wrist": _unshaded(Color(0.1, 1.0, 0.2)),
		"finger": _unshaded(Color(1.0, 0.25, 0.2)),
		"thumb": _unshaded(Color(0.3, 0.5, 1.0)),
		"palm": _unshaded(Color(1.0, 1.0, 0.2)),
	}
	_markers = Node3D.new()
	_markers.name = "Markers"
	add_child(_markers)


func _unshaded(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.no_depth_test = true
	return m


func _find_part(finger: String, joint: String, side: String) -> int:
	var prefix := finger + "_" + joint if joint != "" else finger
	for i in _names.size():
		var low := String(_names[i]).to_lower()
		if not low.begins_with(prefix.to_lower()):
			continue
		var s := ""
		if low.contains(".l") or low.contains("_l"):
			s = "l"
		elif low.contains(".r") or low.contains("_r"):
			s = "r"
		if s == side:
			return i
	return -1


func _set_curl(sign: float) -> void:
	for f in FINGERS + ["thumb"]:
		for j in JOINTS:
			for side in ["l", "r"]:
				var idx: int = _idx.get("%s_%s_%s" % [f, j, side], -1)
				if idx >= 0:
					if sign == 0.0:
						_sk.set_bone_pose_rotation(idx, _rest_rot[idx])
					else:
						_sk.set_bone_pose_rotation(idx, _rest_rot[idx] * Basis(Vector3(1, 0, 0), BEND * sign))


## 世界坐标关节球
func _ball(pos: Vector3, radius: float, kind: String) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	mi.mesh = sm
	mi.material_override = _mat[kind]
	add_child(mi)
	mi.global_position = pos


func _rebuild_markers() -> void:
	for c in _markers.get_children():
		c.queue_free()
	for side in ["l", "r"]:
		var wrist: Vector3 = _sk.global_transform * _sk.get_bone_global_pose(_idx["hand_%s" % side]).origin
		_attach_ball(wrist, 0.016, "wrist")
		for f in FINGERS:
			for j in JOINTS:
				var p: Vector3 = _sk.global_transform * _sk.get_bone_global_pose(_idx["%s_%s_%s" % [f, j, side]]).origin
				_attach_ball(p, 0.009, "finger")
		for j in JOINTS:
			var p: Vector3 = _sk.global_transform * _sk.get_bone_global_pose(_idx["thumb_%s_%s" % [j, side]]).origin
			_attach_ball(p, 0.010, "thumb")


func _attach_ball(pos: Vector3, radius: float, kind: String) -> void:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = radius
	sm.height = radius * 2.0
	mi.mesh = sm
	mi.material_override = _mat[kind]
	_markers.add_child(mi)
	mi.global_position = pos # 会在这里立即计算 global（父为单位变换）


func _process(d: float) -> void:
	_frames += 1
	if _frames == 8:
		await _shot_img(0, "r_rest", "r", Vector3(0.22, 0.15, 0.26))
	elif _frames == 22:
		_set_curl(-1.0)
		await _shot_img(1, "r_minusX", "r", Vector3(0.22, 0.15, 0.26))
	elif _frames == 36:
		_set_curl(1.0)
		await _shot_img(2, "r_plusX", "r", Vector3(0.22, 0.15, 0.26))
	elif _frames == 50:
		_set_curl(0.0)
		await _shot_img(3, "l_rest", "l", Vector3(-0.22, 0.15, 0.26))
	elif _frames == 64:
		_set_curl(-1.0)
		await _shot_img(4, "l_minusX", "l", Vector3(-0.22, 0.15, 0.26))
	elif _frames == 78:
		_set_curl(1.0)
		await _shot_img(5, "l_plusX", "l", Vector3(-0.22, 0.15, 0.26))
		get_tree().quit(0)


func _shot_img(n: int, label: String, side: String, cam_off: Vector3) -> void:
	_rebuild_markers()
	await get_tree().process_frame # 让 queue_free 生效、markers 定位
	var cam := get_node("Cam") as Camera3D
	var hand: Vector3 = _sk.global_transform * _sk.get_bone_global_pose(_idx["hand_%s" % side]).origin
	cam.position = hand + cam_off
	cam.look_at(hand, Vector3.UP)
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(OUT)
	img.save_png("%s/axis4_%d_%s.png" % [OUT, n, label])
	print("saved axis4_%d_%s.png" % [n, label])


func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root
	for c in root.get_children():
		var f := _find_skeleton(c)
		if f != null:
			return f
	return null


func _all_meshes(root: Node) -> Array:
	var out: Array = []
	if root is MeshInstance3D:
		out.append(root)
	for c in root.get_children():
		out.append_array(_all_meshes(c))
	return out


func _find_all_anim(root: Node) -> Array:
	var out: Array = []
	if root is AnimationPlayer:
		out.append(root)
	for c in root.get_children():
		out.append_array(_find_all_anim(c))
	return out
