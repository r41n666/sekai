extends Node3D
# tools/probe_ual_leak.gd
# 目的：查清 `test_ual_source_node_is_cleaned_up_on_model_reload` 失败的原因——
#       重载模型后 MikuModel 下仍残留 1 个 `UalLocomotionSource`。
##到底是**真泄漏**（实现的 bug）还是**测试写错**，必须查清，不能靠猜。
##⚠ 必须是**在场景树内**跑的节点脚本（写成 SceneTree._init() 时节点还没进树，
##   `_ready()` 不触发、`is_inside_tree()` 为 false ⇒ 结论全是假的，本探针已踩过一次）。
## 用法：godot --headless --path . res://tools/probe_ual_leak.tscn

const MikuModelScript := preload("res://scripts/entities/miku_model.gd")
const CAT_MODEL := "res://assets/models/cat_hatsune_miku/cat_hatsune_miku.glb"
const MIKU_MODEL := "res://assets/models/miku/miku.glb"


func _ready() -> void:
	var model = MikuModelScript.new()
	model.model_path = CAT_MODEL
	model.ual_locomotion_enabled = true
	add_child(model)

	print("=== STEP 1: 加载 cat（UAL 开）—— 由 _ready 的 load_model 完成 ===")
	print("  model_loaded=%s  is_ual_active=%s" % [
		str(model.model_loaded), str(model.is_ual_locomotion_active())])
	print("  _ual_loco=%s" % str(model._ual_loco))
	print("  _procedural=%s" % str(model._procedural))
	print("  UAL源节点数=%d" % _count(model))
	print("  子节点: %s" % _names(model))

	print("")
	print("=== STEP 2: 重载到 miku.glb（骨架不匹配 ⇒ 应回退程序化姿态 + 清理 UAL 源）===")
	var ok: bool = model.load_model(MIKU_MODEL)
	print("  load_model 返回 %s" % str(ok))
	print("  is_ual_active=%s  _ual_loco=%s" % [
		str(model.is_ual_locomotion_active()), str(model._ual_loco)])
	print("  _procedural=%s valid=%s" % [str(model._procedural),
		str(model._procedural != null and model._procedural.valid)])
	print("  UAL源节点数=%d  ← 期望0" % _count(model))
	print("  子节点: %s" % _names(model))

	print("")
	print("=== STEP 3: 再重载回 cat（验证功能本身仍正常，不是被上面搞坏了）===")
	model.load_model(CAT_MODEL)
	print("  is_ual_active=%s  UAL源节点数=%d（期望 1）" % [
		str(model.is_ual_locomotion_active()), _count(model)])
	print("  drive_pairs=%s" % str(model._ual_loco.debug_pairs.size() if model._ual_loco != null else -1))

	print("")
	print("=== STEP 4: 反复重载 5 次，看 UAL 源节点会不会累积（泄漏的判定性证据）===")
	for i in 5:
		model.load_model(CAT_MODEL)
		model.load_model(MIKU_MODEL)
	print("  5 轮重载后 UAL源节点数=%d（期望 0；若随轮数增长= 真泄漏）" % _count(model))

	print("")
	print("PROBE_DONE")
	get_tree().quit(0)


func _count(node: Node) -> int:
	var n := 0
	for c in node.get_children():
		if String(c.name) == "UalLocomotionSource":
			n += 1
		n += _count(c)
	return n


func _names(node: Node) -> String:
	var out: Array[String] = []
	for c in node.get_children():
		out.append(String(c.name))
	return str(out)