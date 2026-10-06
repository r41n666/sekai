extends Control
class_name Minimap
## 小地图（阶段 2，全部用 _draw() 绘制）
##
## - 以玩家为中心，默认随视角旋转（`rotate_with_player = false` 则固定北向上）
## - 障碍物来自组 `minimap_obstacle`（取其中 BoxShape3D 碰撞体的位置与尺寸）
## - 敌人来自组 `enemy`（红色实心方点 □，M1）；队友来自组 `friendly`（绿色圆点 ○，仅 TDM 生效——FFA 下该组为空）
## - **超出 `world_radius` 的敌人 → 在圆周边缘沿「中心→敌人」方向画三角箭头（AC-3）**，
##   只给方位、不给精确点/距离；形状用三角 △ 以区别范围内的方点 □（M1 形状编码）。
## - 注意：远程玩家在 FFA 下归 `enemy` 组（scripts/player.gd::_setup_remote_player），按敌对方点渲染
## - 边缘画北向 N 标记
##
## TODO(阶段2+)：地形贴图（TextureRect / SubViewport）、缩放档位、敌人只在小地图显示已暴露目标。

## 显示范围半径（米）
## 80×80 竞技场（design/gdd/03_map_encounter.md）的对角半长 = √(40²+40²) ≈ 56.6 m，
## 取 60 完整覆盖整图并留 3.4 m 余量（对齐 03_map §6 AC-2 / ⚑M-5 的目标值 ≥60）。
@export var world_radius := 60.0
## 是否随视角旋转
@export var rotate_with_player := true
@export var obstacle_group := "minimap_obstacle"
@export var enemy_group := "enemy"
@export var ally_group := "friendly"

@export var background_color := Color(0.02, 0.06, 0.1, 0.55)
@export var border_color := Color(0.55, 0.8, 1.0, 0.5)
@export var cone_color := Color(0.85, 0.95, 1.0, 0.07)
@export var obstacle_color := Color(0.72, 0.78, 0.85, 0.55)
@export var enemy_color := Color(1.0, 0.28, 0.22, 1.0)
@export var ally_color := Color(0.35, 0.95, 0.55, 1.0)
@export var self_color := Color(0.92, 0.98, 1.0, 1.0)
## 视野扇形角度
@export var view_cone_deg := 70.0

var _player: Node3D
var _camera: Camera3D
var _obstacles: Array[Dictionary] = []
var _collected := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	call_deferred("_collect_obstacles")


func _collect_obstacles() -> void:
	_obstacles.clear()
	for holder in get_tree().get_nodes_in_group(obstacle_group):
		for child in holder.get_children():
			if child is CollisionShape3D and child.shape is BoxShape3D:
				var box: BoxShape3D = child.shape
				_obstacles.append({
					"pos": (child as Node3D).global_position,
					"size": Vector2(box.size.x, box.size.z),
				})
	_collected = true


func _process(_delta: float) -> void:
	if _player == null:
		_player = get_tree().get_first_node_in_group("player") as Node3D
	if _camera == null:
		_camera = get_tree().get_first_node_in_group("camera") as Camera3D
	queue_redraw()


func get_obstacle_count() -> int:
	return _obstacles.size()


