#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""变异测试 · ES-4.2 结算面板 —— 验证新增断言**真的有牙齿**。

## 为什么需要这个文件
本项目已因「弱断言（变异后仍全绿）」吃过两次亏：一个只断言"标记存在"的断言，
看起来是绿的，实际什么都没锁住。所以每条关键断言都要做一次变异：
把实现改成"错的样子"，确认对应用例**如期转红**；若仍全绿，说明这条断言是弱的，必须重写。

## 纪律（本脚本自身踩过的坑，务必保持）
1. **注入必须校验**：注入后源码要与备份不同，否则报`NOT_APPLIED`。
   ES-4.2 实测踩到：M3 的锚点字符串与源码不匹配 → 什么都没注入 →
   却被当成「变异体存活（弱断言）」→ **把工具缺陷误报成测试缺陷**，
   险些去"重写"一条本来正确的断言。
2. **注入失败 ≠ 存活**：两者必须分开计数，且**注入失败也要让本脚本失败退出**。
   （另一个实测坑：早期版本注入失败时 `TOTAL-KILLED>0` 但判定分支漏判，
   反而打印出 "MUTATION PASS" —— 全绿结论比红结论更危险。）
3. 收尾必须还原源码（`finally` 里restore），且跑完再跑一次 verify 确认工作区干净。

用法：
    python tools/mutation_es42.py
