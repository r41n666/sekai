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
## 逐模型朝向补正表（度）：某些模型（如 Sketchfab 导出的雕塑）正面朝 -Z，和项目约定（+Z）相反。
## 键 = 模型文件所在目录名（assets/models/<目录>/<文件>.glb），值 = 需要额外转的偏航角。
## 在 yaw_offset_deg 之外**再叠一次**；找不到的模型不加补正（= 0）。
## 判定方法：scripts/entities/model_facing_check.gd（或 tools 里同款离屏实拍：相机放 +Z 正前方，看到脸才对）。
const MODEL_YAW_CORRECTION := {
	"miku_statue": 180.0, # Sketchfab 雕塑：正面朝 -Z，实测 +Z 机位看到的是后脑（双马尾在后），补 180
}
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
## 右手骨骼关键字（把武器挂到手上用；「手首」= 手腕，优先于 Twist / 指尖等辅助骨）
@export var hand_bone_keys: PackedStringArray = PackedStringArray(
	["hand_r", "righthand", "right_hand", "wrist_r", "hand.r", "右手首", "手首", "右手"]
)
## 名字里带这些词的不算「手」（Twist 辅助骨 / 手指 / 握り 之类），否则武器会挂在奇怪的位置
const HAND_BONE_BLOCK := ["捩", "指", "握り", "拡散", "先", "ik", "親", "end"]
## 枪挂到手骨骼上时的相对位置（武器空间微调，米）
@export var hand_offset := Vector3.ZERO
## 武器相对角色正前方的额外旋转（度，一般不用动；用来微调枪口俯仰 / 侧倾）
@export var hand_rotation_deg := Vector3.ZERO
## 第一人称时武器相对相机的摆放（相机空间：+X 右 / +Y 上 / -Z 前）
@export var view_offset := Vector3(0.2, -0.16, -0.4)
## 开镜（右键 ADS）时第一人称武器的摆放：往画面中心收，像真的在瞄准
@export var view_aim_offset := Vector3(0.02, -0.05, -0.45)
## 第一人称时武器相对相机的偏航（度）：武器模型正面朝 +Z，转 180° 才对上镜头前方
@export var view_yaw_deg := 180.0
## 动画状态切换的淡入时间（秒）
@export var fade_time := 0.18
## 跑 / 走的判定阈值（速度比例）
@export var run_threshold := 0.62

## 几何法找右手时的排除词（头发 / 裙子等辅助骨骼不能当手）与最低高度比例
const HAND_SEARCH_BLOCK := [
	"hair", "skirt", "ribbon", "tail", "collider", "dummy", "shadow", "rigid", "joint",
	"ik", "end", "offset", "捩", "髪", "スカート", "リボン", "影"
]
const HAND_MIN_RATIO := 0.55

var model_loaded := false
var current_state := ""

var _placeholder: Node3D
var _weapon_mount: Node3D
var _weapon_home := Transform3D.IDENTITY
var _weapon_attachment: BoneAttachment3D
## 第三人称：武器挂点是否跟随右手骨骼（第一人称 / 没骨骼时为 false）
var _weapon_follow := false
## 是否处于「端着武器」状态（程序化姿态会把右手抬到身前）
var _holding_weapon := false
var _first_person := false
var _loaded_model: Node
var _anim: AnimationPlayer
var _procedural: MikuProceduralPose
var _state_clips: Dictionary = {} # idle / walk / run / jump -> 动画名

## 第一人称时武器跟随的相机（由 player.gd 注入）；不设时退回模型节点下的默认位置
var view_camera: Node3D
## 是否开镜（由 player.gd 的 set_aiming 同步过来，第一人称下把武器收到画面中心）
var _view_aiming := false


func _ready() -> void:
	_placeholder = get_node_or_null("Placeholder")
	_weapon_mount = get_node_or_null("WeaponMount")
	if _weapon_mount != null:
		_weapon_home = _weapon_mount.transform
	load_model(model_path)


## 装备 / 空手切换时由 player.gd 调用：程序化姿态据此决定右手是垂着还是端起来
func set_holding_weapon(on: bool) -> void:
	_holding_weapon = on
	if _procedural != null:
		_procedural.holding_weapon = on


## 开镜 / 收镜时由 player.gd 调用：第一人称下武器跟着收进画面中心
func set_view_aiming(on: bool) -> void:
	_view_aiming = on