func _draw() -> void:
	var radius := minf(size.x, size.y) * 0.5 - 2.0
	var center := size * 0.5
	var scale := radius / maxf(world_radius, 1.0)

	draw_circle(center, radius, background_color)
	if _player != null:
		draw_colored_polygon(_sector_points(center, radius * 0.98), cone_color)

	var frame := _frame()
	var forward: Vector2 = frame[0]
	var right: Vector2 = frame[1]

	# 障碍物
	if _player != null:
		for obstacle in _obstacles:
			var pos := _to_map(obstacle["pos"], center, scale, forward, right)
			if pos.distance_to(center) > radius:
				continue
			var box_size: Vector2 = obstacle["size"]
			var draw_size := Vector2(maxf(box_size.x, 0.6), maxf(box_size.y, 0.6)) * scale
			draw_rect(Rect2(pos - draw_size * 0.5, draw_size), obstacle_color)

		# 队友 / 敌人（M1 形状优先：敌对 = 实心方点 □，我方 = 圆点 ○）
		_draw_group(ally_group, center, radius, scale, forward, right, ally_color, 2.8, false)
		_draw_group(enemy_group, center, radius, scale, forward, right, enemy_color, 3.2, true)

		# 玩家（中心箭头，始终朝上）
		var arrow := PackedVector2Array([
			center + Vector2(0.0, -8.0),
			center + Vector2(-5.5, 6.5),
			center + Vector2(0.0, 3.5),
			center + Vector2(5.5, 6.5),
		])
		draw_colored_polygon(arrow, self_color)

	draw_arc(center, radius, 0.0, TAU, 96, border_color, 1.5, true)
	_draw_north_marker(center, radius, scale, forward, right)


## 绘制一个组的标记。`hostile=true` 画实心方点（M1：敌对 □），否则画圆点（我方 ○）。
## AC-3：敌对目标超出 `radius` 时不丢弃，而是在圆周边缘画三角箭头指方位（只给方位）。
func _draw_group(
	group: String,
	center: Vector2,
	radius: float,
	scale: float,
	forward: Vector2,
	right: Vector2,
	color: Color,
	dot_radius: float,
	hostile: bool
) -> void:
	for node in get_tree().get_nodes_in_group(group):
		if not (node is Node3D):
			continue
		if node.get("alive") == false:
			continue
		var pos := _to_map((node as Node3D).global_position, center, scale, forward, right)
		var decision := edge_marker_for(pos, center, radius)
		if bool(decision["out_of_range"]):
			if hostile:
				_draw_edge_arrow(decision["edge_pos"], decision["angle"], color)
			continue
		if hostile:
			_draw_square(pos, dot_radius, color)
		else:
			draw_circle(pos, dot_radius + 1.0, Color(0.0, 0.0, 0.0, 0.55))
			draw_circle(pos, dot_radius, color)


## AC-3 · 判定一个「已映射到小地图像素坐标」的目标应画在哪里。
##
## 抽成**纯静态函数**（入参/出参都是普通值，不碰节点与 _draw），便于 headless 单测：
## 给定目标像素坐标 `pos`、地图中心 `center`、显示半径 `radius`，返回：
##   - `out_of_range`：目标是否超出 radius（true → 应画边缘箭头，false → 画范围内标记）
##   - `edge_pos`：箭头应落的位置（半径 `radius - EDGE_ARROW_INSET`，沿 center→pos 方向）
##   - `angle`：center→pos 的方向角（弧度，供箭头朝向；也方便测试断言方位）
##
## 注意：`radius` 在 `_draw()` 里是 `min(size) * 0.5 - 2.0` 的**像素**半径；测试可直接
## 传任意数值。两参数几何自洽即可，不依赖真实视口尺寸。
static func edge_marker_for(pos: Vector2, center: Vector2, radius: float) -> Dictionary:
	var offset := pos - center
	var dist := offset.length()
	if dist <= radius:
		return {"out_of_range": false, "edge_pos": pos, "angle": 0.0}
	# 方向：center → 目标；目标恰在中心（dist≈0）时不画箭头（无方位可言）。
	if dist < 0.0001:
		return {"out_of_range": false, "edge_pos": pos, "angle": 0.0}
	var dir := offset / dist
	var edge_pos := center + dir * maxf(radius - EDGE_ARROW_INSET, 0.0)
	return {"out_of_range": true, "edge_pos": edge_pos, "angle": atan2(dir.y, dir.x)}


## 边缘三角箭头相对圆周的内缩像素（避免和圆边框糊在一起）。
const EDGE_ARROW_INSET := 2.0
## 箭头三角形尺寸（像素）：底半宽 / 顶点到背边的长。
const EDGE_ARROW_HALF_BASE := 4.5
const EDGE_ARROW_LENGTH := 9.0


