extends Control
class_name EnemyHealthBars
## 敌方血条（EP-4 · Task #10「远程血量同步」的可见部分）
##
## ## 数据来源：**受害端权威**的血量，经`net_player_state`（30Hz 广播）传到本端，
## 由 `player.gd::apply_network_state()` 写进**显示副本** `get_display_health()`。
## 本脚本是这条链路的**唯一消费者**：
##   · 只读 `get_display_health()`，**从不**调`take_damage()`、不写 `health`、不驱动死亡流程；
##   · 不参与任何胜负 / 计分判定（全项目胜负唯一口径 = `ScoreManager._evaluate_winner`）。
##
## ## 为什么画在「头顶上方」而不是屏幕边缘
## `teammate_icons.gd` 用的是**屏幕边缘贴边**（那是队友导航语义：队友可能在画面外，贴边告诉你往哪看）。
## 敌方血条**故意不贴边**：FFA 贴边会在屏幕边缘凭空出现一个「不知道是哪个方向、哪个敌人」的条，
## 反而是误导（`04_ux_flow §6.2` FFA 敌我语义）。**背对摄像机 / 出画即不画** ——
## 「看得见的敌人 →看得见的血量」，一对一映射，绝不臆造。
##
## ## 可读性（`04_ux_flow §6` Standard 基准：不依赖单一感官 / 颜色）
##   · **明度对比为主**：近黑的底衬 + 近白的填充（明度差 ≈0.9），不靠「红/绿」区分敌我；
##   · **不只靠颜色**：填充上每 25% 有一道**刻度缺口**，血量越低露出的刻度越多
##     （形状 + 位置线索）；条右侧有**数字**（精确读数）；
##   · 因此灰度截图下同样可读（对齐 AC-F3 / AC-F5）。

## 相机组名（与 teammate_icons.gd 同口径：只有本地玩家端有 `camera` 组）
const CAMERA_GROUP := "camera"
## 敌对组（FFA 下远端玩家 + bot 都在此组；bot 无 `get_display_health` 会被跳过）
@export var enemy_group := "enemy"
## 血条锚点高度（米）：画在角色头顶上方一点，避免被模型挡住
@export var height_offset := 2.15
## 条的像素尺寸
@export var bar_width := 68.0
@export var bar_height := 7.0
## 刻度缺口宽度（像素）
@export var notch_width := 2.0
@export var font_size := 13

## 近黑底衬（明度锚点：与填充的明度差是本控件的主要可读性来源）
@export var back_color := Color(0.02, 0.04, 0.07, 0.72)
## 描边（比底衬亮一档，让条在近白天空前仍有边界 —— AC-F4）
@export var border_color := Color(0.62, 0.82, 1.0, 0.85)
## 高血量填充（近白）
@export var fill_color := Color(0.93, 0.98, 1.0, 0.97)
## 低血量填充（暖黄）。⚠ 低血**不靠这个颜色**表达 —— 同时有刻度缺口 + 数字两重线索。
@export var low_fill_color := Color(1.0, 0.79, 0.36, 0.98)
@export var low_health_ratio := 0.35
## 数字颜色
@export var text_color := Color(0.95, 0.98, 1.0, 0.95)

var _camera: Camera3D


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	if _camera == null or not is_instance_valid(_camera):
		_camera = get_tree().get_first_node_in_group(CAMERA_GROUP) as Camera3D
	queue_redraw()


func _draw() -> void:
	# headless / 无渲染后端时投影矩阵退化，`unproject_position()` 会报错 → 直接跳过
	if _camera == null or not is_instance_valid(_camera):
		return
	if RenderingServer.get_rendering_device() == null:
		return
	if get_viewport_rect().size.x <= 0.0 or get_viewport_rect().size.y <= 0.0:
		return

	var font := ThemeDB.fallback_font
	for node in get_tree().get_nodes_in_group(enemy_group):
		if not (node is Node3D):
			continue
		# 能力探测（ADR-007 风格）：只有「会收到远端血量广播的节点」才有显示值。
		# bot / 训练靶没有这个方法 → 跳过（本 Story 只负责联机玩家之间的血量可见）。
		if not node.has_method("get_display_health"):
			continue
		var current := float(node.call("get_display_health"))
		if current < 0.0:
			continue # 尚未收到过有效广播 → 不画（宁可没有，不要先显示一条假血）
		var maximum := 100.0
		if node.has_method("get_display_max_health"):
			maximum = maxf(float(node.call("get_display_max_health")), 1.0)

		var world: Vector3 = (node as Node3D).global_position + Vector3.UP * height_offset
		# 背对摄像机 → 不画（见文件头「为什么不贴边」）
		if _camera.is_position_behind(world):
			continue
		var anchor := _camera.unproject_position(world)

		var ratio := clampf(current / maximum, 0.0, 1.0)
		var rect := bar_rect_for(anchor, get_viewport_rect().size, Vector2(bar_width, bar_height))
		if rect.size == Vector2.ZERO:
			continue
		_draw_one_bar(rect.position, ratio, current, font)


