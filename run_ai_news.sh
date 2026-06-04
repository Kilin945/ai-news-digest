#!/bin/zsh
# AI 新聞寄信：由 launchd 觸發。可共用於每日/每週/每月。
# 用法：run_ai_news.sh [prompt檔名] [主旨前綴]
#   不帶參數 = 每日版（預設）
#   例：run_ai_news.sh prompt_weekly.txt "每週 AI 新聞回顧"

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"   # 自動偵測腳本所在目錄
LOG="$DIR/run.log"

# ── 讀取個人設定 ──
if [ ! -f "$DIR/config.env" ]; then
  echo "ERROR: 找不到 $DIR/config.env，請先 cp config.env.example config.env 並填入設定。" >> "$LOG"
  exit 5
fi
source "$DIR/config.env"
export GMAIL_USER MAIL_TO KEYCHAIN_SERVICE

CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
PYTHON="${PYTHON_BIN:-/opt/homebrew/bin/python3}"
MODEL="${CLAUDE_MODEL:-sonnet}"

PROMPT_FILE="${1:-prompt.txt}"
SUBJECT_PREFIX="${2:-每日 AI 新聞 Top 10}"

# ── 可調參數 ──
MAX_TRIES=3            # claude 失敗最多重試次數
CLAUDE_TIMEOUT=600     # 單次 claude 最長秒數（避免無限卡住）
NET_WAIT_MAX=24        # 網路就緒最多等 24×5=120 秒

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# 等待網路就緒（喚醒後 WiFi 常需數秒～數十秒才連上）
wait_for_network() {
  local i=0
  until curl -sf --max-time 5 https://www.google.com/generate_204 >/dev/null 2>&1; do
    i=$((i+1))
    if [ $i -ge $NET_WAIT_MAX ]; then
      log "WARN: 網路在 $((NET_WAIT_MAX*5))s 內未就緒，仍繼續嘗試。"
      return
    fi
    sleep 5
  done
}

# 帶逾時執行 claude，輸出寫入 $1
run_claude() {
  local outfile="$1"
  : > "$outfile"
  "$CLAUDE" -p "$PROMPT" \
    --model "$MODEL" \
    --allowedTools WebSearch WebFetch \
    --permission-mode default \
    --output-format text > "$outfile" 2>>"$LOG" &
  local cpid=$!
  ( sleep "$CLAUDE_TIMEOUT"; kill -TERM "$cpid" 2>/dev/null ) &
  local wpid=$!
  wait "$cpid" 2>/dev/null
  local rc=$?
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  return $rc
}

# 驗證輸出像不像有效的新聞 HTML（而非錯誤訊息）
looks_valid() {
  local out="$1"
  [ -n "$out" ] || return 1
  print -r -- "$out" | grep -q '<' || return 1                       # 要有 HTML 標籤
  print -r -- "$out" | grep -qiE 'API Error|socket connection|^Error:|Error:' && return 1  # 不可含錯誤字樣
  return 0
}

echo "===== $(date '+%Y-%m-%d %H:%M:%S') 開始 [$SUBJECT_PREFIX] =====" >> "$LOG"

PROMPT="$(cat "$DIR/$PROMPT_FILE")"
TMP_OUT="$(mktemp -t ai-news)"

HTML=""
attempt=1
while [ $attempt -le $MAX_TRIES ]; do
  wait_for_network
  run_claude "$TMP_OUT"; crc=$?
  OUT="$(cat "$TMP_OUT")"
  if [ $crc -eq 0 ] && looks_valid "$OUT"; then
    HTML="$OUT"
    log "INFO: 第 $attempt 次嘗試成功。"
    break
  fi
  log "WARN: 第 $attempt/$MAX_TRIES 次嘗試失敗 (rc=$crc, 長度=${#OUT})，30s 後重試。"
  attempt=$((attempt+1))
  [ $attempt -le $MAX_TRIES ] && sleep 30
done
rm -f "$TMP_OUT"

if [ -z "$HTML" ]; then
  # 全部失敗：寄「明確的失敗通知」而非垃圾內容
  FAIL_HTML="<div style='font-family:sans-serif'><h3>⚠️ 今日「$SUBJECT_PREFIX」產生失敗</h3><p>Claude 連線或逾時，已重試 $MAX_TRIES 次仍失敗。請查看 <code>run.log</code>。</p></div>"
  echo "$FAIL_HTML" | "$PYTHON" "$DIR/send_ai_news.py" "⚠️ $SUBJECT_PREFIX 產生失敗" >> "$LOG" 2>&1
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=1, 已寄失敗通知) [$SUBJECT_PREFIX] =====" >> "$LOG"
  exit 1
fi

# 成功：寄出新聞
echo "$HTML" | "$PYTHON" "$DIR/send_ai_news.py" "$SUBJECT_PREFIX" >> "$LOG" 2>&1
RC=$?

echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=$RC) [$SUBJECT_PREFIX] =====" >> "$LOG"
exit $RC
