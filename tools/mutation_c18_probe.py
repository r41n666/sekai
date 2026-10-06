#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""
mutation_c18_probe.py —— 变异测试：证明 C-18「联机击杀归因」的回归防线是活的。

用途：本轮删除了 G4 临时观测层 scripts/debug/match_debug_probe.gd（EP-4 落地收尾）。
观测层删掉后，「扣血正常却比分恒 0」这类缺陷还守得住吗？本脚本用变异测试回答。

纪律（control_checklist §4-13）：
  · 注入前确认锚点唯一命中；未命中或命中多处 → 非零退出（工具缺陷，不判存活）
  · 注入后校验源码确实变化
  · 注入/还原失败 → 非零退出（「全绿结论」比「红结论」危险得多）
  · 还原后逐字节比对，确保不留变异残留
  本项目已因「锚点不匹配 → 什么都没注入 → 误判存活」栽过两次。

实测结论（2026-10-06，删除观测层后）：
  杀伤组 7/7 全杀—— 删观测层没有削弱 C-18 防线。
  同日加固弱断言后：**杀伤组 13/13 全杀 + 守恒对照组 2/2 仍全绿**（共 15 变异体）。

⚠ 历史记录（ES-4 收尾时一度存在的两条弱断言，**已修**）：
  ① `var was_alive := health > 0.0` 改成 `:= false` → 曾**存活**。
     原因：当时只断言「`var was_alive` 出现在 `take_damage(amount)` 之前」这个**顺序**，
     不看它被赋成什么。修复：新增 `_line_with` / `_has_cmp_zero` 语义级断言，
     要求 `was_alive` 由 `health` 与 0 比较求值。
  ② `net_confirm_kill` 里 `if victim_id < 0:` 改成 `if false:` → 曾**存活**。
     原因：只断言用到了 `resolve_victim_id`，没锁失败分支。
     修复：新增 `test_net_confirm_kill_guards_invalid_victim_id`。

⚠ **弱断言有两个方向，只测一个方向仍不够**（§4-13 的延伸）：
  · 漏杀：真缺陷改了却全绿 → 上面的 ①②。
  · 误杀：语义等价的改写被挡下 → 说明断言退化成了字面量锁，同样是坏断言。
  故本脚本设`EXPECT_GREEN` 守恒对照组：`0.0 < health`（等价比较）、
  `victim_id <= 0`（等价守卫）必须**仍然全绿**。
  对照组若转红，脚本判为「误杀」并以非零退出。

⚠ `load_steps` **故意不加锁**：Godot 不对它做强校验（实测 6 轮：3 变异 / 3 基线，
  ERROR 数恒为 1，且该 ERROR 是 `--quit-after` 提前退出的既有噪声）。
  锁它拦不住真正的加载失败、只给虚假安全感。`load_steps` 正确性
  靠 `ext + sub + 1` 人工核算 + `control_checklist §4-11` 的 diff 纪律保证。
