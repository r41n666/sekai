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

实测结论（2026-10-06，删除观测层后）：7/7 全杀 —— 删观测层没有削弱 C-18 防线。

⚠ 两条**已知的覆盖缺口**（变异体存活，均为 suite 既有覆盖边界，与本轮删除无关，
   记录在此以免后人误以为是新回归；补覆盖请先确认不会与他人在制品冲突）：
  ① `var was_alive := health > 0.0` 改成 `:= false` → **存活**。
     suite 断言的是「`var was_alive` 出现在 `take_damage(amount)` 之前」这个**顺序**，
     以及守卫串里含 `health <= 0.0`，**不检查 was_alive 的求值表达式**。
     （该顺序断言是 ES-4.2 变异测试的产物：更早的「token 存在」版本被证伪。）
  ② `net_confirm_kill` 里 `if victim_id < 0:` 改成 `if false:` → **存活**。
     suite 只断言用到 `resolve_victim_id`，未断言该守卫本身。
  ③ `load_steps` 写错（如 12 → 99）→ **存活**：Godot 不对 load_steps 做强校验，
     实测 6 轮（3 变异 / 3 基线）ERROR 数恒为 1，且该 ERROR 是 `--quit-after`
     提前退出的既有噪声，与 load_steps 无关。故 load_steps 正确性靠 §4-11 的diff 纪律
     与人工核算保证，无自动化守护。
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
    survivors, tool_errors = [], []
    for mid, rel, anchor, repl, desc in MUTANTS:
        print("=" * 74)
        print("[%s] %s" % (mid, desc))
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
        if red:
            print("  → 变异体被杀 ✓")
        else:
            print("  → ⚠ 存活（exit %s）" % rc)
            survivors.append(mid)
    print("=" * 74)
    if tool_errors:
        print("工具缺陷：%s" % ", ".join(tool_errors))
        return 2
    if survivors:
        print("存活 %d/%d：%s" % (len(survivors), len(MUTANTS),
                                   ", ".join(survivors)))
        return 1
    print("全部 %d 个变异体被杀 ✓ —— C-18 守门能力完好" % len(MUTANTS))
    return 0


if __name__ == "__main__":
    sys.exit(main())
