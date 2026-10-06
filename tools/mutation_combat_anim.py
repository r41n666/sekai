#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
mutation_combat_anim.py —— 变异测试：证明战斗动作（开火/受击/死亡/换弹）的回归防线是活的。

背景：本项目没有任何外部动画素材（18 个模型合计 4 条剪辑，默认模型 miku.glb 零剪辑），
四个战斗动作全部由 MikuCombatAnim（纯逻辑）+ MikuProceduralPose（骨骼摆放）程序化实现。
这套东西「看起来能跑」与「真的对」之间没有自动保障，本脚本用变异测试回答。

纪律（control_checklist §4-13 / §4-16）：
  · 注入前确认锚点唯一命中；未命中或命中多处 → 非零退出（工具缺陷，不判存活）
  · 注入后校验源码确实变化
  · 注入/还原失败 → 非零退出（「全绿结论」比「红结论」危险得多）
  · 还原后逐字节比对，确保不留变异残留
  · **杀伤组 / 守恒对照组显式区分**：守恒组转红即判「误杀」并非零退出（§4-16 双向）

⚠ 弱断言有两个方向，只测一个方向仍不够：
  · 漏杀：真缺陷改了却全绿 —— 下面的杀伤组。
  · 误杀：语义等价的改写被挡下 —— 下面的守恒对照组。
  故 EXPECT_GREEN 里的变异体是**语义等价**的改写，必须**仍然全绿**。

⚠ 本脚本**不使用 `--import`**：实测 `--import` 会触发 Godot 的编辑器布局加载，
  进而把 project.godot 里的 `rendering_device/driver.windows="vulkan"` 整块删掉
  （control_checklist §4-17 的第 5 次复发）。class_name 注册在首次导入后已写入
  .godot/global_script_class_cache.cfg，后续纯 --headless 运行即可。
