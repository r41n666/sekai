extends CanvasLayer
class_name GameMenu
## Esc 菜单（阶段 5）：角色选择 / 退出游戏
##
## - Esc 开关菜单；打开时释放鼠标并屏蔽玩家输入（移动 / 跳跃 / 开火 / 开镜），关闭后重新锁定鼠标；
## - 角色选择：扫描 res://assets/models/*/*.glb 生成列表，点击后切换本地玩家的 MikuModel 模型；
## - 退出游戏：联机时先退出房间（NetworkManager.leave_game），再退出进程；
## 与死亡界面 / 人机面板互斥（都在 game_ui 组，打开一个会关掉其它界面）。

const UI_GROUP := "game_ui"

@onready var _model_list: VBoxContainer = $Panel/VBox/ModelList
@onready var _resume_button: Button = $Panel/VBox/ResumeButton
@onready var _quit_button: Button = $Panel/VBox/QuitButton

var _model_paths: Array[String] = []


func _ready() -> void:
	add_to_group(UI_GROUP)
	visible = false
	_resume_button.pressed.connect(close_ui)
	_quit_button.pressed.connect(_on_quit_pressed)
	_build_model_list()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel"):
		return
	if is_open():
		close_ui()
	elif not _other_ui_open():
		open_ui() # 阵亡状态由死亡界面接管（此时它会拦住 Esc）
	get_viewport().set_input_as_handled()


func is_open() -> bool:
	return visible


## 打开菜单：释放鼠标 + 屏蔽玩家输入
func open_ui() -> void:
	var player := _get_player()
	if player != null and float(player.get_health()) <= 0.0:
		return # 已阵亡：交给死亡界面
	_close_other_uis()
	visible = true
	_refresh_highlight()
	if player != null and player.has_method("set_input_blocked"):
		player.set_input_blocked(true) # 内部会释放鼠标


func close_ui() -> void:
	if not visible:
		return
	visible = false
	var player := _get_player()
	if player != null and player.has_method("set_input_blocked"):
		player.set_input_blocked(false)
		player.capture_mouse()


## 打开其它界面时自动关闭自己（此时不要再抢鼠标，交给要打开的界面）
func _close_other_uis() -> void:
	for ui in get_tree().get_nodes_in_group(UI_GROUP):
		if ui != self and ui.has_method("close_ui") and ui.has_method("is_open") and ui.is_open():
			ui.close_ui()


func _other_ui_open() -> bool:
	for ui in get_tree().get_nodes_in_group(UI_GROUP):
		if ui != self and ui.has_method("is_open") and ui.is_open():
			return true
	return false


func _get_player() -> Node:
	return get_tree().get_first_node_in_group("player")


func _get_local_model() -> MikuModel:
	var player := _get_player()
	if player == null:
		return null
	return player.get_node_or_null("MikuModel") as MikuModel


## 扫描 assets/models/<子目录>/*.glb 生成角色列表（与 BotManager 共用 MikuModel 的扫描实现）
func _build_model_list() -> void:
	_model_paths = MikuModel.list_available_models()
	for path in _model_paths:
		var button := Button.new()
		button.text = _display_name(path)
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(_select_model.bind(path))
		_model_list.add_child(button)
	if _model_paths.is_empty():
		var empty := Label.new()
		empty.text = "没有找到 assets/models/*/*.glb"
		_model_list.add_child(empty)
	_refresh_highlight()


func _display_name(path: String) -> String:
	var parts := path.trim_suffix(".glb").split("/")
	if parts.size() >= 3:
		return "%s / %s" % [parts[parts.size() - 2], parts[parts.size() - 1]]
	return path.get_file()


## 切换本地玩家模型（模型挂载点自己会处理占位胶囊显隐 / 尺寸适配 / 武器挂手）
func _select_model(path: String) -> void:
	var model := _get_local_model()
	if model == null:
		push_warning("GameMenu：找不到本地玩家的 MikuModel，无法切换模型")
		return
	model.model_path = path
	if not model.load_model(path):
		push_warning("GameMenu：模型加载失败 %s" % path)
	_refresh_highlight()


func _refresh_highlight() -> void:
	var model := _get_local_model()
	var current := model.model_path if model != null else ""
	for i in _model_list.get_child_count():
		var child := _model_list.get_child(i)
		if not (child is Button):
			continue
		var path := _model_paths[i]
		child.text = ("▶ " if path == current else "    ") + _display_name(path)


func _on_quit_pressed() -> void:
	if NetworkManager.is_online:
		NetworkManager.leave_game() # 先退出房间
	get_tree().quit()