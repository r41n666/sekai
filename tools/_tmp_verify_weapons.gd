extends Node
## 临时验证（验证后删除）：武器模型移植 + 角色朝向 + 玩法冒烟
## 运行：godot --headless --path . res://tools/_tmp_verify_weapons.tscn

func _ready() -> void:
	var runner := Runner.new()
	runner.name = "WeaponVerifyRunner"
	get_tree().root.add_child.call_deferred(runner)


class Runner extends Node:
	var _fails := 0
	var _checks := 0

	func _ready() -> void:
		_run()

	func _run() -> void:
		await get_tree().process_frame

		# ---------- 1) 武器模型与贴图 ----------
		var expect := {
			"res://scenes/weapons/rifle.tscn": {"name": "M4A4 突击步枪", "len": [0.6, 1.3]},
			"res://scenes/weapons/usp.tscn": {"name": "USP · 半自动", "len": [0.1, 0.4]},
			"res://scenes/weapons/grenade.tscn": {"name": "手雷", "len": [0.05, 0.3]},
		}
		for path in expect:
			var packed := load(path) as PackedScene
			_check(packed != null, "加载 %s" % path.get_file())
			if packed == null:
				continue
			var inst := packed.instantiate() as Node3D
			add_child(inst)
			await get_tree().process_frame
			var model := inst.get_node_or_null("Model")
			_check(model != null, "%s 有 Model 子节点（真实模型）" % path.get_file())
			var meshes: Array[MeshInstance3D] = []
			_collect(inst, meshes)
			# 排除曳光弹 / 枪口火光等辅助网格
			var gun: MeshInstance3D = null
			for m in meshes:
				var n := String(m.name).to_lower()
				if not n.contains("tracer") and not n.contains("muzzleflash"):
					gun = m
					break
			_check(gun != null, "%s 找到枪械本体网格" % path.get_file())
			if gun != null:
				var aabb: AABB = gun.global_transform * gun.get_aabb()
				var length: float = maxf(aabb.size.x, aabb.size.z) # 朝 +Z 摆放时长度在 Z 轴上
				var want: Array = expect[path]["len"]
				_check(length >= float(want[0]) and length <= float(want[1]),
					"%s 尺寸合理（长 %.3f m，期望 %.2f~%.2f）" % [path.get_file(), length, want[0], want[1]])
				var textured := 0
				var total := 0
				var mesh: Mesh = gun.mesh
				for s in mesh.get_surface_count():
					total += 1
					var mat := mesh.surface_get_material(s)
					if mat is BaseMaterial3D and (mat as BaseMaterial3D).albedo_texture != null:
						textured += 1
					elif mat is StandardMaterial3D and (mat as StandardMaterial3D).albedo_texture != null:
						textured += 1
				_check(textured == total, "%s 每个表面都有贴图（%d/%d）" % [path.get_file(), textured, total])
			_check(String(inst.get("display_name")) == String(expect[path]["name"]),
				"%s display_name = %s" % [path.get_file(), str(inst.get("display_name"))])
			inst.queue_free()
			await get_tree().process_frame

		# ---------- 2) 角色模型朝向（脚尖应比足首更靠 +Z） ----------
		for model_path in ["res://assets/models/miku_navy/miku_navy.glb",
				"res://assets/models/miku_maid/miku_maid.glb", "res://assets/models/miku_maid/miku_maid2.glb"]:
			var scene := load(model_path) as PackedScene
			if scene == null:
				_check(false, "加载 %s" % model_path)
				continue
			var inst := scene.instantiate()
			add_child(inst)
			var skel := _find_skeleton(inst)
			if skel == null:
				_check(false, "%s 有骨架" % model_path)
				inst.queue_free()
				continue
			var ankle := -1
			var toe := -1
			for i in skel.get_bone_count():
				var bone_name := skel.get_bone_name(i)
				if ankle < 0 and bone_name == "右足首":
					ankle = i
				if toe < 0 and bone_name == "右つま先":
					toe = i
			if ankle >= 0 and toe >= 0:
				var dz: float = skel.get_bone_rest(toe).origin.z - skel.get_bone_rest(ankle).origin.z
				_check(dz > 0.0, "%s 面朝 +Z（脚尖 Δz=%+.2f）" % [model_path.get_file(), dz])
			else:
				_check(false, "%s 找到 右足首/右つま先 骨骼" % model_path.get_file())
			inst.queue_free()
			await get_tree().process_frame

		# ---------- 3) 玩法冒烟：武器槽 + 开火 + 人机 ----------
		get_tree().change_scene_to_file("res://scenes/main.tscn")
		for i in 8:
			await get_tree().process_frame
		var player: Node = get_tree().get_first_node_in_group("player")
		_check(player != null, "对局场景里玩家已生成")
		if player != null:
			var slot_map := {"weapon_1": "Rifle", "weapon_2": "USP", "weapon_3": "Knife", "weapon_4": "Grenade"}
			for slot in [["weapon_1", "M4A4 突击步枪"], ["weapon_2", "USP · 半自动"], ["weapon_3", "蝴蝶刀"], ["weapon_4", "手雷"]]:
				player._equip_slot(slot_map[slot[0]])
				await get_tree().process_frame
				if player.get_weapon() == null:
					# 出生时已装备主武器：同键再按一次是「空手」，所以再按一次把它装回来
					player._equip_slot(slot_map[slot[0]])
					await get_tree().process_frame
				var weapon: Node = player.get_weapon()
				var dn := str(weapon.get("display_name")) if weapon != null else "(空手)"
				_check(weapon != null, "装备 %s → %s" % [slot[1], dn])
			player._equip_slot("Rifle")
			await get_tree().process_frame
			var mag_before: int = int(player.get_weapon().get_mag())
			Input.action_press("shoot")
			await _wait_seconds(0.6)
			Input.action_release("shoot")
			await get_tree().process_frame
			var mag_after: int = int(player.get_weapon().get_mag())
			_check(mag_after < mag_before, "M4A4 开火消耗弹药（%d → %d）" % [mag_before, mag_after])

			var manager: Node = get_tree().current_scene.get_node_or_null("Bots")
			manager.change_count(2)
			await get_tree().process_frame
			_check(manager.get_alive_count() == 2, "人机仍可刷新（%d 个）" % manager.get_alive_count())
			manager.change_count(-99)

		_finish()

	func _wait_seconds(seconds: float) -> void:
		var until := Time.get_ticks_msec() + int(seconds * 1000.0)
		while Time.get_ticks_msec() < until:
			await get_tree().process_frame

	func _collect(node: Node, out: Array[MeshInstance3D]) -> void:
		if node is MeshInstance3D:
			out.append(node)
		for child in node.get_children():
			_collect(child, out)

	func _find_skeleton(node: Node) -> Skeleton3D:
		if node is Skeleton3D:
			return node
		for child in node.get_children():
			var found := _find_skeleton(child)
			if found != null:
				return found
		return null

	func _check(ok: bool, message: String) -> void:
		_checks += 1
		if ok:
			print("  [OK] ", message)
		else:
			_fails += 1
			print("  [FAIL] ", message)

	func _finish() -> void:
		print("=== 共 %d 项检查，失败 %d 项 ===" % [_checks, _fails])
		get_tree().quit(1 if _fails > 0 else 0)