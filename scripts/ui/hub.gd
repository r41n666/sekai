extends Control
## 联机大厅（阶段 3）
##
## 创建房间 / 输入房主 IP 加入房间 / 查看玩家列表 / 房主开始对战；
## 也可以「单人试玩」离线直接进对局。所有联机逻辑都在 NetworkManager（Autoload）里。

@onready var _name_edit: LineEdit = $Center/Card/VBox/NameRow/NameEdit
@onready var _host_port_edit: LineEdit = $Center/Card/VBox/HostRow/HostPortEdit
@onready var _host_button: Button = $Center/Card/VBox/HostRow/HostButton
@onready var _join_ip_edit: LineEdit = $Center/Card/VBox/JoinRow/JoinIpEdit
@onready var _join_port_edit: LineEdit = $Center/Card/VBox/JoinRow/JoinPortEdit
@onready var _join_button: Button = $Center/Card/VBox/JoinRow/JoinButton
@onready var _status_label: Label = $Center/Card/VBox/StatusLabel
@onready var _local_ip_label: Label = $Center/Card/VBox/LocalIpLabel
@onready var _room_panel: VBoxContainer = $Center/Card/VBox/RoomPanel
@onready var _room_title: Label = $Center/Card/VBox/RoomPanel/RoomTitle
@onready var _player_list: VBoxContainer = $Center/Card/VBox/RoomPanel/PlayerList
@onready var _start_button: Button = $Center/Card/VBox/RoomPanel/StartButton
@onready var _wait_label: Label = $Center/Card/VBox/RoomPanel/WaitLabel
@onready var _leave_button: Button = $Center/Card/VBox/RoomPanel/LeaveButton
@onready var _solo_button: Button = $Center/Card/VBox/SoloButton


func _ready() -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	_name_edit.text = "玩家%d" % randi_range(100, 999)
	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_pressed)
	_join_ip_edit.text_submitted.connect(func(_text: String) -> void: _on_join_pressed())
	_start_button.pressed.connect(_on_start_pressed)
	_leave_button.pressed.connect(_on_leave_pressed)
	_solo_button.pressed.connect(_on_solo_pressed)

	NetworkManager.room_changed.connect(_refresh)
	NetworkManager.error_occurred.connect(_on_error)
	NetworkManager.connected_to_server.connect(_on_connected)
	NetworkManager.server_disconnected.connect(_on_server_disconnected)

	_local_ip_label.text = "本机 IP：" + _local_addresses_hint()
	if NetworkManager.last_notice != "":
		_status_label.text = NetworkManager.last_notice
		NetworkManager.last_notice = ""
	_refresh()


## 创建房间
func _on_host_pressed() -> void:
	NetworkManager.player_name = _pick_name()
	var port := _port_of(_host_port_edit)
	_status_label.text = "正在创建房间…"
	if NetworkManager.host_game(port):
		_status_label.text = "房间已创建（端口 %d）：把本机 IP 发给朋友，等他们加入后点「开始对战」。" % port


## 加入房间
func _on_join_pressed() -> void:
	NetworkManager.player_name = _pick_name()
	var ip := _join_ip_edit.text.strip_edges()
	var port := _port_of(_join_port_edit)
	_status_label.text = "正在连接 %s:%d …" % [ip if ip != "" else "127.0.0.1", port]
	NetworkManager.join_game(ip, port)


func _on_start_pressed() -> void:
	NetworkManager.host_start_match()


func _on_leave_pressed() -> void:
	NetworkManager.leave_game()
	_status_label.text = "已离开房间。"


## 离线单人：直接进对局场景
func _on_solo_pressed() -> void:
	NetworkManager.player_name = _pick_name()
	get_tree().change_scene_to_file(NetworkManager.GAME_SCENE)


func _on_connected() -> void:
	_status_label.text = "已加入房间，等待房主开始对战…"


func _on_server_disconnected() -> void:
	_status_label.text = NetworkManager.last_notice


func _on_error(message: String) -> void:
	_status_label.text = message


## 根据房间状态刷新界面
func _refresh() -> void:
	var online := NetworkManager.is_online
	_name_edit.editable = not online
	_host_port_edit.editable = not online
	_join_ip_edit.editable = not online
	_join_port_edit.editable = not online
	_host_button.disabled = online
	_join_button.disabled = online
	_solo_button.disabled = online

	var in_room := NetworkManager.is_in_room()
	_room_panel.visible = in_room
	if not in_room:
		return

	var players := NetworkManager.get_players()
	var ids: Array = players.keys()
	ids.sort()
	_room_title.text = "房间玩家（%d/%d）%s" % [
		ids.size(),
		NetworkManager.MAX_PLAYERS,
		"· 你是房主" if NetworkManager.is_server else "",
	]
	for child in _player_list.get_children():
		child.queue_free()
	for id in ids:
		var text := "★ " if id == 1 else "· "
		text += NetworkManager.get_player_name(id)
		if id == multiplayer.get_unique_id():
			text += "（你）"
		var label := Label.new()
		label.text = text
		_player_list.add_child(label)

	_start_button.visible = NetworkManager.is_server
	_wait_label.visible = not NetworkManager.is_server


func _pick_name() -> String:
	var chosen := _name_edit.text.strip_edges()
	return chosen if chosen != "" else "玩家"


func _port_of(edit: LineEdit) -> int:
	var text := edit.text.strip_edges()
	return int(text) if text.is_valid_int() else NetworkManager.DEFAULT_PORT


## 本机可用的 IPv4（蓝盾 VPN 的 26.x.x.x 也会出现在这里）
func _local_addresses_hint() -> String:
	var found: Array[String] = []
	for address in IP.get_local_addresses():
		if address.count(".") != 3 or address.begins_with("127.") or address == "0.0.0.0":
			continue
		found.append(address)
	if found.is_empty():
		return "未检测到"
	found.sort()
	return ", ".join(found)