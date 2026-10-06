extends Node
## 验收截图工具（改完武器外观 / 角色模型后跑一遍，图在 /tmp/accept，挑好的放进 docs/acceptance/）
##
## 它把 main.tscn 拉起来，然后：四个武器槽各拍「第三人称 + 第一人称」→ 换回旧外观回归一遍
## → 打开 Esc 菜单拍外观 / 皮肤 / 3D 检视 → 逐个切角色模型。
##
## 运行（无头机要 xvfb；本机 Windows 直接 godot --path . res://tools/capture_acceptance.tscn）：
##   xvfb-run -a godot --path . res://tools/capture_acceptance.tscn --rendering-driver opengl3 --resolution 1280x720

const OUT_DIR := "res://_accept_tmp"
## 只想看这几个角色就改这里
const CHARACTERS := [
	"res://assets/models/miku/miku.glb",
	"res://assets/models/miku_nightcord/miku_nightcord.glb",
	"res://assets/models/miku_ps/miku_ps.glb",
	"res://assets/models/miku_statue/miku_statue.glb",
]
## 每个槽的「旧外观」（回归检查用）
const ALT_VARIANTS := {"Rifle": "m4a4", "USP": "pink", "Knife": "hudidao", "Grenade": "porcelain"}

var _main: Node3D
var _player: Node
var _menu: Node


func _ready() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	_main = (load("res://scenes/main.tscn") as PackedScene).instantiate() as Node3D
	add_child(_main)
	await get_tree().create_timer(1.2).timeout
	_player = get_tree().get_first_node_in_group("player")
	_menu = _main.get_node_or_null("GameMenu")
	if _player == null:
		print("[acc] 找不到玩家，退出")
		get_tree().quit()
		return
	await _run()
	print("[acc] 全部完成，截图在 %s" % OUT_DIR)
	get_tree().quit()


func _run() -> void:
	for slot in ["Rifle", "USP", "Knife", "Grenade"]:
		_equip(slot)
		await get_tree().create_timer(0.8).timeout
		await _shot("tp_%s" % slot)
		_player._toggle_first_person()
		await get_tree().create_timer(0.6).timeout
		await _shot("fp_%s" % slot)
		_player._toggle_first_person()
		await get_tree().create_timer(0.4).timeout
	print("[acc] 1) 当前外观拍完")
	for slot in ALT_VARIANTS:
		_equip(slot)
		_player.set_weapon_variant(slot, String(ALT_VARIANTS[slot]))
		await get_tree().create_timer(0.8).timeout
		await _shot("tp_alt_%s_%s" % [slot, ALT_VARIANTS[slot]])
	print("[acc] 2) 旧外观回归拍完")
	if _menu != null:
		_menu.open_ui()
		await get_tree().create_timer(0.6).timeout
		await _shot("menu_rifle")
		_menu._select_slot("Knife")
		await get_tree().create_timer(1.4).timeout
		await _shot("menu_knife")
		_menu._select_slot("Rifle")
		_menu.close_ui()
		await get_tree().create_timer(0.3).timeout
	print("[acc] 3) 菜单拍完")
	var model := _player.get_node_or_null("MikuModel")
	if model != null:
		for path in CHARACTERS:
			if not ResourceLoader.exists(path):
				continue
			model.model_path = path
			model.load_model(path)
			await get_tree().create_timer(1.6).timeout
			await _shot("char_%s" % path.get_base_dir().get_file())
	print("[acc] 4) 角色拍完")


func _equip(slot: String) -> void:
	_player._equip_slot(slot)
	if String(_player._current_slot) != slot:
		_player._equip_slot(slot) # 已经拿在手上的槽再按一次 = 空手，补一次掏出来


func _shot(tag: String) -> void:
	await RenderingServer.frame_post_draw
	var image := get_viewport().get_texture().get_image()
	image.save_png("%s/%s.png" % [OUT_DIR, tag])
	print("[acc] 拍好 %s" % tag)