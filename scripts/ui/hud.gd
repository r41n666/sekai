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
##   —— EP-4 起新增一条：**ScoreManager**（比分板 / 结算面板的唯一数据源，附录 A.5）
##   ⚠ ScoreManager 在 `main.tscn` 下与 HUD 平级，按节点名取（不用组查找：
##   ScoreManager 不该被别的东西按「组」语义误用）。

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
@onready var _weapon_label: Label = $AmmoPanel/WeaponLabel
@onready var _reload_bar: ProgressBar = $AmmoPanel/ReloadBar
@onready var _kill_feed: VBoxContainer = $KillFeed
@onready var _leave_button: Button = $LeaveButton
@onready var _scoreboard: Scoreboard = $Scoreboard

var _player: Node
var _weapon: Node
var _recoil: Node
var _bound := false
## ScoreManager 是否已接上比分板（_ready 时序不确定，取不到就每帧重试）
var _scoreboard_bound := false


func _ready() -> void:
	add_to_group("hud") # 供 NetworkManager 推送联机击杀信息
	_crosshair.set_spread(0.0)
	_reload_bar.visible = false
	_leave_button.pressed.connect(_on_leave_pressed)
	_bind()
	# EP-4 ES-4.1：比分板绑ScoreManager.score_changed（附录 A.5）——
	#   UI 只绑信号、不碰 RPC / 不自行判定胜负（胜负口径唯一归 ScoreManager._evaluate_winner）。
	#   ⚠ 时序：HUD 的 _ready 可能早于/晚于 ScoreManager，故用节点名兜底取一次并允许延迟重试。
	_bind_scoreboard()


## EP-4 ES-4.1：把 ScoreManager 接到比分板（取不到时下一帧再试，避免 _ready 顺序问题）。
func _bind_scoreboard() -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var score := scene.get_node_or_null("ScoreManager")
	if score == null:
		return
	_scoreboard.set_local_peer_id(score.local_peer_id())
	_scoreboard.bind(score)
	_scoreboard_bound = true


## 按住 Tab 显示完整榜、松开隐藏（§3.1.1 · 非模态，可边看边打）。
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("scoreboard"):
		_scoreboard.show_full()
	elif event.is_action_released("scoreboard"):
		_scoreboard.hide_full()


## 返回大厅：联机时退出对局；单机时直接回大厅
func _on_leave_pressed() -> void:
	if NetworkManager.is_online:
		NetworkManager.leave_game()
	else:
		get_tree().change_scene_to_file(NetworkManager.HUB_SCENE)


func _process(_delta: float) -> void:
	if not _bound:
		_bind()
	if not _scoreboard_bound:
		_bind_scoreboard() # 延迟兜底：ScoreManager 可能晚于 HUD 就绪
	elif _scoreboard != null:
		_scoreboard.refresh_names()
	if _weapon == null or _recoil == null:
		return

	_crosshair.set_spread(_recoil.get_spread())

	var reloading: bool = _weapon.has_method("is_reloading") and _weapon.is_reloading()
	_reload_bar.visible = reloading
	if reloading:
		_reload_bar.value = _weapon.get_reload_progress() * 100.0
		_crosshair.set_reload_progress(_weapon.get_reload_progress())
	else:
		_crosshair.set_reload_progress(-1.0)


## 找到玩家 / 武器 / 后坐力系统并连接信号（找不到就下一帧再试）
func _bind() -> void:
	_player = get_tree().get_first_node_in_group("player")
	_recoil = get_tree().get_first_node_in_group("recoil")
	if _player == null or _recoil == null:
		return

	if _player.has_signal("health_changed"):
		if not _player.health_changed.is_connected(_on_health_changed):
			_player.health_changed.connect(_on_health_changed)
		_on_health_changed(_player.get_health(), _player.get_max_health())
	if _player.has_signal("weapon_changed"):
		if not _player.weapon_changed.is_connected(_on_weapon_changed):
			_player.weapon_changed.connect(_on_weapon_changed)

	_bind_weapon(get_tree().get_first_node_in_group("weapon"))
	_bound = true


## 切换武器 / 空手：重新绑定并刷新显示
func _on_weapon_changed(weapon: Node) -> void:
	_bind_weapon(weapon)


func _bind_weapon(weapon: Node) -> void:
	_weapon = weapon
	if _weapon != null:
		if _weapon.has_signal("ammo_changed") and not _weapon.ammo_changed.is_connected(_on_ammo_changed):
			_weapon.ammo_changed.connect(_on_ammo_changed)
		if _weapon.has_signal("aiming_changed") and not _weapon.aiming_changed.is_connected(_on_aiming_changed):
			_weapon.aiming_changed.connect(_on_aiming_changed)
		if _weapon.has_signal("reload_started") and not _weapon.reload_started.is_connected(_on_reload_started):
			_weapon.reload_started.connect(_on_reload_started)
		if _weapon.has_signal("reload_finished") and not _weapon.reload_finished.is_connected(_on_reload_finished):
			_weapon.reload_finished.connect(_on_reload_finished)
		if _weapon.has_signal("hit_confirmed") and not _weapon.hit_confirmed.is_connected(_on_hit_confirmed):
			_weapon.hit_confirmed.connect(_on_hit_confirmed)
	_update_weapon_display()


## 武器名 / 弹药显示（空手或近战显示 —）
func _update_weapon_display() -> void:
	_reload_bar.visible = false
	if _weapon == null:
		_weapon_label.text = "空手"
		_mag_label.text = "—"
		_reserve_label.text = ""
		return
	var weapon_name = _weapon.get("display_name")
	_weapon_label.text = String(weapon_name) if weapon_name is String and not String(weapon_name).is_empty() else "武器"
	if _weapon.has_method("get_mag") and _weapon.has_method("get_reserve"):
		_on_ammo_changed(int(_weapon.get_mag()), int(_weapon.get_reserve()))
	else:
		_mag_label.text = "—"
		_reserve_label.text = ""


func _on_health_changed(current: float, maximum: float) -> void:
	_health_bar.max_value = maximum
	_health_bar.value = current
	_health_label.text = "%d" % roundi(current)
	var ratio := current / maxf(maximum, 1.0)
	_health_bar.modulate = Color(1.0, 1.0, 1.0) if ratio > low_health_ratio else Color(1.0, 0.45, 0.4)


func _on_ammo_changed(mag: int, reserve: int) -> void:
	_mag_label.text = "%d" % mag
	_reserve_label.text = "/ %d" % reserve if reserve > 0 else ""
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