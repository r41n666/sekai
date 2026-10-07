extends Node3D
## [临时只读探针] 量化「基准冲突」：躯干（chest）在走路时摆动多大？握持点是否跟着躯干走？
## 用法：
##   godot --path . --rendering-driver vulkan res://tools/probe_torso_anchor.tscn
##   godot --path . --rendering-driver vulkan res://tools/probe_torso_anchor.tscn -- no-torso

const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const RIFLE := "res://scenes/weapons/rifle.tscn"

var _model: MikuModel
var _frames := 0
var _no_torso := false
var _chest := -1
var _hand_r := -1
var _sk: Skeleton3D
var _chest_y: Array[float] = []
var _tgt_rel: Array[Vector3] = []
var _err: Array[float] = []
var _anchor_err: Array[float] = []


func _ready() -> void:
	_no_torso = "no-torso" in OS.get_cmdline_user_args()
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-30, 30, 0)
	add_child(light)
	_model = MikuModel.new()
	_model.model_path = CAT_MODEL
	_model.procedural_legs_enabled = true
	_model.hold_ik_enabled = true
	_model.hold_ik_torso_anchor = not _no_torso
	var mount := Node3D.new()
	mount.name = "WeaponMount"
	_model.add_child(mount)
	mount.add_child((load(RIFLE) as PackedScene).instantiate())
	add_child(_model)
	_model.position.y = 0.9
	_model.set_holding_weapon(true)
	_sk = _find_skeleton(_model)
	_chest = _sk.find_bone("chest_94")
	_hand_r = _sk.find_bone("hand.R_85")
	_sk.skeleton_updated.connect(_on_upd)
	print("no_torso=%s  torso_attached=%s  chest=%d hand_r=%d" % [
		_no_torso, _model._hold_ik._torso_attached, _chest, _hand_r])


func _on_upd() -> void:
	if _frames < 45 or _frames > 120:
		return
	var chest := _sk.get_bone_global_pose(_chest).origin
	var hand := _sk.get_bone_global_pose(_hand_r).origin
	var tgt: Vector3 = _sk.global_transform.affine_inverse() * _model._hold_ik._target_r.global_position
	# 锚点节点是否跟随「带覆写的 chest 骨」？（若不一致 → 锚点读的是不含覆写的姿态）
	if _model._hold_ik._torso != null:
		var anchor_pos: Vector3 = _sk.global_transform.affine_inverse() * _model._hold_ik._torso.global_position
		_anchor_err.append(anchor_pos.distance_to(chest))
	_chest_y.append(chest.y)
	_tgt_rel.append(tgt - chest)
	_err.append(tgt.distance_to(hand))


func _process(d: float) -> void:
	_frames += 1
	# 固定步长推进，保证两次运行可比（窗口模式不锁帧，真实 delta 每次都不同）
	_model.update_animation(1.0 / 60.0, 2.0, 0.5, true, true)
	if _frames == 122:
		_report()
		get_tree().quit(0)


func _report() -> void:
	print("--- n=%d 样本（帧 45~120，走路中） ---" % _chest_y.size())
	print("chest global y 范围 = [%.4f, %.4f]  摆动幅度 = %.4f 骨架单位（scale≈1.16 → %.4f m）" % [
		_min_f(_chest_y), _max_f(_chest_y), _max_f(_chest_y) - _min_f(_chest_y),
		(_max_f(_chest_y) - _min_f(_chest_y)) * 1.16])
	print("目标点相对 chest 偏移范围（x,y,z 各自 min→max）:")
	for a in 3:
		var lo := INF
		var hi := -INF
		for v in _tgt_rel:
			lo = minf(lo, v[a])
			hi = maxf(hi, v[a])
		print("  axis %d: [%.4f, %.4f]  变化量=%.4f" % [a, lo, hi, hi - lo])
	print("|target - hand| = [%.4f, %.4f] 均值=%.4f 米" % [
		_min_f(_err), _max_f(_err), _avg(_err)])
	if not _anchor_err.is_empty():
		print("锚点节点 vs chest 骨 位置差 = [%.4f, %.4f] 骨架单位（≈0 = 锚点确实跟随带覆写的 chest）" % [
			_min_f(_anchor_err), _max_f(_anchor_err)])


func _min_f(a: Array) -> float:
	var m := INF
	for v in a:
		m = minf(m, v)
	return m


func _max_f(a: Array) -> float:
	var m := -INF
	for v in a:
		m = maxf(m, v)
	return m


func _avg(a: Array) -> float:
	if a.is_empty():
		return 0.0
	var s := 0.0
	for v in a:
		s += v
	return s / a.size()


func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root
	for c in root.get_children():
		var f := _find_skeleton(c)
		if f != null:
			return f
	return null