退出码：0 = 全部变异体被杀死；1 = 有存活（弱断言）或注入失败
"""

import io
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "scripts", "ui", "match_result.gd")
BAK = os.path.join(ROOT, ".tmpdbg", "match_result.gd.bak")
GODOT = os.environ.get(
    "GODOT_BIN", "C:/Users/Administrator/Desktop/Godot_v4.7.2-stable_win64_console.exe"
)


def read(path):
    with io.open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    with io.open(path, "w", encoding="utf-8", newline="") as f:
        f.write(text)


def restore():
    shutil.copyfile(BAK, SRC)


def run_failures():
    """跑一次 headless runner，返回 (失败数, 失败用例名列表)。"""
    proc = subprocess.run(
        [GODOT, "--headless", "--path", ROOT, "res://tests/test_runner.tscn"],
        capture_output=True, text=True, timeout=180, errors="replace",
    )
    out = proc.stdout + proc.stderr
    m = re.search(r"用例\s+(\d+)\s+｜\s+断言\s+(\d+)\s+｜\s+失败\s+(\d+)", out)
    if not m:
        return None, []
    failed = sorted(set(re.findall(r"(test_match_result\.[A-Za-z0-9_]+)", out)))
    return int(m.group(3)), failed


# ══════════════════════════════════════════════════════════════════════
#  变异体定义：(名称, 期望转红的用例关键字, 变异函数)
#  变异函数签名：src -> 变异后源码（不做替换校验，由调用方比对）
# ══════════════════════════════════════════════════════════════════════

def m1_pause(src):
    """结算面板暂停游戏（违反 §3.2「不暂停」）。"""
    old = "\t_set_input_blocked(true) # §4-1"
    assert old in src, "M1 锚点未命中"
    return src.replace(
        old, "\tget_tree().paused = true\n\t_set_input_blocked(true) # §4-1", 1)


def m2_client_caption(src):
    """客户端按钮文案谎报「再来一局」。"""
    old = 'return "再来一局" if is_authority else "等待房主…"'
    assert old in src, "M2 锚点未命中"
    return src.replace(old, 'return "再来一局"', 1)


def m3_recompute_winner(src):
    """结算面板自行按 kills 重算胜负（最严重的架构违纪）。"""
    old = "static func winner_text(winner_id: int, local_peer_id: int, names: Dictionary = {}) -> String:"
    assert old in src, "M3 锚点未命中"
    new = old + (
        '\n\tvar __w := winner_id'
        '\n\tfor __k: Variant in _final_scores:'
        '\n\t\tvar __e: Dictionary = _final_scores[__k]'
        '\n\t\tif int(__e.get("kills", 0)) > 0:'
        '\n\t\t\t__w = int(__k)'
        '\n\twinner_id = __w'
    )
    return src.replace(old, new, 1)


def m4_client_button_enabled(src):
    """客户端按钮可点（caption 对，但 disabled 放行）。"""
    old = "\t_again_button.disabled = not can_request_reset(is_authority)"
    assert old in src, "M4 锚点未命中"
    return src.replace(old, "\t_again_button.disabled = false", 1)


def m5_tie_shows_name(src):
    """平局时显示玩家名（误导：明明并列却说某人赢了）。"""
    old = "\tif winner_id == ScoreManager.WINNER_TIE:"
    assert old in src, "M5 锚点未命中"
    return src.replace(old, "\tif false and winner_id == ScoreManager.WINNER_TIE:", 1)


def m6_no_exclusive_close(src):
    """打开时不关闭 game_ui 组内其它界面（破坏 §3.2 互斥）。"""
    old = "\t_close_other_uis()\n\tvisible = true"
    assert old in src, "M6 锚点未命中"
    return src.replace(old, "\tvisible = true", 1)


def m7_duration_with_hours(src):
    """时长改用自带小时的独立格式（与比分板两套口径）。"""
    old = "\treturn Scoreboard.format_clock(seconds)"
    assert old in src, "M7 锚点未命中"
    new = ('\tvar __t := int(ceil(maxf(seconds, 0.0)))'
           '\n\treturn "%02d:%02d:%02d" % [__t / 3600, (__t % 3600) / 60, __t % 60]')
    return src.replace(old, new, 1)


MUTANTS = [
    ("M1 结算面板暂停游戏", "test_open_ui_does_not_pause_the_tree", m1_pause),
    ("M2 客户端按钮谎报「再来一局」", "test_button_caption_client_waits_for_host", m2_client_caption),
    ("M3 结算面板自行重算胜负", "test_does_not_reimplement_winner_evaluation", m3_recompute_winner),
    ("M4 客户端按钮可点", "test_rendered_button_is_disabled_for_client", m4_client_button_enabled),
    ("M5 平局显示玩家名", "test_winner_text_tie_shows_no_player_name", m5_tie_shows_name),
    ("M6 打开时不关闭同组界面", "test_opening_closes_other_group_members", m6_no_exclusive_close),
    ("M7 时长改用带小时的独立格式", "test_format_duration_reuses_scoreboard_clock", m7_duration_with_hours),
]


def main():
    os.makedirs(os.path.dirname(BAK), exist_ok=True)
    shutil.copyfile(SRC, BAK)
    baseline_src = read(BAK)

    print("变异测试 · ES-4.2 结算面板")
    bf, _ = run_failures()
    if bf is None:
        print("  !! 基线runner 无输出/超时，终止")
        return 1
    print("基线（未变异）：%d 失败" % bf)
    if bf != 0:
        print("  !! 基线本就不绿，先修基线再谈变异")
        return 1
    print("-" * 55)

    total = killed = 0
    survived, inject_fail = [], []

    try:
        for name, expect_test, fn in MUTANTS:
            total += 1
            restore()
            # ── 注入（带断言，锚点未命中直接判注入失败，绝不静默跳过）
            try:
                mutated = fn(baseline_src)
            except AssertionError as e:
                inject_fail.append("%s（%s）" % (name, e))
                print("  !! 注入失败  %s —— %s" % (name, e))
                continue
            if mutated == baseline_src:
                inject_fail.append("%s（变异未改变源码）" % name)
                print("  !! 注入失败  %s —— 变异后源码与基线相同" % name)
                continue
            write(SRC, mutated)

            fails, failed_tests = run_failures()
            if fails is None:
                inject_fail.append("%s（runner 超时/无输出，多半是变异体语法错）" % name)
                print("  !! runner异常 %s" % name)
                continue
            if fails > 0:
                killed += 1
                hit = "✓" if any(expect_test in t for t in failed_tests) else "!"
                print("  %s 变异体被杀  %-28s → 失败 %d  %s"
                      % (hit, name, fails, " ".join(t.replace("test_match_result.", "")
                                                   for t in failed_tests)))
                if hit == "!":
                    print("       ⚠ 转红用例与预期 %s 不符，请核对" % expect_test)
            else:
                survived.append(name)
                print("  ✗ 变异体存活  %-28s → 仍全绿（弱断言！）" % name)
    finally:
        restore()

    print("-" * 55)
    # 收尾自检：源码必须已还原
    if read(SRC) != baseline_src:
        print("  !! 源码未还原干净！")
        return 1

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