## 第一人称：隐藏模型与占位胶囊，武器改为贴着相机显示（否则跟着模型一起被隐藏，V 键看不到枪）。
## 注意：WeaponMount 始终留在 MikuModel 下（只改它的世界变换），
## player.gd / bot.gd 里的固定路径 $MikuModel/WeaponMount/... 才不会失效。
func set_first_person(on: bool) -> void:
	_first_person = on
	if _weapon_mount != null:
		if on:
			_weapon_follow = false
		elif _loaded_model != null and is_instance_valid(_loaded_model):
			_attach_weapon_to_hand(_loaded_model)
	_apply_model_visibility()


## 每帧把武器摆到该在的位置：第一人称贴相机，第三人称贴右手骨骼
func _process(_delta: float) -> void:
	if _weapon_mount == null:
		return
	if _first_person:
		_follow_view_camera()
	elif _weapon_follow:
		_follow_hand_bone()


func _apply_model_visibility() -> void:
	if _placeholder != null:
		_placeholder.visible = not _first_person and not model_loaded
	if _loaded_model != null and is_instance_valid(_loaded_model):
		(_loaded_model as Node3D).visible = not _first_person


## 扫描 res://assets/models/<子目录>/*.glb，返回可用角色模型（Esc 菜单的角色选择、人机随机外观都用它）。
## 注意：武器模型也放在 assets/models/weapons/ 下，但它不是角色，要跳过（否则人机会随机变成一把枪）。
const MODEL_DIR_IGNORE := ["weapons"]

static func list_available_models() -> Array[String]:
	var paths: Array[String] = []
	var root := DirAccess.open("res://assets/models")
	if root == null:
		return paths
	for sub in root.get_directories():
		if sub.to_lower() in MODEL_DIR_IGNORE:
			continue
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
	# 朝向补正 = 节点上的 yaw_offset_deg + 逐模型表里的补正（某些模型正面朝 -Z）
	var yaw := yaw_offset_deg + _yaw_correction_for(path)
	if yaw != 0.0 and _loaded_model is Node3D:
		(_loaded_model as Node3D).rotation.y = deg_to_rad(yaw)
	add_child(_loaded_model)
	_strip_mmd_physics_proxies(_loaded_model)
	_anim = _find_animation_player(_loaded_model)
	_build_state_clips()
	_fit_to_capsule(_loaded_model)
	if not _first_person:
		_attach_weapon_to_hand(_loaded_model)
	_start_procedural_pose(_loaded_model)
	model_loaded = true
	# 必须在 model_loaded = true 之后再刷新可见性，否则占位胶囊不会隐藏（会和模型重叠）
	_apply_model_visibility()
	return true


## 逐模型朝向补正：按 assets/models/<目录>/xxx.glb 的目录名查表（找不到返回 0）
static func _yaw_correction_for(path: String) -> float:
	var dir_name := path.get_base_dir().get_file() # res://assets/models/miku_statue/miku_statue.glb -> miku_statue
	return float(MODEL_YAW_CORRECTION.get(dir_name, 0.0))


## 当前姿态下，模型最低点相对「玩家原点」（MikuModel 的父节点原点）的高度差。
## 返回值 = 最低点 y − 父原点 y / 父缩放；0 = 正好贴地，正 = 悬空，负 = 穿地。
## 用于趴下时每帧闭环贴地：不用预测（各模型厚度 / 程序化姿态 / 骨骼差异太大），
## 直接量「现在最低点在哪」，再让 player.gd 把 MikuModel.position.y 推回去。
## 同帧内不能读 global_transform（父变换未传播），这里手动累乘局部变换链。
func ground_gap() -> float:
	if _loaded_model == null or not is_instance_valid(_loaded_model):
		return 0.0
	var parent := get_parent() as Node3D
	if parent == null:
		return 0.0
	# MikuModel 自己的变换（含当前旋转 / 位置）作为链的起点
	var base := parent.global_transform
	var lo := INF
	for child in get_children():
		lo = minf(lo, _lowest_y_under(child, base * transform))
	if not is_finite(lo):
		return 0.0
	# 换算到父节点局部空间（父节点若被缩放，global 与 local 不 1:1；这里按父原点对齐）
	var parent_origin := parent.global_position.y
	# 用父节点的 y 缩放，把世界高度差换算成 MikuModel.position.y 上的量
	var scale_y := parent.global_transform.basis.get_scale().y
	if is_zero_approx(scale_y):
		scale_y = 1.0
	return (lo - parent_origin) / scale_y


