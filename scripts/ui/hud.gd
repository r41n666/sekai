extends CanvasLayer
class_name GameHUD
## 战地 5 风格 HUD 根节点（阶段 2）
##
## 只负责「把游戏数据接到界面元件上」，具体绘制交给各子元件：
##   Crosshair      动态准星（扩散值 / 开镜 / 命中标记 / 换弹进度环）
##   Minimap        小地图（_draw() 绘制障碍物、敌我、朝向、罗盘 N）
##   Compass        顶部指南针
##   TeammateIcons  屏幕边缘队友图标（3D → 屏幕投影 + 贴边）
##   HealthRoot     生命值
##   AmmoPanel      弹药 / 装备
##   KillFeed       击杀日志
##
## 数据来源（通过场景组解耦查找）：player / weapon / recoil / camera

## 击杀日志保留时间（秒）
@export var kill_feed_duration := 4.5
## 击杀日志最多同时显示几条
@export var max_kill_lines := 5
## 生命值低于该比例时变红
@export var low_health_ratio := 0.3

@onready var _crosshair: DynamicCrosshair = $Crosshair
@onready var _health_bar: ProgressBar = $HealthRoot/HealthBar
@onready var _health_label: Label = $HealthRoot/HealthLabel
@onready var _mag_label: Label = $AmmoPanel/AmmoRow/MagLabel
@onready var _reserve_label: Label = $AmmoPanel/AmmoRow/ReserveLabel
@onready var _reload_bar: ProgressBar = $AmmoPanel/ReloadBar
@onready var _kill_feed: VBoxContainer = $KillFeed

var _player: Node
var _weapon: Node
var _recoil: Node
var _bound := false


func _ready() -> void:
	_crosshair.set_spread(0.0)
	_reload_bar.visible = false
	_bind()


func _process(_delta: float) -> void:
	if not _bound:
		_bind()
	if _weapon == null or _recoil == null:
		return

	_crosshair.set_spread(_recoil.get_spread())

	var reloading: bool = _weapon.is_reloading()
	_reload_bar.visible = reloading
	if reloading:
		_reload_bar.value = _weapon.get_reload_progress() * 100.0
		_crosshair.set_reload_progress(_weapon.get_reload_progress())
	else:
		_crosshair.set_reload_progress(-1.0)


## 找到玩家 / 武器 / 后坐力系统并连接信号（找不到就下一帧再试）
func _bind() -> void:
	_player = get_tree().get_first_node_in_group("player")
	_weapon = get_tree().get_first_node_in_group("weapon")
	_recoil = get_tree().get_first_node_in_group("recoil")
	if _player == null or _weapon == null or _recoil == null:
		return

	if _player.has_signal("health_changed"):
		if not _player.health_changed.is_connected(_on_health_changed):
			_player.health_changed.connect(_on_health_changed)
		_on_health_changed(_player.get_health(), _player.get_max_health())

	if not _weapon.ammo_changed.is_connected(_on_ammo_changed):
		_weapon.ammo_changed.connect(_on_ammo_changed)
		_weapon.aiming_changed.connect(_on_aiming_changed)
		_weapon.reload_started.connect(_on_reload_started)
		_weapon.reload_finished.connect(_on_reload_finished)
		_weapon.hit_confirmed.connect(_on_hit_confirmed)
	_on_ammo_changed(_weapon.get_mag(), _weapon.get_reserve())

	_bound = true


func _on_health_changed(current: float, maximum: float) -> void:
	_health_bar.max_value = maximum
	_health_bar.value = current
	_health_label.text = "%d" % roundi(current)
	var ratio := current / maxf(maximum, 1.0)
	_health_bar.modulate = Color(1.0, 1.0, 1.0) if ratio > low_health_ratio else Color(1.0, 0.45, 0.4)


func _on_ammo_changed(mag: int, reserve: int) -> void:
	_mag_label.text = "%d" % mag
	_reserve_label.text = "/ %d" % reserve
	_mag_label.modulate = Color(1.0, 0.55, 0.5) if mag == 0 else Color(1.0, 1.0, 1.0)


func _on_aiming_changed(aiming: bool) -> void:
	_crosshair.set_aiming(aiming)


func _on_reload_started(_duration: float) -> void:
	_reload_bar.value = 0.0
	_reload_bar.visible = true


func _on_reload_finished() -> void:
	_reload_bar.visible = false


func _on_hit_confirmed(target_name: String, killed: bool) -> void:
	_crosshair.show_hitmarker(killed)
	if killed:
		push_kill("你  ➤  %s" % target_name, true)


## 往击杀日志里加一条（后续联机阶段可显示队友/敌人的击杀）
func push_kill(text: String, is_kill := false) -> void:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override(
		"font_color",
		Color(1.0, 0.45, 0.38, 0.95) if is_kill else Color(0.85, 0.95, 1.0, 0.9)
	)
	_kill_feed.add_child(label)

	while _kill_feed.get_child_count() > max_kill_lines:
		var oldest := _kill_feed.get_child(0)
		_kill_feed.remove_child(oldest)
		oldest.queue_free()

	var tween := create_tween()
	tween.tween_interval(kill_feed_duration)
	tween.tween_property(label, "modulate:a", 0.0, 0.8)
	tween.tween_callback(label.queue_free)


func get_kill_feed_count() -> int:
	return _kill_feed.get_child_count()