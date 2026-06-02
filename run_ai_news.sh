#!/bin/zsh
# AI 新聞寄信：由 launchd 觸發。可共用於每日/每週/每月。
# 用法：run_ai_news.sh [prompt檔名] [主旨前綴]
#   不帶參數 = 每日版（預設）
#   例：run_ai_news.sh prompt_weekly.txt "每週 AI 新聞回顧"

set -u
# 自動偵測腳本所在目錄（搬家也不用改路徑）
DIR="$(cd "$(dirname "$0")" && pwd)"
LOG="$DIR/run.log"

# 讀取個人設定
if [ ! -f "$DIR/config.env" ]; then
  echo "ERROR: 找不到 $DIR/config.env，請先 cp config.env.example config.env 並填入設定。" >> "$LOG"
  exit 5
fi
source "$DIR/config.env"
# 給 send_ai_news.py 用
export GMAIL_USER MAIL_TO KEYCHAIN_SERVICE

CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
PYTHON="${PYTHON_BIN:-/opt/homebrew/bin/python3}"
MODEL="${CLAUDE_MODEL:-sonnet}"

PROMPT_FILE="${1:-prompt.txt}"
SUBJECT_PREFIX="${2:-每日 AI 新聞 Top 10}"

# launchd 的 PATH 很精簡，補上常用路徑
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

echo "===== $(date '+%Y-%m-%d %H:%M:%S') 開始 [$SUBJECT_PREFIX] =====" >> "$LOG"

PROMPT="$(cat "$DIR/$PROMPT_FILE")"

# 無頭執行 Claude：只允許唯讀的網路工具，輸出純文字(HTML)
HTML="$("$CLAUDE" -p "$PROMPT" \
  --model "$MODEL" \
  --allowedTools WebSearch WebFetch \
  --permission-mode default \
  --output-format text 2>>"$LOG")"

if [ -z "$HTML" ]; then
  echo "ERROR: Claude 未產出內容，中止。[$SUBJECT_PREFIX]" >> "$LOG"
  exit 1
fi

# 交給寄信腳本（帶主旨前綴），密碼由 send_ai_news.py 從 Keychain 取得
echo "$HTML" | "$PYTHON" "$DIR/send_ai_news.py" "$SUBJECT_PREFIX" >> "$LOG" 2>&1
RC=$?

echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=$RC) [$SUBJECT_PREFIX] =====" >> "$LOG"
exit $RC