"""
import io
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
GODOT = r"C:\Users\Administrator\Desktop\Godot_v4.7.2-stable_win64_console.exe"

PLAYER = os.path.join("scripts", "player.gd")
WEAPON = os.path.join("scripts", "shooting", "weapon.gd")
KNIFE = os.path.join("scripts", "shooting", "knife.gd")

# ── 变异体：每个都针对 test_kill_attribution.gd 里真实存在的断言 ──────────
MUTANTS = [
    (
        "C2_was_alive_constant_false",
        PLAYER,
        "\tvar was_alive := health > 0.0\n\ttake_damage(amount)\n",
        "\tvar was_alive := false\n\ttake_damage(amount)\n",
        "was_alive 赋恒 false（**顺序仍正确**）→ 断言「必须由 health 求值」",
    ),
    (
        "C3_was_alive_constant_true",
        PLAYER,
        "\tvar was_alive := health > 0.0\n\ttake_damage(amount)\n",
        "\tvar was_alive := true\n\ttake_damage(amount)\n",
        "was_alive 赋恒 true → 防止只挡 false 方向的半边断言",
    ),
    (
        "C4_was_alive_threshold_changed",
        PLAYER,
        "\tvar was_alive := health > 0.0\n\ttake_damage(amount)\n",
        "\tvar was_alive := health > 100.0\n\ttake_damage(amount)\n",
        "was_alive 阈值被改成 100（仍含 health 与 >）→ 断言「与 0 比较」",
    ),
    (
        "C4b_was_alive_threshold_fractional",
        PLAYER,
        "\tvar was_alive := health > 0.0\n\ttake_damage(amount)\n",
        "\tvar was_alive := health > 0.5\n\ttake_damage(amount)\n",
        "was_alive 阈值被改成 0.5 → 防「`0` 匹配 `0.5` 前缀」的正则陷阱（单元测试实测）",
    ),
    (
        "C5_was_alive_snapped_back_to_comparison",
        PLAYER,
        "\tvar was_alive := health > 0.0\n\ttake_damage(amount)\n",
        "\tvar was_alive := 0.0 < health\n\ttake_damage(amount)\n",
        "was_alive 改成等价写法 `0.0 < health` → **必须仍然全绿**（守恒性对照）",
    ),
    (
        "H_victim_guard_disabled",
        PLAYER,
        "\tif victim_id < 0:\n\t\treturn # 双保险：节点名不是 peer id（非玩家节点）→ 不上报\n",
        "\tif false:\n\t\treturn # 双保险：节点名不是 peer id（非玩家节点）→ 不上报\n",
        "摘掉 victim_id < 0 守卫 → 断言「必须校验 victim_id」",
    ),
    (
        "H2_victim_guard_no_return",
        PLAYER,
        "\tif victim_id < 0:\n\t\treturn # 双保险：节点名不是 peer id（非玩家节点）→ 不上报\n",
        "\tif victim_id < 0:\n\t\tpass # 双保险：节点名不是 peer id（非玩家节点）→ 不上报\n",
        "守卫条件在但不 return → 断言「守卫成立必须早退」",
    ),
    (
        "H3_victim_guard_leq_variant",
        PLAYER,
        "\tif victim_id < 0:\n\t\treturn # 双保险：节点名不是 peer id（非玩家节点）→ 不上报\n",
        "\tif victim_id <= 0:\n\t\treturn # 双保险：节点名不是 peer id（非玩家节点）→ 不上报\n",
        "守卫改成等价的 `<= 0` → **必须仍然全绿**（证明不是字面量锁）",
    ),
    (
        "A_kill_confirm_call_removed",
        PLAYER,
        "\t\tnet_confirm_kill.rpc_id(shooter_peer_id)\n",
        "\t\tpass\n",
        "删掉 net_confirm_kill.rpc_id 回传 → 对应断言「受害端归零后必须回传」",
    ),
    (
        "B_was_alive_moved_after_damage",
        PLAYER,
        "\tvar was_alive := health > 0.0\n\ttake_damage(amount)\n",
        "\ttake_damage(amount)\n\tvar was_alive := health > 0.0\n",
        "把 was_alive 挪到扣血之后 → 对应断言「求值顺序」",
    ),
    (
        "C_guard_no_longer_depends_on_was_alive",
        PLAYER,
        "if was_alive and health <= 0.0 and shooter_peer_id > 0:",
        "if health <= 0.0 and shooter_peer_id > 0:",
        "回传守卫不再依赖 was_alive → 对应断言「守卫应为 was_alive and health<=0」",
    ),
    (
        "D_report_local_kill_removed",
        PLAYER,
        "\tscore._report_local_kill(victim_id)\n",
        "\tpass\n",
        "不回调 ScoreManager 上报 → 对应断言「转调 _report_local_kill」",
    ),
    (
        "E_resolve_victim_removed",
        PLAYER,
        "\tvar victim_id := ScoreManager.resolve_victim_id(self)\n",
        "\tvar victim_id := 0\n",
        "不再用 resolve_victim_id 解析被击倒者 → 对应断言「必须用 resolve_victim_id」",
    ),
    (
        "F_rpc_annotation_removed",
        PLAYER,
        '@rpc("authority", "call_remote", "reliable")\nfunc net_confirm_kill',
        "func net_confirm_kill",
        "去掉 @rpc 注解 → 对应断言「必须是 @rpc / call_remote」",
    ),
    (
        "G_weapon_shoots_network_damage_locally",
        WEAPON,
        "\t\t\tcollider.apply_network_damage.rpc_id(\n"
        "\t\t\t\tcollider.get_multiplayer_authority(), damage, _shooter_peer_id()\n"
        "\t\t\t)\n",
        "\t\t\tcollider.take_damage(damage)\n",
        "射手端改回本地扣血 → 对应断言「远程伤害必须走 apply_network_damage.rpc_id」",
    ),
]


def _read(p):
    with io.open(p, "r", encoding="utf-8", newline="") as f:
        return f.read()


def _write(p, t):
    with io.open(p, "w", encoding="utf-8", newline="") as f:
        f.write(t)


# ── 守恒性对照变异体：语义**等价**，期望测试仍然全绿 ────────────────────
# 这些不是「杀不杀」的问题，而是「会不会误杀」的问题。
# 一个只会搜字面量的弱断言，既可能挡不住真缺陷（漏杀），
# 也可能挡住等价改写（误杀）。两者都是坏断言，故两类都要测。
EXPECT_GREEN = {"C5_was_alive_snapped_back_to_comparison",
                "H3_victim_guard_leq_variant"}


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
    survivors, tool_errors, false_kills = [], [], []
    for mid, rel, anchor, repl, desc in MUTANTS:
        expect_green = mid in EXPECT_GREEN
        tag = "守恒对照" if expect_green else "杀伤"
        print("=" * 74)
        print("[%s][%s] %s" % (mid, tag, desc))
        full = os.path.join(ROOT, rel)
        if not os.path.isfile(full):
            print("  ✗ 工具缺陷：文件不存在 %s" % rel)
            tool_errors.append(mid)
            continue
        src = _read(full)
        n = src.count(anchor)
        if n != 1:
            print("  ✗ 锚点命中 %d 处（要求恰好 1）→ 工具缺陷，不判存活" % n)
            tool_errors.append(mid)
            continue
        mutated = src.replace(anchor, repl, 1)
        if mutated == src:
            print("  ✗ 注入后源码未变化 → 工具缺陷")
            tool_errors.append(mid)
            continue
        _write(full, mutated)
        print("  ✓ 锚点唯一命中，注入成功")
        try:
            red, out, rc = run_tests(ROOT)
        finally:
            _write(full, src)
            if _read(full) != src:
                print("  ✗ 还原失败")
                tool_errors.append(mid)
                continue
        hit = [ln.strip() for ln in out.splitlines()
               if "test_kill_attribution" in ln]
        for h in hit[:3]:
            print("│%s" % h)
        if expect_green:
            if red:
                print("  →✗ 误杀！等价改写被断言挡下 → 断言是字面量锁（弱）")
                false_kills.append(mid)
            else:
                print("  → 等价改写仍全绿 ✓（断言按语义锁，未误杀）")
        else:
            if red:
                print("  → 变异体被杀 ✓")
            else:
                print("  → ⚠ 存活（exit %s）" % rc)
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
    n_kill = len(MUTANTS) - len(EXPECT_GREEN)
    print("杀伤组 %d/%d 全杀 ✓；守恒对照组 %d/%d 仍全绿 ✓ —— C-18 守门能力完好"
          % (n_kill, n_kill, len(EXPECT_GREEN), len(EXPECT_GREEN)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
