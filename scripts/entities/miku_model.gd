extends Node3D
class_name MikuModel
## 初音未来模型挂载点（阶段 4）
##
## - 如果 res://assets/models/miku/miku.glb 存在，自动用它替换占位胶囊（Placeholder 隐藏）；
##   文件不存在时保持占位胶囊，不影响其它功能。
## - 模型里有 AnimationPlayer 时，按移动状态切换 Idle / Walk / Run / Jump（动画名用关键字匹配，带淡入淡出）。
## - 模型里有 Skeleton3D 时，把武器（Rifle）挂到右手骨骼的 BoneAttachment3D 上；否则维持挂在模型节点下。
## 模型正面不是 +Z（player.gd 的转向基准）时，把 yaw_offset_deg 设为 180 之类的补正值。

## 双手持枪 IK 脚本。用 preload 而不是全局 `class_name` 引用：
## 全局类名依赖 `.godot/global_script_class_cache.cfg`（需一次导入/开编辑器才登记），
## preload 则任何情况下都能解析，避免「新加的 class_name 在 headless 首次运行时找不到」。
const WeaponHoldIKScript := preload("res://scripts/entities/weapon_hold_ik.gd")
## UAL locomotion 驱动（preload 同理：全局 class_name 依赖导入缓存）。
const UalLocomotionScript := preload("res://scripts/entities/ual_locomotion.gd")

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
	# "miku_classic": 180.0 —— ⚠ 该模型已删（2026-10-07 资源精简）；若日后重新加回需重新登记
}

