extends Control
class_name TeammateIcons
## 屏幕边缘队友图标（阶段 2）
##
## 把组 `friendly` 里每个队友的 3D 位置投影到屏幕，画菱形图标 + 名字 + 距离；
## 超出屏幕或位于摄像机背后时，贴到屏幕边缘显示（战地风格）。

@export var icon_size := 9.0
## 贴边时距离屏幕边缘的留白
@export var edge_margin := 40.0
@export var height_offset := 1.9
@export var name_font_size := 13
@export var ally_color := Color(0.4, 0.95, 0.6, 0.95)
@export var distance_color := Color(0.75, 0.95, 0.85, 0.8)

## 队友图标消费的阵营组（FFA 下为空 → 不绘制任何图标）
@export var ally_group := "friendly"

var _camera: Camera3D


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	if _camera == null:
		_camera = get_tree().get_first_node_in_group("camera") as Camera3D
	queue_redraw()


func _draw() -> void:
	if _camera == null or size.x <= 0.0 or size.y <= 0.0:
		return
	# headless / 无渲染后端时摄像机投影矩阵退化，unproject_position() 会报错，直接跳过绘制
	if RenderingServer.get_rendering_device() == null:
		return
	var viewport_size := get_viewport_rect().size
	if viewport_size.x <= 0.0 or viewport_size.y <= 0.0:
		return
	var projection := _camera.get_camera_projection()
	if is_zero_approx(projection.z.z) or is_zero_approx(projection.y.y):
		return
	# FFA（个人死斗）下没有队友：ally_group 为空时显式早退，让「无队友图标」成为
	# 明确意图而非「空循环恰好不画」的副作用（04_ux §6.2 / ADR-007）。
	var allies := get_tree().get_nodes_in_group(ally_group)
	if allies.is_empty():
		return
	var font := ThemeDB.fallback_font
	var center := size * 0.5
	var half_extent := Vector2(
		maxf(center.x - edge_margin, 1.0),
		maxf(center.y - edge_margin, 1.0)
	)

	for node in allies:
		if not (node is Node3D):
			continue
		var world := (node as Node3D).global_position + Vector3.UP * height_offset
		var screen_pos := _camera.unproject_position(world)
		var on_edge := false

		if _camera.is_position_behind(world):
			screen_pos = _clamp_to_edge(screen_pos - center, center, half_extent)
			on_edge = true
		elif absf(screen_pos.x - center.x) > half_extent.x or absf(screen_pos.y - center.y) > half_extent.y:
			screen_pos = _clamp_to_edge(screen_pos - center, center, half_extent)
			on_edge = true

		var distance := _camera.global_position.distance_to(world)
		_draw_diamond(screen_pos, on_edge)

		var display_name := String(node.name)
		var custom_name = node.get("player_name")
		if custom_name is String and not custom_name.is_empty():
			display_name = custom_name
		var base := screen_pos + Vector2(icon_size + 3.0, icon_size * 0.5)
		draw_string(
			font,
			base,
			display_name,
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			name_font_size,
			ally_color
		)
		draw_string(
			font,
			base + Vector2(0.0, float(name_font_size) + 2.0),
			"%dm" % roundi(distance),
			HORIZONTAL_ALIGNMENT_LEFT,
			-1,
			name_font_size - 2,
			distance_color
		)


func _draw_diamond(pos: Vector2, on_edge: bool) -> void:
	var r := icon_size * (0.75 if on_edge else 1.0)
	var color := ally_color
	if on_edge:
		color = Color(ally_color.r, ally_color.g, ally_color.b, 0.55)
	draw_colored_polygon(
		PackedVector2Array([
			pos + Vector2(0.0, -r),
			pos + Vector2(r, 0.0),
			pos + Vector2(0.0, r),
			pos + Vector2(-r, 0.0),
		]),
		Color(0.0, 0.0, 0.0, 0.45)
	)
	var inner := r * 0.68
	draw_colored_polygon(
		PackedVector2Array([
			pos + Vector2(0.0, -inner),
			pos + Vector2(inner, 0.0),
			pos + Vector2(0.0, inner),
			pos + Vector2(-inner, 0.0),
		]),
		color
	)


## 把屏幕外（或摄像机背后）的点沿中心方向贴到屏幕边缘矩形上
func _clamp_to_edge(direction: Vector2, center: Vector2, half_extent: Vector2) -> Vector2:
	var dir := direction
	if dir.length() < 0.001:
		dir = Vector2(0.0, -1.0)
	dir = dir.normalized()
	var scale_x := half_extent.x / maxf(absf(dir.x), 0.0001)
	var scale_y := half_extent.y / maxf(absf(dir.y), 0.0001)
	return center + dir * minf(scale_x, scale_y)