extends CanvasLayer
class_name BotPanel
## H 键人机管理面板（阶段 5）：增减人机数量
##
## 人机由对局场景里的 BotManager 在本端生成（不联网同步），本面板只是它的遥控器。
## 打开面板时释放鼠标并屏蔽玩家输入，关闭后恢复。

const UI_GROUP := "game_ui"

@onready var _count_label: Label = $Panel/VBox/CountLabel
@onready var _add_button: Button = $Panel/VBox/Buttons/AddButton
@onready var _sub_button: Button = $Panel/VBox/Buttons/SubButton
@onready var _clear_button: Button = $Panel/VBox/ClearButton
@onready var _close_button: Button = $Panel/VBox/CloseButton

var _manager: Node = null


func _ready() -> void:
	add_to_group(UI_GROUP)
	visible = false
	_add_button.pressed.connect(_change_count.bind(1))
	_sub_button.pressed.connect(_change_count.bind(-1))
	_clear_button.pressed.connect(_change_count.bind(-99))
	_close_button.pressed.connect(close_ui)
	_bind_manager()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("bot_panel"):
		if is_open():
			close_ui()
		else:
			open_ui()
		get_viewport().set_input_as_handled()
	elif is_open() and event.is_action_pressed("ui_cancel"):
		close_ui()
		get_viewport().set_input_as_handled()


func is_open() -> bool:
	return visible


func open_ui() -> void:
	for ui in get_tree().get_nodes_in_group(UI_GROUP):
		if ui != self and ui.has_method("close_ui") and ui.has_method("is_open") and ui.is_open():
			ui.close_ui()
	visible = true
	_refresh()
	var player := get_tree().get_first_node_in_group("player")
	if player != null and player.has_method("set_input_blocked"):
		player.set_input_blocked(true)


func close_ui() -> void:
	if not visible:
		return
	visible = false
	var player := get_tree().get_first_node_in_group("player")
	if player != null and player.has_method("set_input_blocked"):
		player.set_input_blocked(false)
		player.capture_mouse()


## 找到对局里的 BotManager（对局场景加载后才存在，找不到就下次刷新时再试）
func _bind_manager() -> void:
	_manager = get_tree().get_first_node_in_group("bot_manager")
	if _manager != null and _manager.has_signal("count_changed"):
		_manager.count_changed.connect(_on_count_changed)
	_refresh()


func _change_count(delta: int) -> void:
	if _manager == null or not is_instance_valid(_manager):
		_bind_manager()
	if _manager == null:
		return
	_manager.change_count(delta)
	_refresh()


func _on_count_changed(_alive: int, _maximum: int) -> void:
	_refresh()


func _refresh() -> void:
	if _manager == null or not is_instance_valid(_manager):
		_count_label.text = "人机：未找到管理器"
		return
	_count_label.text = "人机数量：%d / %d" % [_manager.get_alive_count(), _manager.max_bots]