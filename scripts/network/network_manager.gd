extends Node
## 阶段 3：局域网联机管理器（Autoload「NetworkManager」）
##
## 流程：大厅（hub.tscn）创建/加入房间 → 房主开始对战 → 全部切到对局场景（main.tscn）。
##   - 主机：host_game(port) → ENetMultiplayerPeer.create_server，默认端口 7777
##   - 客户端：join_game(ip, port) → create_client；蓝盾 VPN 下直接用 26.x.x.x 虚拟 IP
##   - 对局：各端按（服务端广播的）玩家列表在本地创建同一批玩家节点，迟到加入也能直接看到所有人；
##     位置/朝向走 MultiplayerSynchronizer，开火特效与伤害走 RPC（见 weapon.gd / player.gd）
##
## TODO(阶段3+)：断线重连、观战、队伍/兵种/出生点选择、服务器列表。

signal server_started
signal join_started
signal connected_to_server
signal connection_failed
signal server_disconnected
signal room_changed
signal error_occurred(message: String)
signal match_started

const DEFAULT_PORT := 7777
const MAX_PLAYERS := 4
const HUB_SCENE := "res://scenes/hub/hub.tscn"
const GAME_SCENE := "res://scenes/main.tscn"
const GRENADE_SCENE := preload("res://scenes/weapons/grenade_projectile.tscn")

## 本地玩家昵称（大厅里设置，加入房间时上报给主机）
var player_name := "玩家"
var is_online := false
var is_server := false
var in_game := false
## 一条提示信息（跨场景保留，大厅加载时显示，例如“与主机断开连接”）
var last_notice := ""

var _players: Dictionary = {}   # peer_id -> 昵称


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


## 主机：创建房间
func host_game(port: int = DEFAULT_PORT) -> bool:
	if is_online:
		return false
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MAX_PLAYERS - 1)
	if err != OK:
		error_occurred.emit("创建房间失败：端口 %d 可能已被占用" % port)
		return false
	multiplayer.multiplayer_peer = peer
	is_online = true
	is_server = true
	in_game = false
	_players = {1: player_name}
	server_started.emit()
	room_changed.emit()
	return true


## 客户端：加入房间
func join_game(address: String, port: int = DEFAULT_PORT) -> bool:
	if is_online:
		return false
	var addr := address.strip_edges()
	if addr == "":
		addr = "127.0.0.1"
	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(addr, port)
	if err != OK:
		error_occurred.emit("无法发起连接：请检查 IP 与端口")
		return false
	multiplayer.multiplayer_peer = peer
	is_online = true
	is_server = false
	in_game = false
	join_started.emit()
	room_changed.emit()
	return true


## 离开房间 / 退出对局（主机离开 = 解散房间，客户端会被断开）
func leave_game() -> void:
	var was_in_game := in_game
	_reset_session()
	room_changed.emit()
	if was_in_game:
		get_tree().change_scene_to_file(HUB_SCENE)


## 主机：开始对战（把所有端切到对局场景）
func host_start_match() -> void:
	if not is_server or in_game:
		return
	in_game = true
	match_started.emit()
	_start_match.rpc()
	get_tree().change_scene_to_file(GAME_SCENE)


func get_players() -> Dictionary:
	return _players.duplicate()


func get_player_name(id: int) -> String:
	return str(_players.get(id, "玩家%d" % id))


func get_my_name() -> String:
	return player_name


## 房间是否已建立（主机已建房，或客户端已成功连上主机）
func is_in_room() -> bool:
	if not is_online:
		return false
	if is_server:
		return true
	var peer := multiplayer.multiplayer_peer
	return peer != null and peer.get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED


func _reset_session() -> void:
	var peer := multiplayer.multiplayer_peer
	if peer != null:
		peer.close()
	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	is_online = false
	is_server = false
	in_game = false
	_players.clear()


func _on_peer_connected(_id: int) -> void:
	pass # 昵称会在 _register_name 里上报


func _on_peer_disconnected(id: int) -> void:
	if not is_server:
		return
	_players.erase(id)
	_sync_player_list.rpc(_players)
	room_changed.emit()


func _on_connected_to_server() -> void:
	_register_name.rpc_id(1, player_name)
	connected_to_server.emit()
	room_changed.emit()


