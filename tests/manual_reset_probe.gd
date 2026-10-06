extends Node
## 对局复位闭环 · **双端窗口实测探针**（启动器）
##
## ## 为什么需要它（这是本缺陷的**唯一真实验证**）
##① `tools/verify.sh` 走 `--headless`，**不经过渲染后端**（control_checklist §4-10）；
##   headless 能证明「信号连上了、逻辑跑了」，**证明不了「客户端画面上的面板真的消失了」**。
## ② 更根本：这是**跨端**行为。缺陷形态是「房主正常、客户端卡死」——
##   单端跑绿对这条缺陷**没有任何证明力**（房主本来就有 `close_ui()` 兜底）。
## → 必须两个真实窗口：一个建房、一个加入，走真实的 ENet + 真实渲染。
##
## ## 关键设计：不动 `main.tscn`（ES-4.2 教训③）
## 探针**自带场景**、只做启动器：调 `NetworkManager.host_game/join_game`，
## 房主等齐人后调 `host_start_match()`，由 `NetworkManager` 自己切到 `main.tscn`。
## 观察者挂在 `get_tree().root` 下（不在探针场景下）→ **能活过场景切换**。
## → 收尾零残留，无需清理 `main.tscn`。
##
## ## 自动化说明
## 正常流程是 GUI 驱动（Hub 里点按钮），无法自动跑完 → 本探针**直接调NetworkManager 的
## 同一批公开方法**（`host_game` / `join_game` / `host_start_match`），
## 与 UI 点击走的是同一条代码路径，只跳过了「用鼠标点按钮」这一步。
##
## 用法（**窗口模式**，加 --headless 就测不到渲染）：
##   godot --path . res://tests/manual_reset_probe.tscn -- --role=host --port=7795
##   godot --path . res://tests/manual_reset_probe.tscn -- --role=join --port=7795
## 退出码：0 = 本端全部断言通过。

const ROLE_HOST := "host"
const ROLE_JOIN := "join"

var _role := ROLE_HOST
var _port := 7795
var _observer: Node


func _ready() -> void:
	_parse_args()
	print("[RS] ==== 对局复位闭环 · 双端窗口实测（role=%s port=%d）====" % [_role, _port])
	# 观察者挂到 root 下 → 活过 NetworkManager 的 change_scene_to_file
	_observer = preload("res://tests/manual_reset_observer.gd").new()
	_observer.name = "ResetObserver"
	_observer.setup(_role)
	get_tree().root.add_child.call_deferred(_observer)

	if _role == ROLE_HOST:
		if not NetworkManager.host_game(_port):
			print("[RS] FAIL host_game 失败（端口 %d 可能被占用）" % _port)
			get_tree().quit(1)
			return
		print("[RS] HOST 已建房，等待客户端加入…")
	else:
		if not NetworkManager.join_game("127.0.0.1", _port):
			print("[RS] FAIL join_game 失败")
			get_tree().quit(1)
			return
		print("[RS] CLIENT 已发起加入 127.0.0.1:%d…" % _port)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--role="):
			_role = arg.substr(7)
		elif arg.begins_with("--port="):
			_port = int(arg.substr(7))
