#!/usr/bin/env bash
#
# tools/verify.sh —— sekai 一键自检（headless 静默验证）
#
# 用途：把「导入 → 脚本可解析性校验 → 测试」固化成一条可重复命令，
#       供每次改动后自检。任一必需环节失败 → 非零退出。
#
# 用法：
#   bash tools/verify.sh            # 静默模式：只打印每环节结论 + 最终退出码
#   bash tools/verify.sh -v         # 详细模式：追加 --import / 测试的完整原始输出
#   GODOT_BIN=/path/to/godot bash tools/verify.sh
#
# 环境变量：
#   GODOT_BIN       Godot 可执行文件路径（可选）。未设置时按顺序探测常见安装位置，最后退回 `godot`。
#   VERIFY_TIMEOUT  单步超时秒数（默认 180）。
#
# 退出码：
#   0   全部环节通过
#   1   有环节失败（--import 失败 / 测试失败 / 步骤超时）
#   2   前置条件不满足（找不到 Godot 可执行文件 / 参数错误）
#
# ---------------------------------------------------------------------------
# 为什么本脚本「不」用裸 `--check-only`（ES-5.5 字面要求的第二步）
# ---------------------------------------------------------------------------
# ES-5.5 原文要求 `--import` → `--check-only` → `test_runner.tscn`。但在本项目实测，
# 裸 `--check-only` 有两种致命用法，都不可用作门禁（2026-10-06 实测）：
#
#   ① `godot --headless --path . --check-only <file>`
#      → 会挂起不退出（本机 4.7.2 实测 timeout 15s 后仍被 kill，exit 124）。
#
#   ② `godot --headless --path . --script <file> --check-only`
#      → 能退出，但该模式**不注册 Autoload**。本项目几乎每个关键脚本都引用
#        `NetworkManager` / `MusicManager`，于是本应「通过」的脚本被误报为：
#            SCRIPT ERROR: Compile Error: Identifier not found: NetworkManager
#        exit code = 1。即：干净的 HEAD 上裸跑这个门禁也会「失败」。
#
# 结论：裸 `--check-only` 在本项目**必然误报**，不适合当门禁。ES-5.5 的**实质意图**
# 是「改动后一键确认脚本可解析 + 测试通过」——而本项目里有更可靠的等价物：
#
#   `test_runner.tscn` 以**普通场景**运行 → Autoload 正常注册 → 会 load+compile 被测脚本。
#   实测：注入语法错误时 runner 会明确报 `Failed to load script ... Parse error`。
#   因此它同时充当「可解析性门禁」+「行为门禁」，正是 ES-5.5 想要的那一步。
#
# 本脚本采用方案 A：`--import`（建类缓存）→ `test_runner.tscn`（解析 + 行为门禁）。
# 另有一个关键运行事实：**runner 在遇到解析错误时不会走到 quit()，会挂起**
# （实测 exit 124）。所以本脚本对 runner 强制加 timeout，并把「超时」判为失败，
# 同时尝试从输出里抓出 `Parse error` 作为失败原因。详见下方 run_runner()。
# ---------------------------------------------------------------------------

set -u

# --- 0. 定位项目根（对当前工作目录不敏感）-----------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT" || { echo "FAIL 无法进入项目根: $PROJECT_ROOT"; exit 2; }

# --- 1. 解析参数 -------------------------------------------------------------
VERBOSE=0
for arg in "$@"; do
	case "$arg" in
		-v|--verbose) VERBOSE=1 ;;
		-h|--help)
			sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0
			;;
		*)
			echo "FAIL 未知参数: $arg（用 --help 查看用法）"
			exit 2
			;;
	esac
done

# --- 2. 探测 Godot 可执行文件 ------------------------------------------------
resolve_godot() {
	if [ -n "${GODOT_BIN:-}" ]; then
		if [ -x "$GODOT_BIN" ] || command -v "$GODOT_BIN" >/dev/null 2>&1; then
			printf '%s' "$GODOT_BIN"
			return 0
		fi
		echo "FAIL GODOT_BIN 指向的文件不可执行: $GODOT_BIN" >&2
		return 1
	fi
	# 常见安装位置（按顺序探测）
	local candidates=(
		"$HOME/Desktop/Godot_v4.7.2-stable_win64_console.exe"
		"$HOME/Desktop/Godot_v4.7.2-stable_win64.exe"
		"/c/Program Files/Godot/godot.exe"
		"/usr/local/bin/godot"
		"/usr/bin/godot"
	)
	local c
	for c in "${candidates[@]}"; do
		if [ -x "$c" ]; then printf '%s' "$c"; return 0; fi
	done
	# 最后退回 PATH 上的 godot
	if command -v godot >/dev/null 2>&1; then printf '%s' "godot"; return 0; fi
	return 1
}

GODOT="$(resolve_godot)"
if [ -z "$GODOT" ]; then
	echo "FAIL 找不到 Godot 可执行文件。请设置环境变量 GODOT_BIN 指向它，例如："
	echo "     GODOT_BIN=/c/path/to/Godot_v4.7.2-stable_win64_console.exe bash tools/verify.sh"
	exit 2
