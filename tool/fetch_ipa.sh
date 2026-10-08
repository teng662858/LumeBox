#!/usr/bin/env bash
# 把最新一次成功的 iOS 构建（未签名 IPA）拉到 ipa/ 目录。
#
# 用法（Git Bash / macOS / Linux 均可）：
#   bash tool/fetch_ipa.sh              # 拉最新一次成功构建
#   bash tool/fetch_ipa.sh <run_id>     # 指定某次 run（gh run list 里的 ID）
#
# 产物落在仓库根的 ipa/ 下，文件名带**构建号**：
#   ipa/LumeBox-unsigned-1.0.<run_number>.ipa
# 装到手机后，「设置 → 关于」显示的就是同一个号（版本 1.0.<run_number>）——
# 两边对上才说明装的是这一版（真机踩过「代码改了界面没变」：旧包与新包同名，
# 看不出来装的是哪一版）。
set -euo pipefail

cd "$(dirname "$0")/.."
OUT_DIR="ipa"
ARTIFACT="LumeBox-unsigned-ipa"

command -v gh >/dev/null || { echo "需要 gh（GitHub CLI）"; exit 1; }
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)

RUN_ID="${1:-}"
if [[ -z "$RUN_ID" ]]; then
  RUN_ID=$(gh run list --limit 20 \
    --json databaseId,conclusion,status,headBranch \
    -q '[.[] | select(.headBranch=="main" and .status=="completed" and .conclusion=="success")][0].databaseId')
  [[ -n "$RUN_ID" && "$RUN_ID" != "null" ]] || { echo "没找到成功的构建"; exit 1; }
fi

RUN_NUMBER=$(gh api "repos/$REPO/actions/runs/$RUN_ID" --jq '.run_number')
TARGET="$OUT_DIR/LumeBox-unsigned-1.0.$RUN_NUMBER.ipa"

if [[ -f "$TARGET" ]]; then
  echo "已存在：$TARGET（跳过下载）"
else
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  echo "下载 run $RUN_ID（构建号 $RUN_NUMBER）…"
  gh run download "$RUN_ID" -n "$ARTIFACT" -D "$TMP"
  mkdir -p "$OUT_DIR"
  mv "$TMP/LumeBox-unsigned.ipa" "$TARGET"
fi

echo "已就位：$TARGET"
echo "装到手机后核对：设置 →「关于」应显示「版本 1.0.$RUN_NUMBER（构建 $RUN_NUMBER）」"
