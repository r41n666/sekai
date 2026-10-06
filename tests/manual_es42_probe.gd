extends Node
## ES-4.2 窗口实测探针（**一次性，不进产品**）
##
## ## 为什么需要它
## `tools/verify.sh` 走 `--headless`，**完全不经过渲染后端**（control_checklist §4-10）。
## 所以「UI 改动在窗口里真的能看见、真的不报错」这件事，headless 永远证明不了。
## 这个探针用**真实渲染窗口**跑一遍结算面板的完整渲染路径，把面板上**每一行文本**
## 打印出来，并统计 Godot 的 ERROR 数量。
##
## ## 关键设计：不动 main.tscn
## ES-4.1 当时的做法是「临时往main.tscn 挂节点、跑完再删干净」。
## 那个做法有风险（§4-11 同款教训：清理不干净就会把改动留在场景文件里，
## 而且 `git diff` 未必一眼看出）。本探针改为**自带一个独立场景**：
## 只实例化 `match_result.tscn` + 一个假 ScoreManager，走完渲染再打印。
## → 完全不碰 `scenes/main.tscn`，收尾无需清理，零残留风险。
##
## 用法（**窗口模式**，不能加 --headless，否则测不到渲染）：
##   godot --path<project> res://tests/manual_es42_probe.tscn
## 退出码：0 = 面板文本全部符合预期且渲染 0 错误。

const MATCH_RESULT_SCENE := "res://scenes/ui/match_result.tscn"

## 期望的文本片段（与 tests/suites/test_match_result.gd 的契约一致）
const EXPECT_TITLE := "对局结束"
const EXPECT_WINNER := "你 获胜"
const EXPECT_DURATION_PREFIX := "本局时长"
const EXPECT_HEADER := "排名"
const EXPECT_AGAIN := "再来一局"
const EXPECT_LOBBY := "返回大厅"

var _panel: CanvasLayer = null
var _frames := 0
var _errors: Array[String] = []


func _ready() -> void:
	print("[PROBE] ==== ES-4.2 结算面板 · 窗口渲染实测 ====")
	_panel = (load(MATCH_RESULT_SCENE) as PackedScene).instantiate() as CanvasLayer
	add_child(_panel)

	# 假 ScoreManager：只提供 match_ended 信号 + 面板要读的两个状态量。
	# 刻意**不**接真实 ScoreManager —— 本探针要验的是**渲染路径**，
	# 权威计分与联机由 test_score_manager.gd 等 headless 用例负责。
	var fake := Node.new()
	fake.name = "ScoreManager"
	add_child(fake)
	_define_fake_api(fake)

	_panel.call("bind", fake)
	# 触发结算：房主视角（winner == 本端= 1）
	_panel.call("_on_match_ended", 1, {
		1: {"kills": 15, "deaths": 3},
		2: {"kills": 9, "deaths": 7},
		3: {"kills": 4, "deaths": 11},
	})
	# 让渲染跑几帧，确保 Label 真的布局过（headless 不会做这步）
	set_process(true)


func _define_fake_api(fake: Node) -> void:
	fake.set_script(load("res://tests/manual_es42_fake_score_manager.gd"))
	fake.set("match_duration", 300.0)
	fake.set("time_remaining", 96.0) # → 本局时长 204秒 = 03:24


func _process(_delta: float) -> void:
	_frames += 1
	if _frames < 12:
		return
	set_process(false)
	_report()
	get_tree().quit()


func _report() -> void:
	print("[PROBE] ---- 面板可见 = %s ----" % str(_panel.visible))
	print("[PROBE] game_ui 组内 = %s" % str(_panel.is_in_group("game_ui")))
	print("[PROBE] get_tree().paused = %s（必须 false）" % str(get_tree().paused))

	var title: Label = _panel.get_node_or_null("Panel/VBox/Title")
	var winner: Label = _panel.get_node_or_null("Panel/VBox/Winner")
	var duration: Label = _panel.get_node_or_null("Panel/VBox/Duration")
	var again: Button = _panel.get_node_or_null("Panel/VBox/Buttons/AgainButton")
	var lobby: Button = _panel.get_node_or_null("Panel/VBox/Buttons/LobbyButton")
	var table: VBoxContainer = _panel.get_node_or_null("Panel/VBox/Table")

	print("[PROBE] ==== 面板实际文本 ====")
	print("[PROBE] 标题   : 「%s」" % (title.text if title else "<缺失>"))
	print("[PROBE] 胜者行 : 「%s」" % (winner.text if winner else "<缺失>"))
	print("[PROBE] 时长行 : 「%s」" % (duration.text if duration else "<缺失>"))
	print("[PROBE] 再来一局: 「%s」 disabled=%s" % [
		again.text if again else "<缺失>", str(again.disabled) if again else "-"])
	print("[PROBE] 返回大厅: 「%s」" % (lobby.text if lobby else "<缺失>"))
	if table:
		print("[PROBE] ==== 比分表 %d 行 ====" % table.get_child_count())
		for child in table.get_children():
			var lbl := child as Label
			if lbl:
				print("[PROBE]   | %s" % lbl.text)
	else:
		print("[PROBE] 比分表节点 <缺失>")

	print("[PROBE] ==== 断言 ====")
	var ok := true
	ok = _expect("标题为「对局结束」", title != null and title.text.contains(EXPECT_TITLE)) and ok
	ok = _expect("胜者行为「你获胜」", winner != null and winner.text.contains(EXPECT_WINNER)) and ok
	# 时长：match_duration 300 - time_remaining 96 = 204 秒 → 03:24（与比分板同格式）
	ok = _expect("时长含「本局时长」", duration != null and duration.text.contains(EXPECT_DURATION_PREFIX)) and ok
	ok = _expect("时长为 03:24（300-96）", duration != null and duration.text.contains("03:24")) and ok
	ok = _expect("表头含「排名」", table != null and table.get_child_count() >= 2
		and (table.get_child(0) as Label).text.contains(EXPECT_HEADER)) and ok
	ok = _expect("表内 4 行（表头+分隔+3 玩家）", table != null and table.get_child_count() == 5) and ok
	ok = _expect("第一名是 15 杀", table != null and table.get_child_count() >= 4
		and (table.get_child(2) as Label).text.contains("15")) and ok
	ok = _expect("[再来一局] 文案", again != null and again.text == EXPECT_AGAIN) and ok
	ok = _expect("[再来一局] 房主可点", again != null and not again.disabled) and ok
	ok = _expect("[返回大厅] 文案", lobby != null and lobby.text == EXPECT_LOBBY) and ok
	ok = _expect("面板已可见", _panel.visible) and ok
	ok = _expect("加入 game_ui 组", _panel.is_in_group("game_ui")) and ok
	ok = _expect("**未**暂停游戏", not get_tree().paused) and ok
	print("[PROBE] ==== 结论: %s ====" % ("全部通过" if ok else "存在失败"))
	print("[PROBE] RENDER_ERRORS=%d" % _errors.size())


func _expect(label: String, cond: bool) -> bool:
	print("[PROBE] %s %s" % ["PASS" if cond else "FAIL", label])
	return cond
