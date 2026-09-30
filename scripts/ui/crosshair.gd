extends Control
class_name DynamicCrosshair
## 动态准星（阶段 2）
##
## 四根刻度 + 中心点，间距由 RecoilSystem 的扩散值驱动：
##   连射 / 移动 → 扩散变大 → 准星张开；静止 / 开镜 → 收缩。
## 另外提供：命中标记（白色）/ 击杀标记（红色）、换弹进度环。

## 最小间距（像素）
@export var min_gap := 5.0
## 最大间距（像素，扩散值 = 1 时）
@export var max_gap := 34.0
## 每根刻度长度
@export var tick_length := 8.0
@export var thickness := 1.6
@export var color := Color(0.88, 0.96, 1.0, 0.9)
## 开镜时的间距
@export var ads_gap := 2.0
@export var dot_radius := 1.3
## 命中标记显示时间
@export var hitmarker_time := 0.18
@export var reload_ring_radius := 22.0

var _spread := 0.0
var _aiming := false
var _hit_timer := 0.0
var _hit_kill := false
var _reload_progress := -1.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(delta: float) -> void:
	if _hit_timer > 0.0:
		_hit_timer = maxf(_hit_timer - delta, 0.0)
		queue_redraw()


func set_spread(spread: float) -> void:
	var clamped := clampf(spread, 0.0, 1.0)
	if absf(clamped - _spread) > 0.002:
		_spread = clamped
		queue_redraw()


func set_aiming(aiming: bool) -> void:
	if aiming != _aiming:
		_aiming = aiming
		queue_redraw()


func show_hitmarker(killed: bool) -> void:
	_hit_kill = killed
	_hit_timer = hitmarker_time
	queue_redraw()


## 传入 0~1 显示换弹进度环，传入负数隐藏
func set_reload_progress(progress: float) -> void:
	var changed := absf(progress - _reload_progress) > 0.01
	_reload_progress = progress
	if changed:
		queue_redraw()


func get_spread() -> float:
	return _spread


func _draw() -> void:
	var center := size * 0.5
	var gap := lerpf(min_gap, max_gap, _spread)
	if _aiming:
		gap = lerpf(gap, ads_gap, 0.8)

	draw_line(center + Vector2(-gap - tick_length, 0.0), center + Vector2(-gap, 0.0), color, thickness, true)
	draw_line(center + Vector2(gap, 0.0), center + Vector2(gap + tick_length, 0.0), color, thickness, true)
	draw_line(center + Vector2(0.0, -gap - tick_length), center + Vector2(0.0, -gap), color, thickness, true)
	draw_line(center + Vector2(0.0, gap), center + Vector2(0.0, gap + tick_length), color, thickness, true)
	draw_circle(center, dot_radius, color)

	if _aiming:
		draw_arc(center, gap + 7.0, 0.0, TAU, 48, Color(color.r, color.g, color.b, 0.3), 1.2, true)

	if _hit_timer > 0.0:
		var alpha := _hit_timer / maxf(hitmarker_time, 0.01)
		var hit_color := Color(1.0, 0.35, 0.3, alpha) if _hit_kill else Color(1.0, 1.0, 1.0, alpha)
		var d := 8.0
		var inner := d * 0.45
		draw_line(center + Vector2(-d, -d), center + Vector2(-inner, -inner), hit_color, 2.0, true)
		draw_line(center + Vector2(d, -d), center + Vector2(inner, -inner), hit_color, 2.0, true)
		draw_line(center + Vector2(-d, d), center + Vector2(-inner, inner), hit_color, 2.0, true)
		draw_line(center + Vector2(d, d), center + Vector2(inner, inner), hit_color, 2.0, true)

	if _reload_progress >= 0.0:
		draw_arc(
			center,
			reload_ring_radius,
			-PI * 0.5,
			-PI * 0.5 + TAU * clampf(_reload_progress, 0.0, 1.0),
			40,
			Color(1.0, 0.8, 0.4, 0.85),
			2.4,
			true
		)