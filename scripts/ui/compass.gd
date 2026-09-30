extends Control
class_name Compass
## 顶部指南针（阶段 2）
##
## 用 _draw() 绘制刻度条：N / NE / E / ... 与世界方位角，随摄像机偏航滚动。
## 约定：世界 -Z 为北（N），+X 为东（E）。

## 横向可见的角度范围
@export var visible_fov := 140.0
## 主刻度间隔（带文字）
@export var major_step := 45.0
## 次刻度间隔
@export var minor_step := 15.0
@export var font_size := 15
@export var tick_color := Color(0.85, 0.95, 1.0, 0.7)
@export var label_color := Color(0.92, 0.98, 1.0, 0.95)
@export var bar_color := Color(0.02, 0.06, 0.1, 0.3)
@export var pointer_color := Color(0.95, 0.98, 1.0, 0.95)

var _heading := 0.0
var _camera: Camera3D


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	if _camera == null:
		_camera = get_tree().get_first_node_in_group("camera") as Camera3D
	if _camera != null:
		_heading = _compute_heading()
	queue_redraw()


func get_heading() -> float:
	return _heading


func _compute_heading() -> float:
	var forward := -_camera.global_transform.basis.z
	return fposmod(rad_to_deg(atan2(forward.x, -forward.z)), 360.0)


func _draw() -> void:
	var font := ThemeDB.fallback_font
	var center_x := size.x * 0.5
	var px_per_deg := size.x / maxf(visible_fov, 1.0)
	var half_fov := visible_fov * 0.5

	draw_rect(Rect2(Vector2.ZERO, size), bar_color)
	draw_line(Vector2(0.0, size.y - 1.0), Vector2(size.x, size.y - 1.0), Color(0.6, 0.85, 1.0, 0.35), 1.0)

	var degrees := 0
	while degrees < 360:
		var delta_deg := wrapf(float(degrees) - _heading, -180.0, 180.0)
		if absf(delta_deg) <= half_fov:
			var x := center_x + delta_deg * px_per_deg
			var is_major := degrees % int(major_step) == 0
			var tick_height := 9.0 if is_major else 5.0
			draw_line(
				Vector2(x, size.y - 4.0 - tick_height),
				Vector2(x, size.y - 4.0),
				tick_color,
				1.4,
				true
			)
			if is_major:
				var text := _label_for(degrees)
				var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
				draw_string(
					font,
					Vector2(x - text_size.x * 0.5, size.y - 18.0),
					text,
					HORIZONTAL_ALIGNMENT_LEFT,
					-1,
					font_size,
					label_color
				)
		degrees += int(minor_step)

	# 中心指针
	draw_colored_polygon(
		PackedVector2Array([
			Vector2(center_x, size.y - 3.0),
			Vector2(center_x - 4.5, size.y - 11.0),
			Vector2(center_x + 4.5, size.y - 11.0),
		]),
		pointer_color
	)


func _label_for(degrees: int) -> String:
	match degrees:
		0:
			return "N"
		45:
			return "NE"
		90:
			return "E"
		135:
			return "SE"
		180:
			return "S"
		225:
			return "SW"
		270:
			return "W"
		315:
			return "NW"
		_:
			return str(degrees)