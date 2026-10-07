extends Node3D
## [临时只读探针] 验证 MikuProceduralPose 能否接管 cat_hatsune_miku 的腿。
##
## 背景：cat_hatsune_miku 自带的 idle 剪辑是「T-pose 定格」（除手臂外全身不动），
## 而 MikuModel._start_procedural_pose 是「全有或全无」：有 idle 剪辑就永不启用程序化姿态。
## 本探针**绕开那条 return**，直接对 cat 骨架做 MikuProceduralPose.setup()，实测：
##   1) valid 是否为 true
##   2) debug_names / debug_indices 能否解析出大腿根 / 膝 / 脚踝 / 上臂 / 肘 / _center
##   3) 若 valid=false，定位失败在哪一步（哪个骨骼没找到、几何判据为何失效）
##
## setup() 只读 rest pose + global_transform，**headless 可跑**（无需渲染）。
## 用法：
##   godot --headless --path . res://tools/probe_procedural_pose.tscn

const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const MIKU_MODEL := "res://assets/models/miku/miku.glb"

var _model: MikuModel
var _frames := 0


func _ready() -> void:
	var path := CAT_MODEL
	var args := OS.get_cmdline_user_args()
	if "miku" in args:
		path = MIKU_MODEL
	print(">>> probing model: %s" % path)
	_model = MikuModel.new()
	_model.name = "MikuModel"
	_model.model_path = path
	add_child(_model)
	_model.position.y = 0.9
	_model.set_holding_weapon(true)


func _process(_d: float) -> void:
	_frames += 1
	if _frames < 3:
		return
	_probe()
	get_tree().quit(0)


func _probe() -> void:
	print("")
	print("==================== PROCEDURAL POSE PROBE ====================")
	var loaded: Variant = _model.get("_loaded_model")
	print("loaded_model = %s" % loaded)
	var sk := _find_skeleton(_model)
	if sk == null:
		print("!! NO SKELETON FOUND")
		return
	print("skeleton = %s  bone_count = %d" % [sk, sk.get_bone_count()])
	print("skeleton.global_transform.basis = %s" % sk.global_transform.basis)
	print("model.global_transform.basis     = %s" % _model.global_transform.basis)

	var pose := MikuProceduralPose.new()
	var ok: bool = pose.setup(sk, _model)
	print("--- setup() result ---")
	print("returned_ok = %s   valid = %s" % [ok, pose.valid])
	print("debug_names   = %s" % pose.debug_names)
	print("debug_indices = %s" % pose.debug_indices)
	print("_leg_length   = %s" % pose._leg_length)
	print("_height       = %s" % pose._height)
	print("_min_height   = %s" % pose._min_height)
	print("_model_scale  = %s" % pose._model_scale)
	print("_up=%s _front=%s _left=%s _right=%s" % [pose._up, pose._front, pose._left, pose._right])
	print("_down_sign_r=%s _down_sign_l=%s" % [pose._down_sign_r, pose._down_sign_l])

	print("--- all bones (idx name parent childcount) ---")
	for i in sk.get_bone_count():
		var p: int = sk.get_bone_parent(i)
		print("  [%3d] %-28s parent=%3d children=%d" % [
			i, sk.get_bone_name(i), p, sk.get_bone_children(i).size()])
	print("===============================================================")
	print("")


func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root
	for c in root.get_children():
		var f := _find_skeleton(c)
		if f != null:
			return f
	return null
