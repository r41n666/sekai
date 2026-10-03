extends Node3D
class_name MikuModel
## 初音未来模型挂载点（阶段 4）
##
## - 如果 res://assets/models/miku/miku.glb 存在，自动用它替换占位胶囊（Placeholder 隐藏）；
##   文件不存在时保持占位胶囊，不影响其它功能。
## - 模型里有 AnimationPlayer 时，按移动状态切换 Idle / Walk / Run / Jump（动画名用关键字匹配，带淡入淡出）。
## - 模型里有 Skeleton3D 时，把武器（Rifle）挂到右手骨骼的 BoneAttachment3D 上；否则维持挂在模型节点下。
## 模型正面不是 +Z（player.gd 的转向基准）时，把 yaw_offset_deg 设为 180 之类的补正值。

## 模型路径（想用别的文件名就改这里）
@export var model_path := "res://assets/models/miku/miku.glb"
## 朝向补正：模型正面朝 -Z 时填 180
@export var yaw_offset_deg := 0.0
## 自动缩放：把模型缩放到这个高度（米，按骨骼/网格范围估算）；设为 0 表示不自动缩放
@export var auto_fit_height := 1.75
## 额外缩放倍率（自动缩放之后再乘一次，用来微调大小）
@export var model_scale := 1.0
## 位置微调（自动落地之后额外偏移，米；模型没对准胶囊中心时用）
@export var position_offset := Vector3.ZERO
## 动画关键字（不分大小写，取“名字包含任一关键字”的第一个动画）
@export var idle_keys: PackedStringArray = PackedStringArray(["idle", "stand", "wait"])
@export var walk_keys: PackedStringArray = PackedStringArray(["walk", "move"])
@export var run_keys: PackedStringArray = PackedStringArray(["run", "sprint"])
@export var jump_keys: PackedStringArray = PackedStringArray(["jump", "fall", "air"])
## 右手骨骼关键字（把武器挂到手上用）
@export var hand_bone_keys: PackedStringArray = PackedStringArray(
	["hand_r", "righthand", "right_hand", "wrist_r", "hand.r", "右手"]
)
## 枪挂到手骨骼上时的相对位置（在 Inspector 里对着模型调）
@export var hand_offset := Vector3.ZERO
## 动画状态切换的淡入时间（秒）
@export var fade_time := 0.18
## 跑 / 走的判定阈值（速度比例）
@export var run_threshold := 0.62

var model_loaded := false
var current_state := ""

var _placeholder: Node3D
var _weapon_mount: Node3D
var _weapon_home := Transform3D.IDENTITY
var _first_person := false
var _loaded_model: Node
var _anim: AnimationPlayer
var _procedural: MikuProceduralPose
var _state_clips: Dictionary = {} # idle / walk / run / jump -> 动画名


func _ready() -> void:
	_placeholder = get_node_or_null("Placeholder")
	_weapon_mount = get_node_or_null("WeaponMount")
	if _weapon_mount != null:
		_weapon_home = _weapon_mount.transform
	load_model(model_path)


## 第一人称：隐藏模型与占位胶囊（武器挂在 WeaponMount 上，保留可见）
func set_first_person(on: bool) -> void:
	_first_person = on
	_apply_model_visibility()


func _apply_model_visibility() -> void:
	if _placeholder != null:
		_placeholder.visible = not _first_person and not model_loaded
	if _loaded_model != null and is_instance_valid(_loaded_model):
		(_loaded_model as Node3D).visible = not _first_person


## 扫描 res://assets/models/<子目录>/*.glb，返回可用模型路径（Esc 菜单的角色选择、人机随机外观都用它）
static func list_available_models() -> Array[String]:
	var paths: Array[String] = []
	var root := DirAccess.open("res://assets/models")
	if root == null:
		return paths
	for sub in root.get_directories():
		var dir := DirAccess.open("res://assets/models/%s" % sub)
		if dir == null:
			continue
		for file in dir.get_files():
			if file.to_lower().ends_with(".glb"):
				paths.append("res://assets/models/%s/%s" % [sub, file])
	paths.sort()
	return paths


