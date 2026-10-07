extends CanvasLayer
class_name GameMenu
## Esc 菜单（阶段 5 + 武器皮肤 / 3D 检视）
##
## - Esc 开关菜单；打开时释放鼠标并屏蔽玩家输入（移动 / 跳跃 / 开火 / 开镜），关闭后重新锁定鼠标；
## - 左栏：角色选择（扫描 res://assets/models/*/*.glb，点击后切换本地玩家的 MikuModel 模型）；
## - 右栏：武器槽 → 皮肤（WeaponSkin）→ 上面是 3D 检视（武器自转预览）；
##   ⚠ 「外观（模型）」变体列表**已删除**（每个槽只剩 1 个变体，选择冗余）。
##   模型变体（WeaponVariant）仍在此菜单之外生效：装备武器时按 `get_selected()`（默认变体）套用。
## - 退出游戏：联机时先退出房间（NetworkManager.leave_game），再退出进程；
## 与死亡界面 / 人机面板互斥（都在 game_ui 组，打开一个会关掉其它界面）。

const UI_GROUP := "game_ui"

@onready var _model_list: VBoxContainer = $Panel/HBox/LeftVBox/ModelList
@onready var _resume_button: Button = $Panel/HBox/LeftVBox/ResumeButton
@onready var _quit_button: Button = $Panel/HBox/LeftVBox/QuitButton
@onready var _weapon_buttons: GridContainer = $Panel/HBox/RightVBox/WeaponButtons
@onready var _skin_list: VBoxContainer = $Panel/HBox/RightVBox/ListsRow/SkinBox/SkinList
@onready var _preview: WeaponPreview = $Panel/HBox/RightVBox/Preview

var _model_paths: Array[String] = []
## 3D 检视 / 皮肤当前作用的武器槽
var _slot := "Rifle"


func _ready() -> void:
	add_to_group(UI_GROUP)
	visible = false
	_resume_button.pressed.connect(close_ui)
	_quit_button.pressed.connect(_on_quit_pressed)
	_build_weapon_buttons()
	_build_skin_list()
	_build_model_list()
	_refresh_highlight()


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


## 打开菜单：释放鼠标 + 屏蔽玩家输入 + 让 3D 检视转起来
func open_ui() -> void:
	var player := _get_player()
	if player != null and float(player.get_health()) <= 0.0:
		return # 已阵亡：交给死亡界面
	_close_other_uis()
	visible = true
	_refresh_preview()
	_preview.set_preview_active(true)
	_refresh_highlight()
	if player != null and player.has_method("set_input_blocked"):
		player.set_input_blocked(true) # 内部会释放鼠标


func close_ui() -> void:
	if not visible:
		return
	visible = false
	_preview.set_preview_active(false)
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


## 武器槽按钮（步枪 / 手枪 / 蝴蝶刀 / 手雷）
func _build_weapon_buttons() -> void:
	for slot in WeaponSkin.SLOTS:
		var button := Button.new()
		button.text = String(WeaponSkin.WEAPON_NAMES.get(slot, slot))
		button.pressed.connect(_select_slot.bind(slot))
		_weapon_buttons.add_child(button)


## 皮肤按钮（原版 / 伽玛多普勒 / 渐变之色 / 蓝钢）
func _build_skin_list() -> void:
	for skin in WeaponSkin.skins():
		var button := Button.new()
		button.text = String(skin["name"])
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.pressed.connect(_select_skin.bind(String(skin["id"])))
		_skin_list.add_child(button)


func _select_slot(slot: String) -> void:
	_slot = slot
	_refresh_preview()
	_refresh_highlight()


## 换皮肤：记下来 + 立即套到本端武器上 + 刷新 3D 检视
func _select_skin(skin_id: String) -> void:
	WeaponSkin.set_selected(_slot, skin_id)
	var player := _get_player()
	if player != null and player.has_method("set_weapon_skin"):
		player.set_weapon_skin(_slot, skin_id)
	_refresh_preview()
	_refresh_highlight()


func _refresh_preview() -> void:
	_preview.show_weapon(_slot, WeaponSkin.get_selected(_slot))


func _refresh_highlight() -> void:
	var model := _get_local_model()
	var current := model.model_path if model != null else ""
	for i in _model_list.get_child_count():
		var child := _model_list.get_child(i)
		if not (child is Button):
			continue
		var path := _model_paths[i]
		child.text = ("▶ " if path == current else "    ") + _display_name(path)
	for i in _weapon_buttons.get_child_count():
		var button := _weapon_buttons.get_child(i)
		if not (button is Button):
			continue
		var slot: String = WeaponSkin.SLOTS[i]
		button.text = ("▶ " if slot == _slot else "") + String(WeaponSkin.WEAPON_NAMES.get(slot, slot))
	var chosen := WeaponSkin.get_selected(_slot)
	var skins := WeaponSkin.skins()
	for i in _skin_list.get_child_count():
		var button := _skin_list.get_child(i)
		if not (button is Button) or i >= skins.size():
			continue
		var skin_id := String(skins[i]["id"])
		button.text = ("▶ " if skin_id == chosen else "    ") + String(skins[i]["name"])


func _on_quit_pressed() -> void:
	if NetworkManager.is_online:
		NetworkManager.leave_game() # 先退出房间
	get_tree().quit()
