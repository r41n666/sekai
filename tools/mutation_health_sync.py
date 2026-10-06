#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""变异测试 · Task #10 远程血量同步 —— 验证新增断言**真的有牙齿**。

## 为什么需要这个文件
本项目已因「弱断言（变异后仍全绿）」吃过**三次**亏（ES-4.1 的 `format_clock ceil→floor`、
ES-4.2 的 M3 绕过、ES-4.2 的「锚点不匹配却被当成存活」）。每条关键断言都要做一次变异：
把实现改成「错的样子」，确认对应用例**如期转红**；仍全绿 = 断言是弱的，必须重写。

## 纪律（本脚本自身踩过的坑，务必保持）
1. **注入必须校验**：注入后源码要与备份不同，否则报 `NOT_APPLIED`。
2. **注入失败 ≠ 存活**：两者分开计数，且**注入失败也要让本脚本非零退出**
   （早期版本注入全失败却打印 "MUTATION PASS" —— 全绿结论比红结论危险得多）。
3. **只改一份文件时不碰其它文件**（避免误伤工作区）；收尾 `finally` 里还原 + 自检。

用法：
    python tools/mutation_health_sync.py
退出码：0 = 全部变异体被杀死；1 = 有存活（弱断言）或注入失败
"""

import io
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PLAYER = os.path.join(ROOT, "scripts", "player.gd")
NETWORK = os.path.join(ROOT, "scripts", "network", "network_manager.gd")
BARS = os.path.join(ROOT, "scripts", "ui", "enemy_health_bars.gd")
BAK_DIR = os.path.join(ROOT, ".tmpdbg", "mutation_health_sync")
GODOT = os.environ.get(
    "GODOT_BIN", "C:/Users/Administrator/Desktop/Godot_v4.7.2-stable_win64_console.exe"
)

SUITE = "test_health_sync"


def read(path):
    with io.open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    with io.open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def snapshot():
    """备份全部可能被改动的文件，返回 {路径: 原文}。"""
    return {p: read(p) for p in (PLAYER, NETWORK, BARS)}


def restore_all(snap):
    for path, text in snap.items():
        write(path, text)


def run_failures():
    """跑一次 headless runner，返回 (失败数, 失败用例名列表)。"""
    proc = subprocess.run(
        [GODOT, "--headless", "--path", ROOT, "res://tests/test_runner.tscn"],
        capture_output=True, text=True, timeout=300, errors="replace",
    )
    out = proc.stdout + proc.stderr
    m = re.search(r"用例\s+(\d+)\s+｜\s+断言\s+(\d+)\s+｜\s+失败\s+(\d+)", out)
    if not m:
        return None, []
    failed = sorted(set(re.findall(re.escape(SUITE) + r"\.([A-Za-z0-9_]+)", out)))
    return int(m.group(3)), failed


# ══════════════════════════════════════════════════════════════════════
#  变异体定义：(名称, 期望转红的用例, 变异函数)
#  变异函数签名：base(=全部基线源码 dict) -> mutated dict；锚点未命中 raise AssertionError
# ══════════════════════════════════════════════════════════════════════


def _patch(base, path_key, old, new, count=1):
    """在 base[path_key] 里替换 old→new；锚点未命中直接 raise（绝不静默跳过）。"""
    src = base[path_key]
    assert old in src, "锚点未命中：%s / %r" % (path_key, old[:60])
    return dict(base, **{path_key: src.replace(old, new, count)})


def m1_remove_clamp(base):
    """M1 去掉 clamp（写库前不再夹取，越界值可写进显示副本）。"""
    return _patch(
        base, PLAYER,
        "\tvar clamped := clamp_display_health(value, maximum)",
        "\tvar clamped := value",
    )


def m2_remove_invalid_guard(base):
    """M2 去掉非法值守卫（NaN / 负数 / 超上限直接写进显示副本）。"""
    return _patch(
        base, PLAYER,
        "\tif not _is_valid_display_health(value, maximum):\n"
        "\t\treturn # 非法值 → 丢弃，保持上一有效值（不清零、不 clamp 成「看起来合法」的错值）",
        "\tif false:\n\t\treturn",
    )


def m3_shooter_deducts_locally(base):
    """M3 让射手端也本地扣血（C-18 教训的反面：两套血量口径打架）。"""
    return _patch(
        base, PLAYER,
        "\t_display_health = clamped\n\tremote_health_changed.emit(clamped, maximum)",
        "\t_display_health = clamped\n"
        "\thealth = maxf(health - 10.0, 0.0)\n"
        "\tremote_health_changed.emit(clamped, maximum)",
    )


def m4_every_frame_broadcast(base):
    """M4 把广播提到每帧（带宽拉爆 —— 30Hz 门控被顺手删掉）。"""
    return _patch(
        base, PLAYER,
        "\t\tif _net_accum >= NET_SYNC_INTERVAL:\n\t\t\t_net_accum = 0.0\n"
        "\t\t\tNetworkManager.net_player_state.rpc(global_position, _model.rotation.y, health)",
        "\t\tNetworkManager.net_player_state.rpc(global_position, _model.rotation.y, health)",
    )


def m5_triggers_local_death(base):
    """M5 远端掉血把射手端带进死亡流程（替受害端决定生死）。"""
    return _patch(
        base, PLAYER,
        "\t_display_health = clamped\n\tremote_health_changed.emit(clamped, maximum)",
        "\t_display_health = clamped\n"
        "\thealth = 0.0\n"
        "\tdied.emit()\n"
        "\t_enter_dead_state()\n"
        "\tremote_health_changed.emit(clamped, maximum)",
    )


def m6_arity_mismatch(base):
    """M6 广播端与接收端实参个数不一致（发送 3 参 / 转发 2 参 —— 运行期才炸）。"""
    return _patch(
        base, NETWORK,
        "\t\tnode.apply_network_state(pos, yaw, health_value)",
        "\t\tnode.apply_network_state(pos, yaw)",
    )


def m7_bars_settle_damage(base):
    """M7 敌方血条反手去改对方血量（显示控件越权改权威数据）。"""
    return _patch(
        base, BARS,
        "\t\tif not node.has_method(\"get_display_health\"):\n\t\t\tcontinue",
        "\t\tif node.has_method(\"take_damage\"):\n"
        "\t\t\tnode.call(\"take_damage\", 1.0)\n"
        "\t\tif not node.has_method(\"get_display_health\"):\n\t\t\tcontinue",
    )


def m8_reuse_health_changed_signal(base):
    """M8 复用 `health_changed` 发远端显示值（观测层会把显示态误读成本端结算）。"""
    return _patch(
        base, PLAYER,
        "\tremote_health_changed.emit(clamped, maximum)",
        "\thealth_changed.emit(clamped, maximum)",
    )


def m9_loosen_low_health_cue(base):
    """M9 低血只靠颜色表达（撤掉刻度缺口 = 撤掉非颜色第二线索）。"""
    return _patch(
        base, BARS,
        "\tfor i in range(1, 4):\n"
        "\t\tvar x := origin.x + bar_width * 0.25 * float(i)\n"
        "\t\tdraw_rect(Rect2(Vector2(x, origin.y), Vector2(notch_width, bar_height)), back_color, true)\n",
        "",
    )


MUTANTS = [
    ("M1 去掉 clamp", "test_display_health_path_does_not_settle_or_kill_locally", m1_remove_clamp),
    ("M2 去掉非法值守卫", "test_invalid_display_health_is_discarded_keeping_last_valid", m2_remove_invalid_guard),
    ("M3 射手端也本地扣血", "test_remote_health_does_not_deduct_local_health", m3_shooter_deducts_locally),
    ("M4 广播提到每帧", "test_sync_interval_unchanged_and_still_gated", m4_every_frame_broadcast),
    ("M5 远端掉血触发本地死亡", "test_remote_health_zero_does_not_emit_died", m5_triggers_local_death),
    # ⚠ M6 由 `test_rpc_call_sites_pass_three_arguments` 抓住，而不是反射那条 ——
    #   因为 M6 改的是**调用点实参**，两侧 `func` 形参声明都还是 3 个 → 反射当然看不出差异。
    #   （这正是为什么「签名一致性」要**两条**断言：反射管声明、源码管调用。）
    ("M6 收发实参个数不一致", "test_rpc_call_sites_pass_three_arguments", m6_arity_mismatch),
    ("M7 敌方血条反手改血量", "test_enemy_health_bars_wired_into_hud_and_read_only", m7_bars_settle_damage),
    ("M8 复用 health_changed 信号", "test_remote_health_uses_a_separate_signal", m8_reuse_health_changed_signal),
    ("M9 低血只靠颜色", "test_enemy_health_bars_has_brightness", m9_loosen_low_health_cue),
]


def main():
    os.makedirs(BAK_DIR, exist_ok=True)
    base = snapshot()
    for path, text in base.items():
        write(os.path.join(BAK_DIR, os.path.basename(path) + ".bak"), text)

    print("变异测试 · Task #10 远程血量同步")
    bf, _ = run_failures()
    if bf is None:
        print("  !! 基线 runner 无输出/超时，终止")
        return 1
    print("基线（未变异）：%d 失败" % bf)
    if bf != 0:
        print("  !! 基线本就不绿，先修基线再谈变异")
        return 1
    print("-" * 62)

    total = killed = 0
    survived, inject_fail = [], []

    try:
        for name, expect_test, fn in MUTANTS:
            total += 1
            restore_all(base)
            try:
                mutated = fn(base)
            except AssertionError as e:
                inject_fail.append("%s（%s）" % (name, e))
                print("  !! 注入失败  %s —— %s" % (name, e))
                continue
            # 注入生效校验：至少一个文件必须真的变了
            if all(mutated[p] == base[p] for p in base):
                inject_fail.append("%s（变异未改变任何源码）" % name)
                print("  !! 注入失败  %s —— 变异后源码与基线相同" % name)
                continue
            restore_all(mutated)

            fails, failed_tests = run_failures()
            if fails is None:
                inject_fail.append("%s（runner 超时/无输出，多半是变异体语法错）" % name)
                print("  !! runner异常 %s" % name)
                continue
            if fails > 0:
                killed += 1
                hit = "✓" if any(expect_test in t for t in failed_tests) else "!"
                print("  %s 变异体被杀  %-30s → 失败 %d  %s"
                      % (hit, name, fails, " ".join(t.replace(SUITE + ".", "")
                                                   for t in failed_tests)))
                if hit == "!":
                    print("       ⚠ 转红用例与预期 %s 不符，请核对" % expect_test)
            else:
                survived.append(name)
                print("  ✗ 变异体存活  %-30s → 仍全绿（弱断言！）" % name)
    finally:
        restore_all(base)

    print("-" * 62)
    dirty = [p for p in base if read(p) != base[p]]
    if dirty:
        print("  !! 源码未还原干净！%s" % dirty)
        return 1
    print("工作区已还原干净")

    print("变异体 %d 个 ｜ 被杀 %d 个 ｜ 存活 %d 个 ｜ 注入失败 %d 个"
          % (total, killed, len(survived), len(inject_fail)))
    if survived:
        print("存活明细：")
        for s in survived:
            print("  ✗ %s → 断言太弱，必须重写" % s)
    if inject_fail:
        print("注入失败明细：")
        for s in inject_fail:
            print("  !! %s" % s)
    if survived or inject_fail:
        print("MUTATION FAIL")
        return 1
    print("MUTATION PASS（全部变异体均被杀死 → 断言有牙齿）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