fi

TIMEOUT_SECS="${VERIFY_TIMEOUT:-180}"

# 日志放到项目内的临时目录，避免 Windows 路径下 rm 的安全删除拦截
LOG_DIR="$PROJECT_ROOT/.verify_tmp"
mkdir -p "$LOG_DIR"

# --- 3. 输出辅助 -------------------------------------------------------------
# 详细模式才回显原始输出
dump() {
	if [ "$VERBOSE" -eq 1 ]; then
		echo "----- 原始输出开始 -----"
		cat "$1"
		echo "----- 原始输出结束 -----"
	fi
}

# --- 4. 步骤 1：--import（建资源 / 类缓存）----------------------------------
IMPORT_LOG=""
RUNNER_LOG=""

run_import() {
	local log="$LOG_DIR/import.log"
	timeout "$TIMEOUT_SECS" "$GODOT" --headless --path "$PROJECT_ROOT" --import >"$log" 2>&1
	local rc=$?
	dump "$log"
	if [ "$rc" -eq 0 ]; then
		printf 'PASS  %s\n' "import（资源/类缓存就绪）"
		rm -f "$log"
		return 0
	fi
	if [ "$rc" -eq 124 ]; then
		printf 'FAIL  %s\n' "import（步骤超时 ${TIMEOUT_SECS}s）"
	else
		printf 'FAIL  %s\n' "import（退出码 $rc；GLB/贴图等资源导入失败）"
	fi
	grep -iE "error|failed|could not" "$log" | head -5 | sed 's/^/      /'
	echo "  详见：$log（保留供排查）"
	IMPORT_LOG="$log"
	return 1
}

# --- 5. 步骤 2：脚本可解析性 + 行为门禁（test_runner.tscn）------------------
# 关键：runner 遇到解析错误时**不会走到 quit()，会挂起** → 必须用 timeout，
#       并把超时判为失败，同时抓取输出里的 Parse error 作为原因。
run_runner() {
	local log="$LOG_DIR/runner.log"
	timeout "$TIMEOUT_SECS" "$GODOT" --headless --path "$PROJECT_ROOT" res://tests/test_runner.tscn >"$log" 2>&1
	local rc=$?
	dump "$log"

	# 无论哪种结局，先抓解析错误（作为可读原因）
	local parse_err
	parse_err="$(grep -iE "Parse Error|Failed to load script" "$log" | head -3)"

	if [ "$rc" -eq 124 ]; then
		printf 'FAIL  %s\n' "测试 + 解析（步骤超时 ${TIMEOUT_SECS}s——runner 未走到退出，通常是脚本解析错误导致）"
		[ -n "$parse_err" ] && echo "$parse_err" | sed 's/^/      /'
		echo "  详见：$log（保留供排查）"
		RUNNER_LOG="$log"
		return 1
	fi

	if [ "$rc" -eq 0 ]; then
		# 绿色通道：正常退出 0；但若输出里意外夹带解析错误，也算失败（防御）
		if [ -n "$parse_err" ]; then
			printf 'FAIL  %s\n' "测试 + 解析（退出码 0 但输出含解析错误）"
			echo "$parse_err" | sed 's/^/      /'
			RUNNER_LOG="$log"
			return 1
		fi
		# 抓一行汇总作为结论附注（可选）
		local pass_line
		pass_line="$(grep -E "用例 [0-9]+ ｜" "$log" | tail -1)"
		printf 'PASS  %s\n' "测试 + 解析（$pass_line）"
		rm -f "$log"
		return 0
	fi

	# rc != 0 且非超时：测试失败（runner 正常置了非零退出码）或其它异常
	local summary
	summary="$(grep -E "用例 [0-9]+ ｜|=================== (PASS|FAIL)" "$log" | tail -2)"
	printf 'FAIL  %s\n' "测试 + 解析（退出码 $rc）"
	[ -n "$summary" ] && echo "$summary" | sed 's/^/      /'
	[ -n "$parse_err" ] && echo "$parse_err" | sed 's/^/      /'
	echo "  详见：$log（保留供排查）"
	RUNNER_LOG="$log"
	return 1
}

# --- 6. 主流程 ---------------------------------------------------------------
echo "sekai verify ｜ Godot: $GODOT"
echo "-----------------------------------------------------"

FAILED=0

if ! run_import; then FAILED=1; fi

# import 失败时仍尝试跑 runner（可能给更多线索），但整体已判失败
if ! run_runner; then FAILED=1; fi

echo "-----------------------------------------------------"

# 失败时**不删**日志，否则用户看到"详见 xxx"却找不到文件。
if [ "$FAILED" -eq 0 ]; then
	rmdir "$LOG_DIR" 2>/dev/null || true
	echo "VERIFY PASS（退出码 0）"
	exit 0
else
	echo "VERIFY FAIL（退出码 1）｜ 排查日志：$LOG_DIR"
	exit 1
fi