func _on_connection_failed() -> void:
	_reset_session()
	last_notice = "连接失败：请检查 IP/端口/防火墙，并确认房主已创建房间"
	error_occurred.emit(last_notice)
	room_changed.emit()


func _on_server_disconnected() -> void:
	var was_in_game := in_game
	_reset_session()
	last_notice = "与主机断开连接，已返回大厅"
	if was_in_game:
		get_tree().change_scene_to_file(HUB_SCENE)
	server_disconnected.emit()
	error_occurred.emit(last_notice)
	room_changed.emit()


## 客户端上报昵称（发给主机）
@rpc("any_peer", "call_remote", "reliable")
func _register_name(name: String) -> void:
	if not is_server:
		return
	var id := multiplayer.get_remote_sender_id()
	var trimmed := name.strip_edges()
	_players[id] = trimmed if trimmed != "" else "玩家%d" % id
	_sync_player_list.rpc(_players)
	room_changed.emit()
	if in_game:
		# 对局进行中：让新玩家直接进入对局场景（各端会按最新玩家列表补建他的节点）
		_join_game_in_progress.rpc_id(id)


## 主机广播玩家列表
@rpc("authority", "call_remote", "reliable")
func _sync_player_list(players: Dictionary) -> void:
	_players = players
	room_changed.emit()


## 主机广播：所有人切换到对局场景
@rpc("authority", "call_remote", "reliable")
func _start_match() -> void:
	in_game = true
	match_started.emit()
	get_tree().change_scene_to_file(GAME_SCENE)


## 主机通知单人：对局已开始，直接进入对局场景
@rpc("authority", "call_remote", "reliable")
func _join_game_in_progress() -> void:
	in_game = true
	match_started.emit()
	get_tree().change_scene_to_file(GAME_SCENE)


## 联机：玩家位置 / 朝向的持续同步（各端按 ~30Hz 广播；用普通 RPC 而不是场景缓存，迟到加入也能收到）
@rpc("any_peer", "call_remote", "unreliable_ordered")
func net_player_state(pos: Vector3, yaw: float) -> void:
	var scene := get_tree().current_scene
	if scene == null or not scene.has_node("Players"):
		return
	var node := scene.get_node_or_null("Players/%s" % multiplayer.get_remote_sender_id())
	if node != null and node.has_method("apply_network_state"):
		node.apply_network_state(pos, yaw)


## 联机：手雷投掷广播（各端各自模拟一个投掷物；伤害由爆点附近的本地玩家自负）
@rpc("any_peer", "call_remote", "unreliable")
func net_grenade(origin: Vector3, velocity: Vector3) -> void:
	var scene := get_tree().current_scene
	if scene == null:
		return
	var projectile: Node = GRENADE_SCENE.instantiate()
	scene.add_child(projectile)
	if projectile is RigidBody3D:
		(projectile as RigidBody3D).global_position = origin
		(projectile as RigidBody3D).linear_velocity = velocity


## 联机：对训练靶等场景物件的伤害在所有端一起结算（由射击者的武器调用）
@rpc("any_peer", "call_local", "reliable")
func apply_damage_to_target(target_path: String, amount: float, shooter_name: String) -> void:
	var target := get_node_or_null(NodePath(target_path))
	if target == null or not target.has_method("take_damage"):
		return
	var hp_before = target.get("health")
	if hp_before != null and float(hp_before) <= 0.0:
		return
	var fatal: bool = hp_before != null and float(hp_before) - amount <= 0.0
	target.take_damage(amount)
	if not fatal or shooter_name == "":
		return
	# 射击者自己的击杀日志由武器本地写入，这里只补其它端的
	var sender := multiplayer.get_remote_sender_id()
	var from_self := sender == 0 or sender == multiplayer.get_unique_id()
	if from_self:
		return
	var display = target.get("display_name")
	var target_name := str(display) if display != null else String(target.name)
	_push_kill_feed(shooter_name, target_name)


func _push_kill_feed(shooter_name: String, target_name: String) -> void:
	var hud := get_tree().get_first_node_in_group("hud")
	if hud != null and hud.has_method("push_kill"):
		hud.push_kill("%s ➤ %s" % [shooter_name, target_name], true)