## 加载并替换模型（返回是否成功；文件不存在时保持占位胶囊）
func load_model(path: String) -> bool:
	_clear_loaded_model()
	if not ResourceLoader.exists(path):
		return false
	var packed := load(path) as PackedScene
	if packed == null:
		push_warning("MikuModel：无法加载模型 %s" % path)
		return false
	_loaded_model = packed.instantiate()
	_loaded_model.name = "Miku"
	if yaw_offset_deg != 0.0 and _loaded_model is Node3D:
		(_loaded_model as Node3D).rotation.y = deg_to_rad(yaw_offset_deg)
	add_child(_loaded_model)
	_strip_mmd_physics_proxies(_loaded_model)
	_anim = _find_animation_player(_loaded_model)
	_build_state_clips()
	_fit_to_capsule(_loaded_model)
	_attach_weapon_to_hand(_loaded_model)
	_start_procedural_pose(_loaded_model)
	model_loaded = true
	# 必须在 model_loaded = true 之后再刷新可见性，否则占位胶囊不会隐藏（会和模型重叠）
	_apply_model_visibility()
	return true


## 每帧由 player.gd 调用：有动画剪辑就切动画；没有剪辑时用程序化姿态（摆放骨骼）
func update_animation(delta: float, speed_mps: float, speed_ratio: float, moving: bool, on_floor: bool) -> void:
	if _procedural != null:
		_procedural.update(delta, speed_mps, moving, speed_ratio >= run_threshold, on_floor)
		return
	if _anim == null:
		return
	var state := "idle"
	if not on_floor:
		state = "jump"
	elif moving:
		state = "run" if speed_ratio >= run_threshold else "walk"
	if state == current_state:
		return
	current_state = state
	var clip: String = _state_clips.get(state, "")
	if clip == "":
		clip = _state_clips.get("idle", "") # 缺某个动画时退回 idle，仍然能玩
	if clip == "" or _anim.current_animation == clip:
		return
	_anim.play(clip, fade_time)


## 模型没有动画剪辑时，退回到「程序化姿态」：把 T-pose 的胳膊放下来 + 走/跑/跳的摆动
func _start_procedural_pose(model: Node) -> void:
	_procedural = null
	if _anim != null:
		return
	var skeleton := _find_skeleton(model)
	if skeleton == null:
		return
	var pose := MikuProceduralPose.new()
	if pose.setup(skeleton, self):
		_procedural = pose
		print("MikuModel：模型没有动画，已启用程序化姿态 ", pose.debug_names)


func _clear_loaded_model() -> void:
	if _loaded_model == null or not is_instance_valid(_loaded_model):
		return
	_detach_weapon_back()
	_loaded_model.queue_free()
	_loaded_model = null
	_anim = null
	_procedural = null
	_state_clips.clear()
	current_state = ""
	model_loaded = false
	_apply_model_visibility()


## 把武器从手骨骼挪回模型节点下（重新加载模型时用）
func _detach_weapon_back() -> void:
	if _weapon_mount == null:
		return
	var parent := _weapon_mount.get_parent()
	if parent != null and parent is BoneAttachment3D:
		parent.remove_child(_weapon_mount)
		add_child(_weapon_mount)
		_weapon_mount.transform = _weapon_home


func _build_state_clips() -> void:
	_state_clips.clear()
	if _anim == null:
		return
	var names: Array[String] = []
	for animation_name in _anim.get_animation_list():
		names.append(String(animation_name))
	_state_clips["idle"] = _match_clip(names, idle_keys)
	_state_clips["walk"] = _match_clip(names, walk_keys)
	_state_clips["run"] = _match_clip(names, run_keys)
	_state_clips["jump"] = _match_clip(names, jump_keys)
	for state in ["idle", "walk", "run"]:
		var clip: String = _state_clips.get(state, "")
		if clip == "":
			continue
		var animation := _anim.get_animation(clip)
		if animation != null:
			animation.loop_mode = Animation.LOOP_LINEAR
	_anim.stop() # 模型自带的自动播放交给状态机接管


func _match_clip(names: Array[String], keys: PackedStringArray) -> String:
	for key in keys:
		var lower_key := String(key).to_lower()
		for name in names:
			if name.to_lower().contains(lower_key):
				return name
	return ""


func _match_bone(skeleton: Skeleton3D) -> String:
	for key in hand_bone_keys:
		var lower_key := String(key).to_lower()
		for bone_idx in skeleton.get_bone_count():
			var bone_name := skeleton.get_bone_name(bone_idx)
			if bone_name.to_lower().contains(lower_key):
				return bone_name
	return ""


