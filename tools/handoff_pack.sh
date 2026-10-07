#!/usr/bin/env bash
#
# tools/handoff_pack.sh —— 生成「换电脑接手」用的离线交接包
#
# 用途：把【代码全部提交历史】+【WorkBuddy 个人资产】打成一个文件，
#       拷到新机器解开即可继续干活（无需联网、无需 push）。
#
# ⚠️ 本脚本只【读】仓库，只写一个 .bundle 和一个 .tar.gz，不改任何项目文件。
#
# 用法：
#   bash tools/handoff_pack.sh [输出目录]
#   默认输出到 ~/sekai-handoff/
#
# 新机器解包：
#   tar xzf sekai-handoff.tar.gz -C <仓库根>      # 取回 sekai.bundle
#   git clone sekai.bundle sekai && cd sekai && git checkout workbuddy/master-230e4f32
#   # 再把 personal/ 里的内容合并进 ~/.workbuddy/ 对应位置（见 HANDOFF.md §3.3）

set -euo pipefail

OUT_DIR="${1:-$HOME/sekai-handoff}"
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
GIT_COMMON="$(cd "$(git rev-parse --git-common-dir)" && pwd)"
STAMP="$(date +%Y%m%d-%H%M%S)"

echo "=== sekai 交接包 ==="
echo "  分支      : $BRANCH"
echo "  真实仓库  : $GIT_COMMON"
echo "  输出目录  : $OUT_DIR"
echo ""

mkdir -p "$OUT_DIR/personal"

# ── 1. 代码：全部提交历史打成单个 bundle ────────────────────────────
# 用 --all 而不是「A..B」：保证新机器连 master 基线都有，历史不断裂。
echo "[1/3] 打包 git 历史（--all，含所有分支）..."
git bundle create "$OUT_DIR/sekai.bundle" --all
echo "      ✔ $(du -h "$OUT_DIR/sekai.bundle" | cut -f1)"

# ── 2. WorkBuddy 个人资产（不在 git 里，必须手动带走）──────────────
echo "[2/3] 打包 WorkBuddy 个人资产..."
WB_HOME="${WORKBUDDY_HOME:-$HOME/.workbuddy}"
if [ -d "$WB_HOME" ]; then
  # 用户级记忆：目录名含机器 uuid，单独收拢到 personal/user_memory.md
  if compgen -G "$WB_HOME/user-*/MEMORY.md" > /dev/null; then
    cat "$WB_HOME"/user-*/MEMORY.md > "$OUT_DIR/personal/user_memory.md"
    echo "      ✔ user_memory.md（$(wc -l < "$OUT_DIR/personal/user_memory.md") 行）"
  else
    echo "      ⚠ 未找到 $WB_HOME/user-*/MEMORY.md（跳过）"
  fi

  # skill 目录（整个 skills/ 一起带走，不只一个）
  if [ -d "$WB_HOME/skills" ]; then
    cp -r "$WB_HOME/skills" "$OUT_DIR/personal/skills"
    echo "      ✔ skills/（$(ls "$WB_HOME/skills" | wc -l) 个）"
  else
    echo "      ⚠ 未找到 $WB_HOME/skills（跳过）"
  fi
else
  echo "      ⚠ 未找到 $WB_HOME（跳过；可用 WORKBUDDY_HOME 环境变量指定）"
fi

# ── 3. 交接说明与自检信息 ─────────────────────────────────────────
echo "[3/3] 复制交接文档..."
cp -f HANDOFF.md "$OUT_DIR/HANDOFF.md" 2>/dev/null || echo "      ⚠ 未找到 HANDOFF.md"
cp -f docs/architecture/control_checklist.md "$OUT_DIR/control_checklist.md" 2>/dev/null || true
cp -f -r .workbuddy/memory "$OUT_DIR/personal/project_memory" 2>/dev/null || true

# 记录关键环境信息，方便新机器对照
GODOT_VER="$("$GODOT" --headless --version 2>/dev/null | head -1 || echo '未设置 $GODOT')" || GODOT_VER="未设置 \$GODOT"
{
  echo "# 交接包信息（生成于 $STAMP）"
  echo
  echo "- 分支：$BRANCH"
  echo "- 提交：$(git rev-parse HEAD)"
  echo "- 领先 master：$(git rev-list --count master..HEAD 2>/dev/null || echo '?') 个提交"
  echo "- 生成时 Godot 版本：$GODOT_VER"
  echo "- 渲染驱动锁：$(grep -c 'rendering_device/driver.windows="vulkan"' project.godot 2>/dev/null || echo '?') （1 = 锁在位）"
  echo "- 测试基线：416 用例 / 6158 断言 / 0 失败"
} > "$OUT_DIR/INFO.md"

# 打成一个 tar.gz（bundle 已在里面，避免二次压缩 275MB 的 git 对象）
cd "$(dirname "$OUT_DIR")"
tar czf "$(basename "$OUT_DIR").tar.gz" "$(basename "$OUT_DIR")"
cd - > /dev/null

echo ""
echo "=== 完成 ==="
echo "  交接包：$(dirname "$OUT_DIR")/$(basename "$OUT_DIR").tar.gz  ($(du -h "$(dirname "$OUT_DIR")/$(basename "$OUT_DIR").tar.gz" | cut -f1))"
echo ""
echo "下一步："
echo "  1. 把这个 tar.gz 拷到新机器"
echo "  2. 新机器按 HANDOFF.md §3.2 / §3.3 / §3.4 操作"
echo ""
echo "⚠️ 提醒：git push 请你自己执行（AI 不代劳）。"
echo "   需要推到 GitHub 的话：git push -u origin $BRANCH"