## AC-3 · 在圆周边缘画一个指向 `angle` 方向的三角箭头（形状 △，区别范围内方点 □）。
## 颜色沿用 enemy_color（#FF4738）。带一圈深色描边提升暗背景可读性。
func _draw_edge_arrow(edge_pos: Vector2, angle: float, color: Color) -> void:
	var dir := Vector2(cos(angle), sin(angle))
	var side := Vector2(-dir.y, dir.x)
	var tip := edge_pos + dir * EDGE_ARROW_LENGTH
	var base_center := edge_pos - dir * EDGE_ARROW_LENGTH
	var left := base_center + side * EDGE_ARROW_HALF_BASE
	var right := base_center - side * EDGE_ARROW_HALF_BASE
	# 描边（先画略大的深色三角，再叠主色）
	var outline_scale := 1.35
	var o_tip := edge_pos + dir * EDGE_ARROW_LENGTH * outline_scale
	var o_base := edge_pos - dir * EDGE_ARROW_LENGTH * outline_scale
	var o_left := o_base + side * EDGE_ARROW_HALF_BASE * outline_scale
	var o_right := o_base - side * EDGE_ARROW_HALF_BASE * outline_scale
	draw_colored_polygon(
		PackedVector2Array([o_tip, o_left, o_right]), Color(0.0, 0.0, 0.0, 0.55)
	)
	draw_colored_polygon(PackedVector2Array([tip, left, right]), color)


## 实心方点（M1 敌对标记 □）：带一圈半透明描边提升暗背景下的可读性
func _draw_square(pos: Vector2, half_size: float, color: Color) -> void:
	var outer := half_size + 1.0
	draw_rect(Rect2(pos - Vector2(outer, outer), Vector2(outer, outer) * 2.0), Color(0.0, 0.0, 0.0, 0.55))
	draw_rect(Rect2(pos - Vector2(half_size, half_size), Vector2(half_size, half_size) * 2.0), color)


func _draw_north_marker(center: Vector2, radius: float, scale: float, forward: Vector2, right: Vector2) -> void:
	if _player == null:
		return
	var north_world := _player.global_position + Vector3(0.0, 0.0, -1.0)
	var direction := (_to_map(north_world, center, scale, forward, right) - center).normalized()
	var pos := center + direction * (radius - 13.0)
	var font := ThemeDB.fallback_font
	var text := "N"
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 13)
	draw_string(
		font,
		pos - Vector2(text_size.x * 0.5, -text_size.y * 0.32),
		text,
		HORIZONTAL_ALIGNMENT_LEFT,
		-1,
		13,
		Color(0.95, 0.98, 1.0, 0.85)
	)


## 地图坐标系：返回 [forward, right]（世界 XZ 平面上的单位向量）
func _frame() -> Array:
	var forward := Vector2(0.0, -1.0)
	if rotate_with_player and _camera != null:
		var cam_forward := -_camera.global_transform.basis.z
		var planar := Vector2(cam_forward.x, cam_forward.z)
		if planar.length() > 0.001:
			forward = planar.normalized()
	return [forward, Vector2(-forward.y, forward.x)]


## 世界坐标 → 小地图像素坐标（前方朝上）
func _to_map(world_pos: Vector3, center: Vector2, scale: float, forward: Vector2, right: Vector2) -> Vector2:
	var offset := Vector2(world_pos.x - _player.global_position.x, world_pos.z - _player.global_position.z)
	return center + Vector2(offset.dot(right), -offset.dot(forward)) * scale


func _sector_points(center: Vector2, radius: float) -> PackedVector2Array:
	var points := PackedVector2Array()
	points.append(center)
	var steps := 14
	for i in steps + 1:
		var angle := deg_to_rad(-view_cone_deg * 0.5 + view_cone_deg * float(i) / float(steps))
		points.append(center + Vector2(sin(angle), -cos(angle)) * radius)
	return points