"""
import io
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
GODOT = r"C:\Users\Administrator\Desktop\Godot_v4.7.2-stable_win64_console.exe"

COMBAT = os.path.join("scripts", "entities", "miku_combat_anim.gd")
POSE = os.path.join("scripts", "entities", "miku_procedural_pose.gd")
MODEL = os.path.join("scripts", "entities", "miku_model.gd")
PLAYER = os.path.join("scripts", "player.gd")
WEAPON = os.path.join("scripts", "shooting", "weapon.gd")
BOT = os.path.join("scripts", "entities", "bot.gd")

# ── 变异体：每个都针对 test_combat_anim.gd 里真实存在的断言 ─────────────────
MUTANTS = [
    # ── ① 包络（alpha envelope）──────────────────────────────────────────
    (
        "K1_fire_envelope_flipped_to_ramp",
        COMBAT,
        "\t\tAction.FIRE:\n\t\t\treturn pow(1.0 - t, FIRE_DECAY_POW)\n",
        "\t\tAction.FIRE:\n\t\t\treturn smoothstep(0.0, 1.0, t)\n",
        "开火包络被改成「渐入」（枪声一响角色先僵住才动）→ 断言「起于 1、终于 0、单调不增」",
    ),
    (
        "K2_death_envelope_became_decay",
        COMBAT,
        "\t\tAction.DEATH:\n\t\t\treturn smoothstep(0.0, 1.0, t)\n",
        "\t\tAction.DEATH:\n\t\t\treturn pow(1.0 - t, FIRE_DECAY_POW)\n",
        "死亡包络被改成衰减（先弹一下再倒）→ 断言「死亡单调不减」",
    ),
    (
        "K3_envelope_progress_unclamped",
        COMBAT,
        "\tvar t := clampf(u, 0.0, 1.0)\n",
        "\tvar t := u\n",
        "进度不再 clamp → 断言「越界进度被夹到端点」（负 delta / 超时 delta 会把骨骼拧坏）",
    ),
    (
        "K4_envelope_ceiling_removed",
        COMBAT,
        "\t\t\treturn 1.0 - smoothstep(RELOAD_PLATEAU, 1.0, t)\n",
        "\t\t\treturn 1.0 - smoothstep(0.0, 1.0, t)\n",
        "换弹去掉保持段 → 断言「起于 1」（t=0 处不再是满强度，手不会先离开弹匣）",
    ),
    # ── ② 死亡不可逆 ────────────────────────────────────────────────────
    (
        "D1_dead_flag_never_set",
        COMBAT,
        "\tif action == Action.DEATH:\n\t\t_dead = true\n",
        "\tif action == Action.DEATH:\n\t\tpass\n",
        "_dead 不再置位 → 断言「死亡后其它动作被拒」（死后还能开枪 / 起身）",
    ),
    (
        "D2_death_does_not_block_others",
        COMBAT,
        "\tif _dead:\n\t\treturn action == Action.DEATH\n",
        "\tif _dead:\n\t\treturn true\n",
        "死亡不再拦截其它动作 → 断言「fire/hit/reload 在死亡后被拒」",
    ),
    (
        "D3_reset_does_not_clear_dead",
        COMBAT,
        "func reset() -> void:\n\t_action = Action.NONE\n\t_elapsed = 0.0\n\t_dead = false",
        "func reset() -> void:\n\t_action = Action.NONE\n\t_elapsed = 0.0",
        "reset() 不清死亡标记 → 断言「reset 后 is_dead() 为 false」（重生后永远起不来）",
    ),
    (
        "D4_death_progress_not_saturated",
        COMBAT,
        "\tif _action == Action.DEATH:\n\t\t_elapsed = total # 倒地后停在「完全倒地」，进度不再无限增长\n\t\treturn\n",
        "\tif _action == Action.DEATH:\n\t\treturn\n",
        "死亡进度不封顶 → 断言「死亡进度封顶在 1.0」",
    ),
    (
        "D5_repeated_death_restarts_progress",
        COMBAT,
        "\t_dead = true\n\t\t_action = action\n\t\t_elapsed = 0.0\n\t\treturn true\n",
        "\tif _dead:\n\t\treturn action == Action.DEATH\n\t_dead = true\n\t\t_action = action\n\t\t_elapsed = 0.0\n\t\treturn true\n",
        "重复死亡会重置进度 → 断言「重复死亡幂等、不倒带重播」",
    ),
    # ── ③ 叠加量语义（纯逻辑 / 渲染分离的关键）──────────────────────────
    (
        "O1_fire_gains_position_channel",
        COMBAT,
        "\t\t\tout[CH_PITCH] = deg_to_rad(FIRE_TORSO_DEG) * w\n",
        "\t\t\tout[CH_PITCH] = deg_to_rad(FIRE_TORSO_DEG) * w\n\t\t\tout[CH_DROP] = -0.3 * w\n",
        "开火偷偷加了位移（下沉）→ 断言「开火不含位置通道」"
        "（位移后坐力归 RecoilSystem 管摄像机，重复表现）",
    ),
    (
        "O2_fire_moves_legs",
        COMBAT,
        "\t\t\tout[CH_PITCH] = deg_to_rad(FIRE_TORSO_DEG) * w\n",
        "\t\t\tout[CH_PITCH] = deg_to_rad(FIRE_TORSO_DEG) * w\n\t\t\tout[CH_LEG] = deg_to_rad(9.0) * w\n",
        "开火动了腿 → 断言「开火只动持械臂 + 躯干」",
    ),
    (
        "O3_hit_moves_legs",
        COMBAT,
        "\t\t\tout[CH_HEAD] = deg_to_rad(HIT_HEAD_DEG) * w\n",
        "\t\t\tout[CH_HEAD] = deg_to_rad(HIT_HEAD_DEG) * w\n\t\t\tout[CH_LEG] = deg_to_rad(12.0) * w\n",
        "受击动了腿 → 断言「受击可叠加在行走之上」（被打中时还在跑，步态不能被改）",
    ),
    (
        "O4_offsets_not_alpha_scaled",
        COMBAT,
        "\tvar w := maxf(alpha, 0.0)\n",
        "\tvar w := 1.0\n",
        "叠加量不再按 alpha 缩放（= 硬切，动作会抽搐）→ 断言「线性缩放」",
    ),
    (
        "O5_sum_offsets_missing_key_as_zero",
        COMBAT,
        "\t\tfor channel in CHANNELS:\n\t\t\ttotal[channel] = float(total[channel]) + float(one.get(channel, 0.0))\n",
        "\t\tfor channel in CHANNELS:\n\t\t\tif not one.has(channel):\n\t\t\t\tcontinue\n\t\t\ttotal[channel] = float(total[channel]) + float(one[channel])\n",
        "求和时改用 has 守卫跳过缺失通道 → **必须仍然全绿**（`get(k,0)` 与 has-守卫"
        "在结果上完全等价：都把缺失通道当0；区别只在防御性写法）",
    ),
    # ── ④ 降级 + 接线口径 ───────────────────────────────────────────────
    (
        "P1_valid_guard_removed_from_fire",
        POSE,
        "func trigger_fire() -> bool:\n\tif not valid:\n\t\treturn false\n",
        "func trigger_fire() -> bool:\n",
        "开火去掉 valid 守卫 → 断言「动作方法必须先判 valid」（无骨骼模型会被拧坏）",
    ),
    (
        "P2_combat_advance_after_valid_check",
        POSE,
        "\tcombat.advance(delta)\n\tif not valid:\n",
        "\tif not valid:\n\t\treturn\n\tcombat.advance(delta)\n\tif not valid:\n",
        "战斗计时挪到 valid 判断之后 → 断言「advance 必须在 valid 判断之前」"
        "（无效姿态下计时永不走，动作卡住）",
    ),
    (
        "R1_remote_death_from_display_health",
        PLAYER,
        "\t_apply_display_health(health_value)\n",
        "\t_apply_display_health(health_value)\n\tif _display_health <= 0.0:\n\t\t_model.play_death()\n",
        "射手端按 _display_health 播死亡 → 断言「远端死亡不得由显示副本驱动」"
        "（§4-9 同源：显示副本不是血量真值）",
    ),
    (
        "R2_combat_action_becomes_rpc",
        MODEL,
        "func play_fire() -> void:\n",
        "@rpc(\"any_peer\", \"call_remote\", \"unreliable\")\nfunc play_fire() -> void:\n",
        "开火动作改成 RPC → 断言「战斗动作不走 RPC」（纯视觉表现，各端本地播）",
    ),
    (
        "W1_fire_action_anchor_removed",
        WEAPON,
        "\t_play_character_fire()\n",
        "",
        "开火动作调用被删 → 断言「与枪声同帧的同步锚点」",
    ),
    (
        "B1_bot_death_action_removed",
        BOT,
        "\t\t_model.play_death()\n",
        "",
        "人机死亡动作被删 → 断言「bot.gd 归零时必须触发死亡动作」",
    ),
]

# ── 守恒性对照变异体：语义**等价**，期望测试仍然全绿 ───────────────────────
# 一个只会搜字面量的弱断言，既可能挡不住真缺陷（漏杀），也可能挡住等价改写（误杀）。
# 两者都是坏断言，故两类都要测（§4-16）。
EXPECT_GREEN = {
    # 「先取夹住的进度再clamp」改成「先 clamp 再算」—— 结果完全等价。
    "C1_clamp_reorder",
    # 触发死亡时改成先置 _action 再置 _dead（顺序不同，语义一致）。
    "C2_dead_flag_order_swap",
    # 缺失通道用 `get(k, 0.0)` 还是 `has` 守卫 —— 两种写法结果完全一致。
    # ⚠ 首轮曾把O5 当成「杀伤组」，结果**存活**：变异体其实与原实现语义等价，
    #   差别只在防御性写法（`get` 兜底 vs `has` 跳过）。
    #   按 §4-16「守恒组转红即误杀」的对称纪律，它属于**守恒对照组**：
    #   断言锁的是「求和结果必须包含全部通道、缺失按 0 处理」这一**语义**，
    #   而不是「必须用 get() 这个写法」。把它留在杀伤组 = 逼后人绕开断言。
    "O5_sum_offsets_missing_key_as_zero",
}


def _read(p):
    with io.open(p, "r", encoding="utf-8", newline="") as f:
        return f.read()


def _write(p, t):
    with io.open(p, "w", encoding="utf-8", newline="") as f:
        f.write(t)


def run_tests(root, timeout=300):
    cmd = [GODOT, "--headless", "--path", root, "res://tests/test_runner.tscn"]
    try:
        p = subprocess.run(cmd, cwd=root, capture_output=True, timeout=timeout)
        out = (p.stdout or b"").decode("utf-8", "replace") + \
              (p.stderr or b"").decode("utf-8", "replace")
        return p.returncode != 0, out, p.returncode
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode("utf-8", "replace")
        return True, out, -1


def main():
    if not os.path.isfile(GODOT):
        print("FAIL 找不到 Godot: %s" % GODOT)
        return 2

    # 守恒对照组以「等价改写」的形式追加（它们与杀伤组走同一注入机制）
    mutants = list(MUTANTS) + [
        (
            "C1_clamp_reorder",
            COMBAT,
            "\tvar t := clampf(u, 0.0, 1.0)\n",
            "\tvar t := clampf(maxf(u, 0.0), 0.0, 1.0)\n",
            "clamp 改写成「先抬下界再夹」→ **必须仍然全绿**（语义等价）",
        ),
        (
            "C2_dead_flag_order_swap",
            COMBAT,
            "\t_dead = true\n\t\t_action = action\n\t\t_elapsed = 0.0\n\t\treturn true\n",
            "\t_action = action\n\t\t_dead = true\n\t\t_elapsed = 0.0\n\t\treturn true\n",
            "死亡触发里 _dead / _action 赋值顺序调换 → **必须仍然全绿**（语义等价）",
        ),
    ]

    survivors, tool_errors, false_kills = [], [], []
    for mid, rel, anchor, repl, desc in mutants:
        expect_green = mid in EXPECT_GREEN
        tag = "守恒对照" if expect_green else "杀伤"
        print("=" * 74)
        print("[%s][%s] %s" % (mid, tag, desc))
        full = os.path.join(ROOT, rel)
        if not os.path.isfile(full):
            print("  x 工具缺陷：文件不存在 %s" % rel)
            tool_errors.append(mid)
            continue
        src = _read(full)
        n = src.count(anchor)
        if n != 1:
            print("  x 锚点命中 %d 处（要求恰好 1）→ 工具缺陷，不判存活" % n)
            tool_errors.append(mid)
            continue
        mutated = src.replace(anchor, repl, 1)
        if mutated == src:
            print("  x 注入后源码未变化 → 工具缺陷")
            tool_errors.append(mid)
            continue
        _write(full, mutated)
        print("  o 锚点唯一命中，注入成功")
        try:
            red, out, rc = run_tests(ROOT)
        finally:
            _write(full, src)
            if _read(full) != src:
                print("  x 还原失败")
                tool_errors.append(mid)
                continue
        hit = [ln.strip() for ln in out.splitlines()
               if "test_combat_anim" in ln]
        for h in hit[:3]:
            print("|%s" % h)
        if expect_green:
            if red:
                print("  -> x 误杀！等价改写被断言挡下 → 断言是字面量锁（弱）")
                false_kills.append(mid)
            else:
                print("  -> 等价改写仍全绿 o（断言按语义锁，未误杀）")
        else:
            if red:
                print("  -> 变异体被杀 o")
            else:
                print("  -> ! 存活（exit %s）" % rc)
                survivors.append(mid)

    print("=" * 74)
    if tool_errors:
        print("工具缺陷：%s" % ", ".join(tool_errors))
        return 2
    if survivors or false_kills:
        if survivors:
            print("存活（漏杀）%d：%s" % (len(survivors), ", ".join(survivors)))
        if false_kills:
            print("误杀 %d：%s" % (len(false_kills), ", ".join(false_kills)))
        return 1
    n_kill = len(mutants) - len(EXPECT_GREEN)
    print("杀伤组 %d/%d 全杀 o；守恒对照组 %d/%d 仍全绿 o —— 战斗动作守门能力完好"
          % (n_kill, n_kill, len(EXPECT_GREEN), len(EXPECT_GREEN)))
    return 0


if __name__ == "__main__":
    sys.exit(main())