## 递归累乘局部变换到每个 MeshInstance3D，求其在「flatten 空间」下的最低 y
func _lowest_y_under(node: Node, parent_xform: Transform3D) -> float:
	var lo := INF
	var xform := parent_xform
	if node is Node3D:
		xform = parent_xform * (node as Node3D).transform
	if node is MeshInstance3D:
		var box: AABB = (node as MeshInstance3D).get_aabb()
		for c in 8:
			var corner := box.position + Vector3(
				box.size.x * (c & 1), box.size.y * ((c >> 1) & 1), box.size.z * ((c >> 2) & 1))
			lo = minf(lo, (xform * corner).y)
		return lo
	for child in node.get_children():
		lo = minf(lo, _lowest_y_under(child, xform))
	return lo


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
	pose.holding_weapon = _holding_weapon
	if pose.setup(skeleton, self):
		_procedural = pose
		print("MikuModel：模型没有动画，已启用程序化姿态 ", pose.debug_names)


func _clear_loaded_model() -> void:
	if _loaded_model == null or not is_instance_valid(_loaded_model):
		return
	_detach_weapon_back()
	_weapon_attachment = null # 旧骨架一起被释放
	_loaded_model.queue_free()
	_loaded_model = null
	_anim = null
	_procedural = null
	_state_clips.clear()
	current_state = ""
	model_loaded = false
	_apply_model_visibility()


## 把武器从手骨骼挪回模型节点下（重新加载模型 / 切第一人称时用）
func _detach_weapon_back() -> void:
	_weapon_follow = false
	if _weapon_mount != null:
		_weapon_mount.transform = _weapon_home


## 第三人称：把武器挂点摆到右手上（每帧调用）。
## 位置跟手（所以不会悬空），朝向固定为角色正前方——
## MMD 手骨的朝向千奇百怪（还有 Twist 辅助骨），跟着手旋转会让走路摆臂时枪口乱甩；
## 射击游戏里枪口本来就应该始终对着准星方向。hand_offset / hand_rotation_deg 用来微调。
func _follow_hand_bone() -> void:
	if _weapon_attachment == null or not is_instance_valid(_weapon_attachment):
		return
	var basis := global_transform.basis.orthonormalized() * Basis.from_euler(hand_rotation_deg)
	_weapon_mount.global_transform = Transform3D(
		basis, _weapon_attachment.global_position + basis * hand_offset
	)


## 第一人称：武器贴着相机放（相机空间偏移，跟着俯仰 / 转动走），做成「手持视角模型」。
## 每把武器可以在自己的场景里覆盖 view_offset（枪长刀短，近距离摆放不一样）。
func _follow_view_camera() -> void:
	if view_camera == null or not is_instance_valid(view_camera):
		_weapon_mount.transform = _weapon_home
		return
	var offset := view_offset
	var yaw := view_yaw_deg
	var weapon := _visible_weapon()
	if weapon != null:
		var custom_offset: Variant = weapon.get("view_offset")
		if custom_offset is Vector3:
			offset = custom_offset
		var custom_yaw: Variant = weapon.get("view_yaw_deg")
		if custom_yaw is float or custom_yaw is int:
			yaw = float(custom_yaw)
	var anchor := view_camera.global_transform
	var cam_basis := anchor.basis.orthonormalized()
	if _view_aiming:
		offset = offset.lerp(view_aim_offset, 0.85) # 开镜：武器往画面中心收
	var basis := cam_basis * Basis(Vector3.UP, deg_to_rad(yaw))
	_weapon_mount.global_transform = Transform3D(basis, anchor.origin + cam_basis * offset)


## 当前显示（已掏出）的武器，没掏武器时返回 null
func _visible_weapon() -> Node3D:
	if _weapon_mount == null:
		return null
	for child in _weapon_mount.get_children():
		if child is Node3D and (child as Node3D).visible:
			return child
	return null


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
			if not bone_name.to_lower().contains(lower_key):
				continue
			if _is_blocked_bone(bone_name):
				continue
			return bone_name
	return ""


## 辅助骨判定：Twist（捩）/ 手指 / 指尖（先）等不能当「手」用
func _is_blocked_bone(bone_name: String) -> bool:
	var lower := bone_name.to_lower()
	for keyword in HAND_BONE_BLOCK:
		if lower.contains(String(keyword).to_lower()):
			return true
	return false


## 找「右手」骨骼：先名字匹配（PMX 转换来的模型骨骼名正常），
## 名字是乱码的模型（miku.glb）回退到几何启发式，否则武器只能挂在胸前悬空、不跟手。
func _find_hand_bone(skeleton: Skeleton3D) -> String:
	var by_name := _match_bone(skeleton)
	if by_name != "":
		return by_name
	return _find_hand_bone_geometric(skeleton)


