#!/usr/bin/env bash
# 生成可公开的发布分支：从 git 索引导出被跟踪文件（git archive，天然不含
# 构建产物），剔除开发文档后压缩为单一初始 commit——历史中的内网 IP /
# 用户路径等隐私不随发布外泄。本地 main 分支与完整历史不受影响。
#
# 注意：导出的是已提交内容，先在 main 提交最新改动再跑本脚本。
#
# 用法: bash scripts/prepare-public.sh [分支名，默认 public]
# 之后: git push <remote> public:main   # 推到 GitHub 的 main
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BRANCH="${1:-public}"

cd "$ROOT"

# 发布树中排除的开发/私有内容（本地保留，仅不进公开分支）
EXCLUDE=(
  AGENTS.md          # 开发决策记录：含内网 IP、用户路径等私有信息
)

if git show-ref --verify --quiet "refs/heads/$BRANCH"; then
  echo "分支 ${BRANCH} 已存在（可 git branch -D 删除后重建）" >&2
  exit 1
fi
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
  echo "工作树有未提交改动——先提交到 main 再生成发布分支" >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# git archive 只导出被跟踪文件（遵守 gitignore，无构建产物/模型缓存）
mkdir -p "$WORK/tree"
git archive HEAD | tar -x -C "$WORK/tree"
for f in "${EXCLUDE[@]}"; do
  rm -f "$WORK/tree/$f"
done

echo "发布树内容："
(cd "$WORK/tree" && ls)

git -C "$WORK/tree" init -q -b "$BRANCH"
git -C "$WORK/tree" add -A
git -C "$WORK/tree" -c user.name="$(git config user.name)" \
                    -c user.email="$(git config user.email)" \
  commit -q -m "simple-asr: 跨平台 Qwen3-ASR 语音转文字（Rust + Flutter）"

# 把孤儿分支接回本仓库
git fetch "$WORK/tree" "$BRANCH:$BRANCH"

echo
echo "完成：分支 ${BRANCH}（单一初始 commit，已排除 ${EXCLUDE[*]}）"
echo "发布：git push <remote> ${BRANCH}:main"
git log --oneline "$BRANCH" | head -3
