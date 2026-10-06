extends Node
## Task #10 ·远程血量同步 —— **双端窗口实测探针**（启动器）
##
## ## 为什么需要它
## ① `tools/verify.sh` 走 `--headless`，**完全不经过渲染后端**（`control_checklist §4-10`）。
##    本 Story 的核心交付是「射手端**看得见**敌方血条」—— 这是**渲染层**的事，headless 证明不了。
## ② 更根本：血量同步是**跨端**行为。单端跑绿不能证明「受害端的血量真的传到了射手端」
##    → 必须两个真实窗口：一个建房、一个加入。
##
## ## 关键设计：不动 `main.tscn`（ES-4.2 教训③）
## 探针**自带场景**、只做启动器：调 `NetworkManager.host_game/join_game`，
## 房主等齐人后调 `host_start_match()`，由 `NetworkManager` 自己切到 `main.tscn`。
## 观察者节点挂在 `get_tree().root` 下（不是探针场景下）→ **能活过场景切换**。
## → 收尾零残留，无需清理 `main.tscn`。
##
## ## 自动化说明
## 正常联机流程是 GUI 驱动（Hub 里点按钮），无法自动跑完 → 本探针**直接调NetworkManager 的
## 同一批公开方法**（`host_game` / `join_game` / `host_start_match`），
## 与 UI 点击走的是同一条代码路径，只跳过了「用鼠标点按钮」这一步。
##
## 用法（**窗口模式**，加 --headless 就测不到渲染）：
##   godot --path . res://tests/manual_health_sync_probe.tscn -- --role=host --port=7791
##   godot --path . res://tests/manual_health_sync_probe.tscn -- --role=join --port=7791
## 退出码：0 = 本端全部断言通过且渲染 0 错误。

const ROLE_HOST := "host"
const ROLE_JOIN := "join"
const PREVIEW_DIR := "res://_healthsync_tmp"

var _role := ROLE_HOST
var _port := 7791
var _observer: Node


func _ready() -> void:
	_parse_args()
	print("[HS] ==== 远程血量同步 · 双端窗口实测（role=%s port=%d）====" % [_role, _port])
	# 观察者挂到 root 下 → 活过 NetworkManager 的 change_scene_to_file
	_observer = preload("res://tests/manual_health_sync_observer.gd").new()
	_observer.name = "HealthSyncObserver"
	_observer.setup(_role, PREVIEW_DIR)
	get_tree().root.add_child.call_deferred(_observer)

	if _role == ROLE_HOST:
		if not NetworkManager.host_game(_port):
			print("[HS] FAIL host_game 失败（端口 %d 可能被占用）" % _port)
			get_tree().quit(1)
			return
		print("[HS] HOST 已建房，等待客户端加入…")
	else:
		if not NetworkManager.join_game("127.0.0.1", _port):
			print("[HS] FAIL join_game 失败")
			get_tree().quit(1)
			return
		print("[HS] CLIENT 已发起加入 127.0.0.1:%d…" % _port)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="):
			_role = arg.substr(7)
		elif arg.begins_with("--port="):
			_port = int(arg.substr(7))