func _attach_weapon_to_hand(model: Node) -> void:
	if _weapon_mount == null:
		return
	var skeleton := _find_skeleton(model)
	if skeleton == null:
		return # 没有骨骼：武器继续挂在模型节点下
	var bone_name := _match_bone(skeleton)
	if bone_name == "":
		return # 没找到右手骨骼：同样保持原挂法
	var attachment := BoneAttachment3D.new()
	attachment.name = "WeaponHand"
	skeleton.add_child(attachment)
	attachment.bone_name = bone_name
	var parent := _weapon_mount.get_parent()
	if parent != null:
		parent.remove_child(_weapon_mount)
	attachment.add_child(_weapon_mount)
	_weapon_mount.position = hand_offset


## 占位胶囊底面在 MikuModel 局部空间的位置（height 1.8 → -0.9），模型脚底对齐到这里
const PLACEHOLDER_BOTTOM_Y := -0.9


## 把模型缩放 / 对齐到占位胶囊的尺寸（很多 FBX/MMD 转出的模型是“几十米巨人”）
func _fit_to_capsule(model: Node) -> void:
	var model_3d := model as Node3D
	if model_3d == null:
		return
	var bounds := _measure_bounds(model)
	if bounds.size.y <= 0.001:
		return
	if auto_fit_height > 0.0:
		model_3d.scale *= auto_fit_height / bounds.size.y
		bounds = _measure_bounds(model)
	if not is_equal_approx(model_scale, 1.0):
		model_3d.scale *= model_scale
		bounds = _measure_bounds(model)
	model_3d.position.y += PLACEHOLDER_BOTTOM_Y - bounds.position.y
	model_3d.position += position_offset


## 估算模型在 MikuModel 局部空间里的包围盒：有骨骼就用骨骼位置（蒙皮网格的 AABB 不可靠），否则用网格 AABB
func _measure_bounds(model: Node) -> AABB:
	var points: Array[Vector3] = []
	var skeleton := _find_skeleton(model)
	if skeleton != null:
		for bone_idx in skeleton.get_bone_count():
			var world_point: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(bone_idx).origin
			points.append(global_transform.affine_inverse() * world_point)
	else:
		for mesh in _collect_meshes(model):
			var box: AABB = mesh.get_aabb()
			for corner_idx in 8:
				var corner := box.position + Vector3(
					box.size.x * (corner_idx & 1),
					box.size.y * ((corner_idx >> 1) & 1),
					box.size.z * ((corner_idx >> 2) & 1)
				)
				points.append(global_transform.affine_inverse() * (mesh.global_transform * corner))
	if points.is_empty():
		return AABB()
	var result := AABB(points[0], Vector3.ZERO)
	for point in points:
		result = result.expand(point)
	return result


## mmd_tools 导出的 glb 常把物理刚体 / 关节占位物件也带进来（渲染出来是一堆白盒子），这里清理掉
func _strip_mmd_physics_proxies(model: Node) -> void:
	var proxies: Array[Node] = []
	_collect_mmd_proxies(model, proxies)
	for proxy in proxies:
		proxy.queue_free()
	if not proxies.is_empty():
		print("MikuModel：已移除 %d 个 MMD 物理占位网格" % proxies.size())


func _collect_mmd_proxies(node: Node, out: Array[Node]) -> void:
	var lower_name := String(node.name).to_lower()
	if lower_name.contains("mmd_tools_rigid") or lower_name.contains("mmd_tools_joint"):
		out.append(node)
		return
	for child in node.get_children():
		_collect_mmd_proxies(child, out)


func _collect_meshes(node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if node is MeshInstance3D:
		out.append(node)
	for child in node.get_children():
		out.append_array(_collect_meshes(child))
	return out


func _find_animation_player(root: Node) -> AnimationPlayer:
	if root is AnimationPlayer:
		return root
	for child in root.get_children():
		var found := _find_animation_player(child)
		if found != null:
			return found
	return null


func _find_skeleton(root: Node) -> Skeleton3D:
	if root is Skeleton3D:
		return root
	for child in root.get_children():
		var found := _find_skeleton(child)
		if found != null:
			return found
	return null