## 逐模型「待机微动作」参数表（键 = 模型目录名；查不到用 DEFAULT_IDLE_PROFILE）。
## 由 MikuIdleMotion（程序化呼吸 / 重心微移 / 上身摆动）驱动，作用在「载入模型」这一层，
## 和 MikuModel 上的站/蹲/趴姿态（player.gd）互不干扰。
## 参数含义见 miku_idle_motion.gd 顶部注释；幅度单位：米 / 弧度 / 缩放比例。
## - miku_statue 是「雕像」型资源（无骨骼无动画），专门给它一套更明显的呼吸 + 重心摆动；
## - 其余模型保持默认（轻微），避免抢掉它们自带动画剪辑的表现。
const DEFAULT_IDLE_PROFILE := {
	"breath_amp": 0.010, "breath_scale_amp": 0.005,
	"sway_x_amp": 0.012, "sway_z_amp": 0.008,
	"yaw_amp": 0.022, "roll_amp": 0.008, "pitch_amp": 0.006,
	"breath_freq": 0.24, "sway_freq": 0.14, "sway_roll_freq": 0.18,
	"harmonic": 0.25,
}
const IDLE_PROFILES := {
	# 雕像：呼吸更沉、重心摆动更明显、上身摇摆更慢更柔；互不成整数比的频率让循环点看不出来。
	"miku_statue": {
		"breath_amp": 0.018, "breath_scale_amp": 0.009,
		"sway_x_amp": 0.024, "sway_z_amp": 0.014,
		"yaw_amp": 0.045, "roll_amp": 0.016, "pitch_amp": 0.012,
		"breath_freq": 0.20, "sway_freq": 0.115, "sway_roll_freq": 0.155,
		"harmonic": 0.22,
	},
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
## 战斗动作的动画关键字（两条通道都试：有剪辑走剪辑，没有就退回程序化动作，见 play_combat_action）
@export var fire_keys: PackedStringArray = PackedStringArray(["fire", "shoot", "attack"])
@export var hit_keys: PackedStringArray = PackedStringArray(["hit", "damage", "flinch"])
@export var death_keys: PackedStringArray = PackedStringArray(["death", "die", "dead"])
@export var reload_keys: PackedStringArray = PackedStringArray(["reload", "load"])
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
## 双手持枪 IK 开关（Spike 能力）。
## ⚠ 默认 **false** = 完全维持既有单臂持械行为（不破坏基线）。
## 打开后：若当前模型有标准人形骨架（如 cat_hatsune_miku），双臂由 TwoBoneIK3D 拉到两个握持点，
## 武器朝向由握持点推导；骨架不达标（如乱码 MMD 名的 miku.glb）时自动退回旧行为。
@export var hold_ik_enabled := false
## 「腿程序化 + 手臂 IK」分层开关（Spike 能力，见 `docs` 报告）。
##
## ⚠ 默认 **false** = 完全维持既有「全有或全无」行为（不破坏基线）。
## 打开后，对**有 idle 剪辑但 idle 是 T-pose 定格**的模型（如 cat_hatsune_miku），
## 绕开 `_start_procedural_pose` 的 `return`，让 `MikuProceduralPose` **只接管腿 + 躯干**，
## 手臂留给 `WeaponHoldIK` 的 TwoBoneIK3D：
##   · 腿 / 骨盆 / 头 → 程序化步态（走路时腿会交替迈步、身体起伏）
##   · 双臂 → IK 拉到握持点（双手持枪）
## 两者写**不相交**的骨骼，不打架（`MikuProceduralPose.pose_arms=false`）。
## 仅当模型骨架能被 `MikuProceduralPose` 解析（valid）时才生效，否则静默退回旧行为。
@export var procedural_legs_enabled := false
## 分层模式下是否把握持点挂到**躯干**（chest 骨）的 BoneAttachment3D 上，随骨盆的 lean / bob 一起走。
##
## ⚠ 默认 **false**（把握持点固定在骨架空间，与已验证的 spike 行为一致）。实测结论（见报告）：
##   · 修好 bob 缩放后，走路时躯干起伏只剩 **3.3 cm**；而挂躯干锚点会引入最多 **~6 cm** 的
##     手↔目标残差（`BoneAttachment3D` 与 `SkeletonModifier3D` 的更新时序所致，锚点本身跟随 chest 无误）。
##   · 二者截图**肉眼无差别**。⇒ 锚点「修正的偏差（3.3 cm）」小于「它引入的残差（6 cm）」，
##     故默认不用。若将来把 bob / lean 幅度调大，或用于躯干运动更剧烈的动作，可再打开本开关。
## 仅在分层模式（procedural_legs_enabled 且 pose_arms=false）下才生效，不影响默认行为。
@export var hold_ik_torso_anchor := false
## 手指抓握开关（Spike 能力，见 `docs` 报告）。
##
## ⚠ 默认 **false** = 完全维持既有「手是五指张开的平面」行为（不破坏基线）。
## 打开后：在双手 IK 持枪**生效时**，把 15 根指骨绕局部 X 轴弯到「握住枪」的角度
## （右手 = 握把，左手 = 护木；见 `hand_grip.gd` 的实测依据）。
## 与 `hold_ik_enabled` 的关系：**grip 只在 IK 生效时才应用**（空手 / 第一人称 / IK 关闭时不握拳）——
## 否则空手也握拳、或第一人称看不见的手也在握，都很怪。故本开关单独存在只为「可单独回退」，
## 实际生效需 `hold_ik_enabled` 同时为 true。
@export var hand_grip_enabled := false
## UAL(Quaternius Universal Animation Library) locomotion 开关。
##
## ✅ **默认 true**（2026-10-07 按用户要求开启，用户实机验收项）。
## 打开后：若当前模型是标准人形骨架（骨名与 `ual_bone_map.gd` 的映射表吻合，实测只有
## `cat_hatsune_miku`），用**运行期pose-delta 重定向**驱动 **腿 + 躯干**，
## 取代程序化步态（UAL 有真实的屈膝抬脚 + 身体起伏，程序化版近乎直腿摆动）。
##
## ⚠ **仍保留本开关**，随时可置 false 回退到纯程序化步态（Esc 菜单 / 调试键可改）。
##   降级链完整：开关关 ⇒ 程序化姿态接管腿；UAL 素材缺失 / 骨架不匹配 ⇒同样回退程序化姿态，
##   **绝不出现「没腿」**。
## ⚠ 默认打开**不影响默认模型** `miku.glb`：它的骨名是乱码，骨映射配不出驱动骨
##   ⇒ `is_ual_locomotion_active()` 恒false ⇒ 照旧由 MikuProceduralPose 接管腿
##   （守护用例：`test_ual_switch_on_does_not_disturb_default_model`）。
##
## ## 手臂归属（本开关**不**碰手臂）
##   · 持枪 → `WeaponHoldIK`（双臂）+ `HandGripModifier`（手指）；
##   · 空手 → UAL 驱动手臂（实测决策：cat 的 rest 是 T-pose，空手无人接管会笔直平举穿帮；
##     详见 `ual_locomotion.gd` 文件头）。
##
## ## 与 `procedural_legs_enabled` 的关系：**互斥，二选一**
## UAL 有效 ⇒ **不建**程序化姿态（避免两层同时写腿骨）；UAL 无效 ⇒ 自动回退程序化姿态。
## 因此**不需要**同时打开 `procedural_legs_enabled`。
@export var ual_locomotion_enabled := true
## UAL 冲刺档的速度比例阈值（>= 走 Sprint 剪辑）。
##
## ⚠ 默认 **1.1 = 故意让冲刺档「够不到」**（2026-10-07 按用户要求：
##   「双马尾穿帮可以按『开着但 sprint 够不到』来配」）。
## 依据（实测，不是猜的）：`speed_ratio` 的定义与量纲见 `player.gd:299`
##   `anim_ratio := clampf(move_speed / maxf(sprint_speed, 0.1), 0.0, 1.0)`
##   ——分母是 `sprint_speed`（6.5），且**被 clamp 到 [0, 1]**⇒ **值域恒为 [0, 1]、上界 1.0**。
##   阈值取 1.1 > 1.0 ⇒ `select_state` 里的 `speed_ratio >= sprint_threshold`
##   **永远为假** ⇒ Sprint 剪辑永不播放（仍注册在表里，随时可调回 ≤1.0 启用）。
##   ⇒ 双马尾穿帮的根源动作（大动作 Sprint）被排除在实机可达范围之外。
@export var ual_sprint_threshold := 1.1
## UAL 接管时，手臂归属在「UAL」↔「IK」之间切换的**渐变时长**（秒）。
## 取 0.18 与既有 `fade_time` 一致。设为 0 可退回「硬切」（不建议）。
const UAL_ARM_BLEND_TIME := 0.18

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
## UAL locomotion 驱动（可切换能力；见 ual_locomotion.gd）。素材缺失 / 骨架不匹配时 valid=false，
## 此时**由 `_start_procedural_pose` 回退 MikuProceduralPose**（绝不出现「没腿」）。
var _ual_loco
## 双手持枪 IK（可切换能力；见 weapon_hold_ik.gd）。骨架不达标时为 null。
var _hold_ik
var _state_clips: Dictionary = {} # idle / walk / run / jump -> 动画名
## 战斗动作剪辑：fire / hit / death / reload -> 动画名（匹配不到就是空串 = 走程序化动作）
var _combat_clips: Dictionary = {}
## 程序化待机微动作（呼吸 / 重心微移 / 上身摆动），插在 MikuModel 与载入模型之间
var _idle_motion: MikuIdleMotion

## 第一人称时武器跟随的相机（由 player.gd 注入）；不设时退回模型节点下的默认位置
var view_camera: Node3D
## 是否开镜（由 player.gd 的 set_aiming 同步过来，第一人称下把武器收到画面中心）
var _view_aiming := false
## 战斗动作剪辑正在播放（此时状态机不切idle / walk，避免动作被立刻打断）
var _combat_playing := false
## 战斗动作剪辑剩余时长（秒）；≤0 表示不在播放
var _combat_clip_left := 0.0


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
	_sync_hold_ik()


## 双手持枪 IK 是否可用（当前模型骨架是否有标准左右手臂链）
func is_hold_ik_available() -> bool:
	return _hold_ik != null and _hold_ik.valid


## 运行时开关双手持枪 IK（Esc 菜单 / 调试键可用）。骨架不达标时静默无效。
func set_hold_ik_enabled(on: bool) -> void:
	hold_ik_enabled = on
	_sync_hold_ik()


func toggle_hold_ik() -> void:
	set_hold_ik_enabled(not hold_ik_enabled)


## 运行时开关手指抓握（纯本地演示开关，与 hold_ik 独立）。仅在 IK 生效时真正处理。
func set_hand_grip_enabled(on: bool) -> void:
	hand_grip_enabled = on
	_sync_hold_ik()


## 运行时切换蹲/站姿态（由 player.gd 的 `_update_stance` 每帧转发）。
##
## 只影响**动画**（UAL locomotion 换蹲姿剪辑）；**不影响位移** ——
## 蹲下的碰撞体高度 / 视角高度 / 模型 Y 偏移仍由 `player.gd::STANCE_HEIGHTS` 等负责
## （那些是碰撞与视角需要的，与姿态是两件事，两者不打架）。
## UAL 无效时本方法静默无效果（此时蹲姿由 MikuProceduralPose / 剪辑自行表现）。
func set_crouched(on: bool) -> void:
	if _ual_loco != null:
		_ual_loco.set_crouched(on)


## UAL locomotion 当前是否**真的**在驱动腿 + 躯干（= 开关打开且素材 / 骨架都就绪）。
## 素材缺失或骨架不匹配时为 false —— 此时腿部由 `MikuProceduralPose` 接管。
func is_ual_locomotion_active() -> bool:
	return _ual_loco != null and _ual_loco.valid


func toggle_hand_grip() -> void:
	set_hand_grip_enabled(not hand_grip_enabled)


## 把「是否开 IK」同步到武器持有 / 第一人称状态：
## IK 只在「开关打开 + 正持械 + 第三人称 + 骨架可用」时生效，其余情况完全退回旧路径。
func _sync_hold_ik() -> void:
	if _hold_ik == null:
		return
	_hold_ik.set_enabled(hold_ik_enabled and _holding_weapon and not _first_person)
	# 手指抓握由 WeaponHoldIK 内部再按「IK 是否生效」二次闸门（见 weapon_hold_ik.gd::_refresh）
	_hold_ik.set_grip_enabled(hand_grip_enabled)
	_sync_ual_arm_ownership()


## 手臂归属同步：**IK 接管手臂时让出，空手时由 UAL 驱动**。
##
## ⚠ 为什么必须这样做（实测踩过的坑）：UAL 有效时程序化姿态是**关闭**的（两者互斥），
##   若 UAL 再无条件排除手臂，空手时就**没有任何东西驱动手臂** ⇒ cat 的 rest = T-pose
##   ⇒ 空手走路手臂笔直平举（截图证据：tmp_spike/loco_ual_walk_1.png）。
## ⇒ 规则很简单：**IK 生效 ⇒ UAL 让出手臂；否则 UAL 驱动手臂**。
func _sync_ual_arm_ownership() -> void:
	if _ual_loco == null or not _ual_loco.valid:
		return
	var ik_owns_arms: bool = _hold_ik != null and _hold_ik.is_enabled()
	_ual_loco.set_arms_driven(not ik_owns_arms)


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
	_sync_hold_ik()
	_apply_model_visibility()


## 每帧把武器摆到该在的位置：第一人称贴相机，第三人称贴右手骨骼 / 双手 IK
func _process(delta: float) -> void:
	_update_idle_intensity(delta)
	_tick_combat_clip(delta)
	# IK 的 influence 渐变（持枪⇄ 空手换驱动者时消跳变；blend_time=0 时本方法空转）
	if _hold_ik != null:
		_hold_ik.tick(delta)
	if _weapon_mount == null:
		return
	if _first_person:
		_follow_view_camera()
	elif _hold_ik != null and _hold_ik.is_enabled():
		# 双手 IK：武器坐标系由「右手握把 + 左手护木」两点推导，不再无条件朝正前方
		_weapon_mount.global_transform = _hold_ik.get_weapon_transform()
	elif _weapon_follow:
		_follow_hand_bone()


## 战斗动作剪辑的倒计时：播完（或动画自身结束）后恢复行走状态机。
func _tick_combat_clip(delta: float) -> void:
	if not _combat_playing:
		return
	_combat_clip_left -= delta
	if _combat_clip_left > 0.0:
		return
	_combat_playing = false
	_combat_clip_left = 0.0
	if _anim != null and current_state != "":
		# 强制下一帧update_animation 重切行走状态（current_state 已被 playing 分支跳过）
		current_state = ""


## 待机微动作的强度：站 / 蹲时全开，趴下时收到 0（避免呼吸起伏把趴姿顶起来、和贴地互掐）。
## 用 MikuModel 自己的世界「上方向」判定倾斜程度，不依赖具体调用方（player.gd / bot.gd 都适用），
## 且带平滑（淡入淡出），姿态切换时不会突然跳一下。
func _update_idle_intensity(delta: float) -> void:
	if _idle_motion == null or not is_instance_valid(_idle_motion):
		return
	# 世界空间中模型「上方向」的 y 分量：1 = 直立，0 = 完全平躺
	var up_y := global_transform.basis.orthonormalized().y.y
	var target := clampf(inverse_lerp(0.55, 0.92, up_y), 0.0, 1.0)
	_idle_motion.intensity = lerpf(
		_idle_motion.intensity, target, 1.0 - exp(-IDLE_INTENSITY_BLEND * delta)
	)

## 待机强度淡入淡出速度（越大切得越快；10 ≈ 0.1 s 级）
const IDLE_INTENSITY_BLEND := 10.0


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
	# 展示台道具要在量包围盒之前清掉，否则自动缩放会拿「舞台」当身高算（模型缩成玩偶）
	_strip_presentation_props(_loaded_model, path)
	_anim = _find_animation_player(_loaded_model)
	_build_state_clips()
	_fit_to_capsule(_loaded_model, path)
	_start_idle_motion(_loaded_model, path)
	if not _first_person:
		_attach_weapon_to_hand(_loaded_model)
	_start_procedural_pose(_loaded_model)
	_start_hold_ik(_loaded_model)
	model_loaded = true
	# 必须在 model_loaded = true 之后再刷新可见性，否则占位胶囊不会隐藏（会和模型重叠）
	_apply_model_visibility()
	return true


## 逐模型朝向补正：按 assets/models/<目录>/xxx.glb 的目录名查表（找不到返回 0）
static func _yaw_correction_for(path: String) -> float:
	var dir_name := path.get_base_dir().get_file() # res://assets/models/miku_statue/miku_statue.glb -> miku_statue
	return float(MODEL_YAW_CORRECTION.get(dir_name, 0.0))


## 逐模型待机参数：按目录名查 IDLE_PROFILES，查不到用 DEFAULT_IDLE_PROFILE
static func _idle_profile_for(path: String) -> Dictionary:
	var dir_name := path.get_base_dir().get_file()
	var custom: Variant = IDLE_PROFILES.get(dir_name)
	if custom is Dictionary:
		# 以默认值为底，模型自己的键覆盖上去，个别键没写也能跑
		var merged := DEFAULT_IDLE_PROFILE.duplicate()
		merged.merge(custom, true)
		return merged
	return DEFAULT_IDLE_PROFILE


## 在 MikuModel 与载入模型之间插一层 MikuIdleMotion，驱动程序化待机微动作。
## 放在 _fit_to_capsule 之后：此时模型的缩放 / 落地偏移已算好，微动沿用它当基准。
## MikuModel 自身的站 / 蹲 / 趴姿态（player.gd）作用在 MikuModel 上，与本层互不干扰。
func _start_idle_motion(model: Node, path: String) -> void:
	var model_3d := model as Node3D
	if model_3d == null:
		return
	var idle := MikuIdleMotion.new()
	idle.name = "IdleMotion"
	add_child(idle)
	# setup 会把 model_3d 挪到 idle 之下（保留它当前的局部变换），基准量在 setup 内捕获
	idle.setup(model_3d, _idle_profile_for(path))
	_idle_motion = idle


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
	# UAL locomotion 有效时：它接管腿 + 躯干，**直接返回**——
	# 既不跑程序化姿态（互斥），也不让 AnimationPlayer 切状态（cat 自带剪辑是 T-pose 定格，
	# 让它播会把 UAL 辛苦算出的腿部姿态覆盖掉）。
	if _ual_loco != null and _ual_loco.valid:
		_ual_loco.update(delta, speed_mps, speed_ratio, moving, on_floor,
			run_threshold, ual_sprint_threshold)
		return
	if _procedural != null:
		_procedural.update(delta, speed_mps, moving, speed_ratio >= run_threshold, on_floor)
		# 分层模式（pose_arms=false）：程序化只驱动腿，**继续往下切动画**，
		# 让手臂 / 手指从剪辑拿到基线姿态（IK 再叠在剪辑之上）。
		if _procedural.pose_arms:
			return
	if _anim == null:
		return
	var state := "idle"
	if not on_floor:
		state = "jump"
	elif moving:
		state = "run" if speed_ratio >= run_threshold else "walk"
	# 战斗动作播放中不切状态（否则开火动画会被立刻切回idle，看起来像没播）
	if _combat_playing:
		return
	if state == current_state:
		return
	current_state = state
	var clip: String = _state_clips.get(state, "")
	if clip == "":
		clip = _state_clips.get("idle", "") # 缺某个动画时退回 idle，仍然能玩
	# ⚠⚠ **退化剪辑绝不 play()** —— 这是「轻微抽搐」的根因修复。
	# 退化剪辑（如 cat 的 0.083 s 定格）一旦被播，就会以 12 Hz 反复重写全身骨骼姿态，
	# 与 IK / 程序化姿态 / UAL **抢同一批骨** ⇒ 胸骨偏航在 0°↔17° 之间锯齿抖动
	# （窗口模式实测：f03~f24 逐帧 yaw = 0.0 / 2.3 / 8.7 / 17.2 / **0.0** …）。
	# 判定按**实际取到的剪辑名**（不是状态名），因为上面有一条「缺状态剪辑就退回 idle」的路径。
	if clip == "" or _clip_is_degenerate(clip):
		return
	if _anim.current_animation == clip:
		return
	_anim.play(clip, fade_time)


# ---------------------------------------------------------------------------
# 退化剪辑（degenerate clip）判定 —— 「播完等于没播」的剪辑
# ---------------------------------------------------------------------------
## ## 为什么要按**内容**而不是名字判定
## 某些模型（实测 `cat_hatsune_miku`）带一条叫 `idle` 的剪辑，但它是
## **0.083 s 的定格**：98 条骨骼轨道里**只有 1 条**会动（`chest_94` 的偏航 0°→19.7°），
## 双腿骨**一条轨道都没有** ⇒ 播起来就是全身 T-pose 且纹丝不动。
## ⚠ 所以**不能**按「名字含 idle 就跳过」—— 那只对这一份资源成立，
## 换一份「叫 walk 但同样是定格」的剪辑就会漏判。
##
## ## 判据（两个条件**同时**成立才算退化）
##   ① 时长 < `DEGENERATE_MIN_LENGTH`（0.2 s）；
##   ② 会动的骨骼轨道占比 < `DEGENERATE_MIN_MOTION_RATIO`（15%）。
##
## ## 阈值是怎么定的（实测数据，`tools/probe_tpose.gd` / `tools/probe_idle_clip.gd`）
##   | 剪辑                 | 时长   | 会动轨道 / 总轨道 | 占比   | 判定 |
##   |----------------------|--------|-------------------|--------|------|
##   | cat `idle`（定格）   | 0.083s | 1 / 98| **1.0%**  | 退化 |
##   | cat `ArmatureAction` | 2.500s | 87 / 98           | 88.8%  | 正常 |
##   阈值取在两者中间（1.0% ↔ 88.8% ⇒ 15% 有约 15× / 6× 的双向余量），
##   因此对「几乎不动」与「正常动」两类都有很强的鉴别力，不是勉强过关。
##   时长阈值同理：0.083 s ↔ 0.667 s（UAL 最短的真实 locomotion 剪辑 Sprint），
##   0.2 s 落在中间（2.4× / 3.3× 余量）。
##
## ## 为什么用「轨道占比」而不是「首尾位移差」
## 首尾差值对**非循环**剪辑会误判（起点 ≠ 终点本来很正常），而轨道占比与首尾无关，
## 问的是「这条剪辑有没有真的在动**哪些骨**」—— 这才是状态机关心的事。
const DEGENERATE_MIN_LENGTH := 0.2
const DEGENERATE_MIN_MOTION_RATIO := 0.15
## 单条轨道「算动了」的门槛：位移 > 1e-6 m（= 1 微米，肉眼绝不可见）
## 或旋转 > 0.05°（比任何渲染抖动都小两个数量级）。
const DEGENERATE_EPS_POS := 1e-6
const DEGENERATE_EPS_ROT_DEG := 0.05


## 量化一条剪辑「动了多少」：**纯函数**，只读 `Animation` 的数据、不碰场景 ⇒ headless 可断言。
##
## @return `{tracks, moving, ratio, max_pos, max_rot_deg, length}`：
##   · `tracks` —— 该剪辑里**变换类**（位置/旋转/缩放）轨道总数（骨骼动画即骨数）；
##   · `moving` —— 其中「真的动了」的轨道数（同一条轨道内任意两个 key 的差超阈值即算动）；
##   · `ratio` = `moving / tracks`（`tracks == 0` 时为 0）。
static func measure_clip_motion(clip: Animation) -> Dictionary:
	if clip == null:
		return {"tracks": 0, "moving": 0, "ratio": 0.0, "max_pos": 0.0,
			"max_rot_deg": 0.0, "length": 0.0}
	var tracks := 0
	var moving := 0
	var max_pos := 0.0
	var max_rot_deg := 0.0
	for track in clip.get_track_count():
		var ttype := clip.track_get_type(track)
		if ttype != Animation.TYPE_POSITION_3D and ttype != Animation.TYPE_ROTATION_3D \
				and ttype != Animation.TYPE_SCALE_3D:
			continue # 只看变换类轨道；TYPE_BEZIER / TYPE_METHOD / TYPE_BLEND_SHAPE 等忽略
		tracks += 1
		var keys := clip.track_get_key_count(track)
		if keys < 2:
			continue # 单 key 轨道 = 恒定值，天然不动
		var has_motion := false
		for k in keys:
			for j in range(k + 1, keys):
				var ka: Variant = clip.track_get_key_value(track, k)
				var kb: Variant = clip.track_get_key_value(track, j)
				if ttype == Animation.TYPE_ROTATION_3D:
					var deg := rad_to_deg(Quaternion(ka).angle_to(Quaternion(kb)))
					max_rot_deg = maxf(max_rot_deg, deg)
					if deg > DEGENERATE_EPS_ROT_DEG:
						has_motion = true
				else:
					var dist := (Vector3(ka) - Vector3(kb)).length()
					max_pos = maxf(max_pos, dist)
					if dist > DEGENERATE_EPS_POS:
						has_motion = true
		if has_motion:
			moving += 1
	return {
		"tracks": tracks,
		"moving": moving,
		"ratio": float(moving) / float(tracks) if tracks > 0 else 0.0,
		"max_pos": max_pos,
		"max_rot_deg": max_rot_deg,
		"length": clip.length,
	}


## 这条剪辑是不是「退化」的（= 播完等于没播，不配当状态动画）。
##
## **纯函数**：只吃 `Animation` 的数据，不读场景、不看名字 ⇒ 可在 headless 逐值断言。
## ⚠ 判据**只看内容**（时长 + 有多少骨真的动了），**不看剪辑名** ——
##   名字判据（「含 idle 就跳过」）只对当前这一份资源成立，换个资源就漏判。
## @param clip 待判定的剪辑；`null` 视为退化（= 没有可用动画）。
## @param min_length 时长上限（秒），达到它就一定不算退化。
## @param min_motion_ratio 会动轨道占比下限，低于它才算「几乎不动」。
static func is_degenerate(clip: Animation, min_length: float = DEGENERATE_MIN_LENGTH,
		min_motion_ratio: float = DEGENERATE_MIN_MOTION_RATIO) -> bool:
	if clip == null:
		return true
	if clip.length >= min_length:
		return false # 时长够长的一律不算退化（哪怕动作很少，也仍是有效动画）
	return float(measure_clip_motion(clip)["ratio"]) < min_motion_ratio


## 退化剪辑名集合（`_build_state_clips` 填一次，`update_animation` 与
## `_start_procedural_pose` 共用**同一份结论**，保证两处判断永不打架）。
##
## ⚠ 键是**剪辑名**而不是状态名：因为 `update_animation` 有一条
##   「缺某个状态的剪辑就退回 idle」的路径，若按状态名判定，
##   「walk 无剪辑→ 退回 idle」会被算成「walk 退化」而误拒掉一个**可用的** idle。
var _degenerate_clips: Dictionary = {}


## 这个**剪辑**是不是退化的。未收录（= 没被选为状态剪辑）时返回 false。
func _clip_is_degenerate(clip: String) -> bool:
	if clip == "":
		return true
	return bool(_degenerate_clips.get(clip, false))


## 模型里有没有**非退化**的状态剪辑（idle / walk / run / jump 任一）。
## ⚠ 这才是「能不能交给 AnimationPlayer 全权接管」的判据 ——
##   早期版本只问「有没有匹配到剪辑」，于是 cat 的 0.083 s 定格被当成有效 idle，
##   程序化姿态永不启用 ⇒ 全身 T-pose 且一动不动（用户实机确认的现象）。
func _has_usable_state_clip() -> bool:
	for state in ["idle", "walk", "run", "jump"]:
		var clip := String(_state_clips.get(state, ""))
		if clip == "" or _clip_is_degenerate(clip):
			continue
		return true
	return false


# ---------------------------------------------------------------------------
# 战斗动作（开火 / 受击 / 死亡 / 换弹）
# ---------------------------------------------------------------------------

## 开火（与枪声同步；只做角色上肢，后坐力位移由 RecoilSystem 管摄像机）
func play_fire() -> void:
	play_combat_action("fire")


## 受击（可叠加在行走步态之上）
func play_hit() -> void:
	play_combat_action("hit")


## 死亡（程序化通道下**不可逆**，直到 reset_pose()）
func play_death() -> void:
	play_combat_action("death")


## 换弹（约 1.2 s，期间移动速度受影响）
func play_reload() -> void:
	play_combat_action("reload")


## 复位姿态（重生时调用）：清掉死亡不可逆标记与骨骼覆写。
func reset_pose() -> void:
	if _procedural != null:
		_procedural.reset_pose()
	_combat_playing = false
	_combat_clip_left = 0.0


## 触发一个战斗动作。**两条通道都支持**：
##   ① 有匹配的动画剪辑 → 播剪辑（本项目只有 cat_hatsune_miku 走这条）；
##   ② 没有剪辑 → **退回程序化动作**（MikuProceduralPose 的 alpha 包络叠加层）。
## 两条通道互斥：走剪辑通道的模型 _procedural 为 null，走程序化通道的模型没有匹配剪辑，
## 因此这里「谁有谁上」，不会出现两边同时驱动骨骼。
func play_combat_action(action: String) -> void:
	match action:
		"fire":
			if not _try_combat_clip(action):
				_procedural_fire()
		"hit":
			if not _try_combat_clip(action):
				_procedural_hit()
		"death":
			if not _try_combat_clip(action):
				_procedural_death()
		"reload":
			if not _try_combat_clip(action):
				_procedural_reload()


## 试着播战斗动作的动画剪辑；没有 / 播不了返回 false（调用方据此退回程序化动作）。
func _try_combat_clip(action: String) -> bool:
	if _anim == null:
		return false
	var clip: String = _combat_clips.get(action, "")
	if clip == "":
		return false
	if _procedural != null:
		_procedural.reset_pose() # 死亡是跨通道不可逆的：切到剪辑前先清掉程序化层的死亡标记
	_anim.play(clip, fade_time)
	_combat_playing = true
	_combat_clip_left = _combat_clip_duration(clip)
	return true


## 程序化通道的四个动作（valid=false 时各自静默跳过，不报错）
func _procedural_fire() -> void:
	if _procedural != null:
		_procedural.trigger_fire()


func _procedural_hit() -> void:
	if _procedural != null:
		_procedural.trigger_hit()


func _procedural_death() -> void:
	if _procedural != null:
		_procedural.trigger_death()


func _procedural_reload() -> void:
	if _procedural != null:
		_procedural.trigger_reload()


## 战斗动作对移动速度的影响系数（1 = 不影响；换弹 < 1；死亡 = 0）。
## 由 player.gd / bot.gd 在算移动速度时乘上去（纯视觉表现，不改角色真实速度）。
func combat_movement_scale() -> float:
	if _procedural != null:
		return _procedural.movement_scale()
	return MikuCombatAnim.new().movement_scale()


## 模型没有「**可用的**状态动画剪辑」时，退回到「程序化姿态」：把 T-pose 的胳膊放下来 + 走/跑/跳的摆动。
##
## ⚠ 判定用的是 `_has_usable_state_clip()` ——「有没有**非退化**的idle/walk/run/jump 剪辑」，
## 而**不是**「有没有 AnimationPlayer」，也不是「有没有匹配到 idle/walk/run 剪辑」。
## 两个反例（都是本项目实测踩过的）：
##   · `cat_hatsune_miku`：有 idle 剪辑，但它 0.083 s、98 条轨道只有 1 条会动 ⇒
##     **退化**（= T-pose 定格）。按旧判据会直接 return，于是程序化姿态永不启用
##     ⇒ 全身 T-pose 且一动不动（用户实机确认的现象）。
##   · 已删除的 `miku_classic`：有 AnimationPlayer，但名字对不上任何状态关键字。
##     只看 `_anim != null` 就会既不播动画、又不启用程序化姿态，同样僵在 T-pose。
func _start_procedural_pose(model: Node) -> void:
	_procedural = null
	# —— 第一步：试 UAL locomotion（腿 + 躯干）。成功则**不建**程序化姿态（两者互斥）。
	# 这一步必须先于下面的「有没有可用状态剪辑」判定：cat 自带的退化 idle 剪辑会让程序化姿态永不启用，
	# 而那个 idle 播起来就是 T-pose ⇒ 不接 UAL、也不建程序化姿态时角色就完全没有腿的动作。
	if _try_start_ual_locomotion(model):
		return
	if _has_usable_state_clip():
		# 既有行为：有**可用的**状态剪辑 → 全交给 AnimationPlayer，不启用程序化姿态。
		# 例外（新增，默认关）：procedural_legs_enabled 时让程序化姿态**只接管腿 + 躯干**，
		# 手臂留给剪辑 / IK —— 解决「idle 是 T-pose 定格、除手臂外全身不动」的模型（cat_hatsune_miku）。
		if procedural_legs_enabled:
			_build_procedural_pose(model, false, true)
		return
	_build_procedural_pose(model, true, false)


## 尝试启用 UAL locomotion。成功返回 true（此时 `_ual_loco.valid == true` 且**没有**程序化姿态）。
##
## 降级语义（关键）：任何一步失败都返回 false，调用方随即走**原有的程序化姿态路径**——
## 因此「素材缺失 / 骨架不匹配 / 加载失败」都不会让角色失去腿部动作（绝不掉进「没腿」状态）。
func _try_start_ual_locomotion(model: Node) -> bool:
	_ual_loco = null
	if not ual_locomotion_enabled:
		return false
	var skeleton := _find_skeleton(model)
	if skeleton == null:
		return false
	var ual = UalLocomotionScript.new()
	if not ual.setup(skeleton, self):
		# setup 失败时它已经 warning 过原因；交回程序化姿态。
		ual.teardown()
		return false
	_ual_loco = ual
	print("MikuModel：已启用 UAL locomotion（腿 + 躯干；手臂归 IK / 程序化姿态） ", ual.debug_names)
	return true


## 建立程序化姿态。`arms=true` = 全程序化（腿 + 手臂 + 躯干；无剪辑模型的兜底路径）；
## `arms=false` = 只接管腿 + 躯干，手臂留给 IK / 剪辑（分层路径，见 procedural_legs_enabled）。
func _build_procedural_pose(model: Node, arms: bool, layered: bool) -> void:
	var skeleton := _find_skeleton(model)
	if skeleton == null:
		return
	var pose := MikuProceduralPose.new()
	pose.pose_arms = arms
	pose.holding_weapon = _holding_weapon
	if pose.setup(skeleton, self):
		_procedural = pose
		if layered:
			print("MikuModel：腿程序化 + 手臂 IK 分层已启用（pose_arms=false）", pose.debug_names)
		else:
			print("MikuModel：没有可用的状态动画剪辑，已启用程序化姿态 ", pose.debug_names)


## 搭建双手持枪 IK（与程序化姿态 / 动画剪辑互不干扰：它只接管两条手臂链）。
##
## ⚠ 与 `_start_procedural_pose` 的「全有或全无」设计**正交**：
##   · 有 idle 剪辑的模型（cat_hatsune_miku）走剪辑通道 → `_procedural == null`，IK 叠在剪辑之上；
##   · 无剪辑的模型走程序化姿态 → 但那些模型（miku.glb 乱码骨名）解析不出手臂链 → IK 自动不启用。
##   因此两条管线不会同时对同一骨骼写姿态。
func _start_hold_ik(model: Node) -> void:
	_hold_ik = null
	var skeleton := _find_skeleton(model)
	if skeleton == null:
		return
	var ik = WeaponHoldIKScript.new()
	# 分层模式（程序化姿态已启用且不接管手臂）→ 把握持点挂到躯干上，随骨盆的 lean / bob 一起走，
	# 避免「躯干动了、目标点不动、手臂被拉扯」的基准冲突。
	ik.attach_targets_to_torso = hold_ik_torso_anchor and _procedural != null and not _procedural.pose_arms
	# ⚠ UAL 接管时手臂归属会在「UAL」↔「IK」之间换人 ⇒ 开 influence 渐变消跳变。
	#   blend_time = 0 时WeaponHoldIK 行为与改动前完全一致（不破坏基线与既有测试）。
	ik.blend_time = UAL_ARM_BLEND_TIME if _ual_loco != null and _ual_loco.valid else 0.0
	if ik.setup(skeleton, self):
		_hold_ik = ik
		_sync_hold_ik()
		print("MikuModel：已就绪双手持枪 IK ", ik.debug_names)


func _clear_loaded_model() -> void:
	# 待机微动作节点（IdleMotion）是 MikuModel 的子节点，不随 _loaded_model 一起释放，要单独清掉
	if _idle_motion != null and is_instance_valid(_idle_motion):
		_idle_motion.queue_free()
	_idle_motion = null
	# ⚠ UAL 源实例同样挂在 MikuModel 下（不随模型骨架释放），必须在这里 teardown。
	#   teardown 还会 reset 写过的骨骼姿态，否则切模型后残留姿态会留在旧骨架上。
	if _ual_loco != null:
		_ual_loco.teardown()
		_ual_loco = null
	# 双手 IK 的 modifier / 目标节点挂在骨架下，会随骨架一起释放；这里只清引用
	if _hold_ik != null:
		_hold_ik.teardown()
		_hold_ik = null
	if _loaded_model == null or not is_instance_valid(_loaded_model):
		return
	_detach_weapon_back()
	_weapon_attachment = null # 旧骨架一起被释放
	_loaded_model.queue_free()
	_loaded_model = null
	_anim = null
	_procedural = null
	_state_clips.clear()
	_degenerate_clips.clear()
	_combat_clips.clear()
	_combat_playing = false
	_combat_clip_left = 0.0
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
	_degenerate_clips.clear()
	if _anim == null:
		return
	var names: Array[String] = []
	for animation_name in _anim.get_animation_list():
		names.append(String(animation_name))
	_state_clips["idle"] = _match_clip(names, idle_keys)
	_state_clips["walk"] = _match_clip(names, walk_keys)
	_state_clips["run"] = _match_clip(names, run_keys)
	_state_clips["jump"] = _match_clip(names, jump_keys)
	_combat_clips["fire"] = _match_clip(names, fire_keys)
	_combat_clips["hit"] = _match_clip(names, hit_keys)
	_combat_clips["death"] = _match_clip(names, death_keys)
	_combat_clips["reload"] = _match_clip(names, reload_keys)
	for state in ["idle", "walk", "run", "jump"]:
		var clip: String = _state_clips.get(state, "")
		if clip == "":
			continue
		var animation := _anim.get_animation(clip)
		var degenerate := is_degenerate(animation)
		if degenerate:
			_degenerate_clips[clip] = true
			# 退化剪辑**绝不**设成循环：0.083 s 的定格一旦循环，就是 12 Hz 的
			# 全身姿态重写（实测胸骨偏航在 0°↔17° 之间锯齿抖动 = 用户说的「轻微抽搐」）。
			print("MikuModel：状态剪辑 %s（%s）判定为**退化**（时长 %.3f s / 会动轨道占比 %.1f%%）⇒ 不播它" % [
				clip, state, animation.length if animation != null else 0.0,
				100.0 * float(measure_clip_motion(animation)["ratio"])])
			continue
		if animation != null:
			animation.loop_mode = Animation.LOOP_LINEAR
	_anim.stop() # 模型自带的自动播放交给状态机接管


## 战斗动作剪辑的时长（秒）：动画自身的长度；读不到就用动作的标称时长兜底。
## 兜底值与 MikuCombatAnim 的时长一致 —— 剪辑不存在时本来就是走程序化通道，
## 这里只是「有剪辑但读不到长度」时的安全下限。
func _combat_clip_duration(clip: String) -> float:
	if _anim != null:
		var animation := _anim.get_animation(clip)
		if animation != null and animation.length > 0.0:
			return animation.length
	match clip:
		"fire":
			return MikuCombatAnim.FIRE_DURATION
		"hit":
			return MikuCombatAnim.HIT_DURATION
		"death":
			return MikuCombatAnim.DEATH_FALL_TIME
		"reload":
			return MikuCombatAnim.RELOAD_DURATION
	return 0.3


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
##
## path 目前只用于保留「逐模型微调」的扩展点（见 MODEL_FIT_SCALE 注释）。
func _fit_to_capsule(model: Node, path: String) -> void:
	var model_3d := model as Node3D
	if model_3d == null:
		return
	var bounds := _measure_bounds(model)
	if bounds.size.y <= 0.001:
		return
	if auto_fit_height > 0.0:
		model_3d.scale *= auto_fit_height / bounds.size.y
		bounds = _measure_bounds(model)
	# 逐模型微调倍率：自动缩放是「把整个包围盒压到 auto_fit_height」，
	# 若某模型包围盒里绝大多数是「非身高」部分（长武器 / 极长马尾），角色会被压小。
	var extra := model_scale * _fit_scale_for(path)
	if not is_equal_approx(extra, 1.0):
		model_3d.scale *= extra
		bounds = _measure_bounds(model)
	model_3d.position.y += PLACEHOLDER_BOTTOM_Y - bounds.position.y
	model_3d.position += position_offset


## 逐模型「自动缩放微调」倍率（键 = 模型目录名；缺省 1.0，即完全信任自动缩放）。
##
## 目前是空的 —— 实测四个模型的自动缩放都已经合理，不需要补正：
##   模型            头顶骨 y   包围盒跨度   自动倍率   身体实际高度
##   miku_classic      6.695      7.664      0.228      1.53 m   ← ⚠ 该模型已删（2026-10-07 资源精简），此行留作历史记录
##   cat_hatsune       2.435      2.979      0.588      1.43 m
##   miku_statue       —（无骨骼，走网格包围盒）0.090     1.77 m
## 身体高度都在 1.4~1.8 m 区间，符合预期（曾试给 miku_classic 补 1.35，身体变 2.24 m，明显过大）。
##
## 什么时候才需要往这里加值：某模型「自动缩放后角色明显不成比例」时。
## 重新判定方法：量「头顶骨 y ÷ 包围盒跨度」得到身体占比，再和目标身高相除。
const MODEL_FIT_SCALE := {}


func _fit_scale_for(path: String) -> float:
	var dir_name := path.get_base_dir().get_file()
	return float(MODEL_FIT_SCALE.get(dir_name, 1.0))


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


## mmd_tools 导出的 glb 常把物理刚体 / 关节占位物件也带进来（渲染出来是一堆白盒子），这里清理掉。
## 另外有些 Sketchfab 导出会把「展示台」整套带进来（地面 / 灯 / 摄像机），
## 那些在游戏里会渲染成角色脚下的一块白板 + 悬浮物件，且会污染包围盒测量（自动缩放算错）。
## 展示台只对**表里点名的模型**清理（MODEL_STRIP_PROPS），避免误删 miku.glb 自带的 Light / Camera（那是既有功能要用的）。
func _strip_mmd_physics_proxies(model: Node) -> void:
	var proxies: Array[Node] = []
	_collect_mmd_proxies(model, proxies)
	for proxy in proxies:
		proxy.queue_free()
	if not proxies.is_empty():
		print("MikuModel：已移除 %d 个 MMD 物理占位网格" % proxies.size())


## 逐模型「展示台道具」清理名单（键 = 模型目录名；值为该模型要删掉的节点名小写关键字）。
## 只删**命中关键字**的节点（连同子树），其余一律保留。
const MODEL_STRIP_PROPS := {
	# Sketchfab 导出带整套展示台：Floor（6.8×6.8 白板）、Lamp / Lamp2（空节点）；Hairshadow 是头发投影片，角色身上不需要
	# "miku_classic": ["floor", "lamp", "hairshadow"] —— ⚠ 该模型已删（2026-10-07 资源精简）
	# cat_hatsune_miku 自带一块 Plane_001_122 平面（疑似底座），一并清掉
	"cat_hatsune_miku": ["plane_001"],
}


func _strip_presentation_props(model: Node, path: String) -> void:
	var dir_name := path.get_base_dir().get_file()
	var keywords: Variant = MODEL_STRIP_PROPS.get(dir_name)
	if not (keywords is Array):
		return
	var targets: Array[Node] = []
	_collect_named_nodes(model, keywords, targets)
	for node in targets:
		# 用 free() 而不是 queue_free()：紧接着就要量包围盒，
		# queue_free 要到帧末才真正释放，这帧量到的还是带舞台的尺寸（自动缩放会算错）。
		_detach_and_free(node)
	if not targets.is_empty():
		print("MikuModel：已移除 %d 个展示台道具节点（%s）" % [targets.size(), dir_name])


## 从父节点摘下来再立即释放（free 不能在「自己子树内」的回调里调用，先 detach 更稳）
func _detach_and_free(node: Node) -> void:
	var parent := node.get_parent()
	if parent != null:
		parent.remove_child(node)
	node.free()


## 广度优先收名字命中关键字的节点；命中即整棵子树带走，不再往下找
func _collect_named_nodes(node: Node, keywords: Array, out: Array[Node]) -> void:
	for child in node.get_children():
		var lower_name := String(child.name).to_lower()
		var hit := false
		for keyword in keywords:
			if lower_name.contains(String(keyword)):
				hit = true
				break
		if hit:
			out.append(child)
			continue
		_collect_named_nodes(child, keywords, out)


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