## 几何启发式找右手：
##   1) 只考虑「-X 侧」（模型正面 +Z 的项目约定下，右手在 -X）、腰以上、且名字不是
##      头发 / 裙子 / IK / 末端 等辅助骨骼的骨；
##   2) 取离身体中轴（竖直轴）最远的 == 手指尖；
##   3) 从指尖沿父链往上走到第一个「分叉点」（子骨骼 ≥ 2）== 手腕，武器挂这里才不悬空。
func _find_hand_bone_geometric(skeleton: Skeleton3D) -> String:
	var count := skeleton.get_bone_count()
	if count == 0:
		return ""
	var positions: Array[Vector3] = []
	var min_y := INF
	var max_y := -INF
	for i in count:
		var world: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(i).origin
		var local: Vector3 = global_transform.affine_inverse() * world # MikuModel 局部空间
		positions.append(local)
		min_y = minf(min_y, local.y)
		max_y = maxf(max_y, local.y)
	var height := maxf(max_y - min_y, 0.001)
	var tip := -1
	var tip_distance := 0.0
	for i in count:
		var bone_name := skeleton.get_bone_name(i).to_lower()
		var blocked := false
		for keyword in HAND_SEARCH_BLOCK:
			if bone_name.contains(keyword):
				blocked = true
				break
		if blocked:
			continue
		var point := positions[i]
		if point.x > -0.02: # 右手在 -X 侧
			continue
		if (point.y - min_y) / height < HAND_MIN_RATIO: # 腰以上才算手臂
			continue
		var distance := Vector2(point.x, point.z).length()
		if distance > tip_distance:
			tip_distance = distance
			tip = i
	if tip < 0:
		return ""
	# 指尖 → 手腕：往上走到第一个分叉点（手腕是 5 根手指链的共同父级）
	var current := tip
	for step in 4:
		var parent := skeleton.get_bone_parent(current)
		if parent < 0:
			break
		if skeleton.get_bone_children(parent).size() >= 2:
			current = parent
			break
		current = parent
	return skeleton.get_bone_name(current)


func _attach_weapon_to_hand(model: Node) -> void:
	if _weapon_mount == null:
		return
	var skeleton := _find_skeleton(model)
	if skeleton == null:
		_weapon_follow = false
		return # 没有骨骼：武器留在模型节点下的默认位置
	var bone_name := _find_hand_bone(skeleton)
	if bone_name == "":
		_weapon_follow = false
		return # 没找到右手骨骼：同样保持原挂法
	var attachment := _weapon_attachment
	if attachment == null or not is_instance_valid(attachment):
		attachment = BoneAttachment3D.new()
		attachment.name = "WeaponHand"
		skeleton.add_child(attachment)
		_weapon_attachment = attachment
	attachment.bone_name = bone_name
	_weapon_follow = true
	_follow_hand_bone()


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


## 估算模型在 MikuModel 局部空间里的包围盒。
## 网格 AABB 与骨骼位置各算一份、取「更矮」的那份：
## - 有的 PMX（小海军初音）把物理骨骼丢在离身体很远的位置（前髪先 Y=-74、パンツ Y=+100），
##   只按骨骼量会把身高量成 155 单位 → 自动缩放后模型缩成一个玩偶（人机随机选中时肉眼可见）；
## - 蒙皮网格的 AABB 在 Godot 里是静止姿态的，个别模型不一定准，所以两条路都留着兜底。
func _measure_bounds(model: Node) -> AABB:
	var mesh_bounds := _measure_mesh_bounds(model)
	var bone_bounds := _measure_bone_bounds(model)
	if mesh_bounds.size.y <= 0.001:
		return bone_bounds
	if bone_bounds.size.y <= 0.001:
		return mesh_bounds
	return mesh_bounds if mesh_bounds.size.y <= bone_bounds.size.y else bone_bounds


## 网格 AABB（静止姿态）：把 8 个角点换算到 MikuModel 局部空间
func _measure_mesh_bounds(model: Node) -> AABB:
	var points: Array[Vector3] = []
	for mesh in _collect_meshes(model):
		var box: AABB = mesh.get_aabb()
		for corner_idx in 8:
			var corner := box.position + Vector3(
				box.size.x * (corner_idx & 1),
				box.size.y * ((corner_idx >> 1) & 1),
				box.size.z * ((corner_idx >> 2) & 1)
			)
			points.append(global_transform.affine_inverse() * (mesh.global_transform * corner))
	return _bounds_of(points)


## 骨骼位置的包围盒（没有骨骼时返回空 AABB）
func _measure_bone_bounds(model: Node) -> AABB:
	var skeleton := _find_skeleton(model)
	if skeleton == null:
		return AABB()
	var points: Array[Vector3] = []
	for bone_idx in skeleton.get_bone_count():
		var world_point: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(bone_idx).origin
		points.append(global_transform.affine_inverse() * world_point)
	return _bounds_of(points)


func _bounds_of(points: Array[Vector3]) -> AABB:
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