## 计算血条的最终绘制矩形（**静态纯函数** → headless 可直接断言，见下）。
##
## ⚠⚠ **`clamp_to_viewport` 不是可选的润色，是可见性保证**（双端窗口实测实测出来的缺陷）：
##   近距离（≈5 m）时头顶锚点 `head + 2.15 m` 会被投影到**屏幕上方之外**
##   （实测 anchor.y = -7 → 整条画在 y = -14，**玩家完全看不见**，而数据层一切正常：
##    血量确实在同步、只是画到了屏幕外）。这类缺陷 headless 100% 测不出来
##   （`control_checklist §4-10`：verify 走 headless，不经过渲染后端）。
##   → 所以夹取必须内建，且必须能被 headless 断言，故抽成本纯函数。
##
## @param anchor        头顶锚点的屏幕投影坐标
## @param viewport      视口尺寸
## @param bar_size      条的像素尺寸
## @param clamp_to_viewport 是否把条夹进视口内（默认 true = 保可见；false = 只做越界剔除）
## @return 绘制矩形；尺寸为 0 表示「这一帧不该画」（锚点在视口外太远 / 相机背后由调用方先判）
static func bar_rect_for(
	anchor: Vector2, viewport: Vector2, bar_size: Vector2, clamp_to_viewport := true
) -> Rect2:
	if viewport.x <= 0.0 or viewport.y <= 0.0 or bar_size.x <= 0.0 or bar_size.y <= 0.0:
		return Rect2()
	# 越界太远（远超一屏）→ 不画（不是「画在屏幕外」，而是彻底不出现）
	if anchor.x < -viewport.x or anchor.x > viewport.x * 2.0 \
			or anchor.y < -viewport.y or anchor.y > viewport.y * 2.0:
		return Rect2()
	var origin := anchor - Vector2(bar_size.x * 0.5, bar_size.y)
	if not clamp_to_viewport:
		return Rect2(origin, bar_size)
	# 夹进视口（留2px 余量，避免正好压在屏幕边缘上被裁掉一半）
	const MARGIN := 2.0
	origin.x = clampf(origin.x, MARGIN, maxf(viewport.x - bar_size.x - MARGIN, MARGIN))
	origin.y = clampf(origin.y, MARGIN, maxf(viewport.y - bar_size.y - MARGIN, MARGIN))
	return Rect2(origin, bar_size)


## 画一条血量条：底衬 → 填充 → 刻度缺口 → 描边 → 数字。
## 分四层而不是一张带颜色的矩形，是为了让「明度对比」与「非颜色线索」在像素上真的分开。
func _draw_one_bar(origin: Vector2, ratio: float, current: float, font: Font) -> void:
	draw_rect(Rect2(origin, Vector2(bar_width, bar_height)), back_color, true)
	var fill_w := bar_width * ratio
	if fill_w > 0.0:
		var fill := low_fill_color if ratio <= low_health_ratio else fill_color
		draw_rect(Rect2(origin, Vector2(fill_w, bar_height)), fill, true)
	# 刻度缺口：每 25% 一道。血量越低 → 缺口露出的越多（形状线索，不依赖颜色）。
	for i in range(1, 4):
		var x := origin.x + bar_width * 0.25 * float(i)
		draw_rect(Rect2(Vector2(x, origin.y), Vector2(notch_width, bar_height)), back_color, true)
	draw_rect(Rect2(origin, Vector2(bar_width, bar_height)), border_color, false, 1.0)
	draw_string(
		font,
		origin + Vector2(bar_width + 4.0, bar_height),
		"%d" % roundi(current),
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		font_size,
		text_color
	)
