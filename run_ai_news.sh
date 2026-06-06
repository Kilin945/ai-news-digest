#!/bin/zsh
# AI 新聞寄信：由 launchd 觸發。可共用於每日/每週/每月。
# 用法：run_ai_news.sh [prompt檔名] [主旨前綴] [kind]
#   kind = daily(預設) | weekly | monthly  —— 決定「已寄記號」的週期
#   不帶參數 = 每日版
#   例：run_ai_news.sh prompt_weekly.txt "每週 AI 新聞回顧" weekly
#
# 可靠性設計：每個週期只成功寄出「一次」（用 state/ 下的 marker 去重）。
# launchd 會排多個時段；第一個在 FullWake+有網路 時跑成功的就寄出並打勾，
# 其餘時段一律秒跳過。失敗只記 log、不寄垃圾信，留待後續時段補跑。

set -u
DIR="$(cd "$(dirname "$0")" && pwd)"   # 自動偵測腳本所在目錄
LOG="$DIR/run.log"
STATE_DIR="$DIR/state"
mkdir -p "$STATE_DIR"

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
KIND="${3:-daily}"

# ── RSS 來源與已寄狀態 ──
FEEDS_FILE="$DIR/feeds.txt"
SEEN_FILE="$STATE_DIR/seen_urls.json"
case "$KIND" in
  weekly)  FEED_HOURS=168;  FEED_WIDEN=240 ;;   # 7 天 → 放寬 10 天
  monthly) FEED_HOURS=720;  FEED_WIDEN=1080 ;;  # 30 天 → 放寬 45 天
  *)       FEED_HOURS=48;   FEED_WIDEN=72 ;;     # 每日 48h → 放寬 72h
esac

# ── 可調參數 ──
MAX_TRIES=3            # claude 失敗最多重試次數
CLAUDE_TIMEOUT=600     # 單次 claude 最長秒數
NET_WAIT_MAX=24        # 網路就緒最多等 24×5=120 秒

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# 桌面通知（僅用於「不會自己好」的錯誤，例如寄信憑證失效）
notify() {  # $1=標題 $2=內文
  /usr/bin/osascript -e "display notification \"$2\" with title \"$1\" sound name \"Basso\"" >/dev/null 2>&1
}

# 依 kind 算出本週期的識別字串
period_key() {
  case "$KIND" in
    weekly)  date +%G-W%V ;;   # ISO 年-週
    monthly) date +%Y-%m ;;
    *)       date +%F ;;       # 每日 YYYY-MM-DD
  esac
}
MARKER="$STATE_DIR/${KIND}-$(period_key)"

# ── 去重：本週期已成功寄過就跳過（補跑時段會大量命中這裡）──
if [ -f "$MARKER" ]; then
  log "SKIP: [$SUBJECT_PREFIX] 本週期已寄過（$(basename "$MARKER")），跳過。"
  exit 0
fi

# 等待網路就緒（喚醒後 WiFi 常需數秒～數十秒才連上）
wait_for_network() {
  local i=0
  until curl -sf --max-time 5 https://www.google.com/generate_204 >/dev/null 2>&1; do
    i=$((i+1))
    if [ $i -ge $NET_WAIT_MAX ]; then
      log "WARN: 網路在 $((NET_WAIT_MAX*5))s 內未就緒，本時段放棄（留待下個補跑時段）。"
      return 1
    fi
    sleep 5
  done
  return 0
}

# 帶逾時執行 claude，輸出寫入 $1
run_claude() {
  local outfile="$1"
  : > "$outfile"
  "$CLAUDE" -p "$PROMPT" \
    --model "$MODEL" \
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
  print -r -- "$out" | grep -q '<' || return 1
  print -r -- "$out" | grep -qiE 'API Error|socket connection|^Error:|Error:' && return 1
  return 0
}

echo "===== $(date '+%Y-%m-%d %H:%M:%S') 開始 [$SUBJECT_PREFIX] (kind=$KIND) =====" >> "$LOG"

BASE_PROMPT="$(cat "$DIR/$PROMPT_FILE")"
TMP_OUT="$(mktemp -t ai-news)"

HTML=""
attempt=1
while [ $attempt -le $MAX_TRIES ]; do
  if ! wait_for_network; then break; fi    # 網路沒就緒就不浪費 claude 額度，留待補跑

  if ! CANDIDATES="$("$PYTHON" "$DIR/fetch_feeds.py" collect \
      --feeds "$FEEDS_FILE" --seen "$SEEN_FILE" \
      --hours "$FEED_HOURS" --widen "$FEED_WIDEN" --min 10 2>>"$LOG")" \
     || [ -z "$CANDIDATES" ]; then
    log "WARN: 第 $attempt/$MAX_TRIES 次抓 RSS 候選失敗或為空，30s 後重試。"
    attempt=$((attempt+1)); [ $attempt -le $MAX_TRIES ] && sleep 30
    continue
  fi
  PROMPT="$BASE_PROMPT"$'\n\n=== 候選新聞清單（只能從這裡面挑）===\n'"$CANDIDATES"

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
  # 失敗：不寄垃圾、不寄重複通知，只記 log，留待後續補跑時段
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=1, 失敗待補跑) [$SUBJECT_PREFIX] =====" >> "$LOG"
  exit 1
fi

# 成功：寄出新聞並打上「本週期已寄」記號
SEND_OUT="$(echo "$HTML" | "$PYTHON" "$DIR/send_ai_news.py" "$SUBJECT_PREFIX" 2>&1)"
RC=$?
echo "$SEND_OUT" >> "$LOG"
if [ $RC -eq 0 ]; then
  date '+%Y-%m-%d %H:%M:%S' > "$MARKER"
  # 把這次信中實際出現的文章連結記入已寄清單，供跨日去重
  if ! print -r -- "$HTML" \
    | grep -oE "href=['\"]https?://[^'\"]+['\"]" \
    | sed -E "s/^href=['\"]//; s/['\"]$//" \
    | "$PYTHON" "$DIR/fetch_feeds.py" record --seen "$SEEN_FILE" 2>>"$LOG"; then
    log "WARN: 已寄 URL 記錄失敗（不影響本次寄送，下次可能出現重複新聞）。"
  fi
  log "INFO: 已寄出並標記 $(basename "$MARKER")。"
else
  # 寄信失敗（多半是 Gmail App Password 失效，重試也不會好）→ 主動通知
  REASON="$(echo "$SEND_OUT" | grep -iE 'error' | tail -1 | tr -d '"\\' | cut -c1-180)"
  [ -z "$REASON" ] && REASON="請查看 run.log"
  notify "⚠️ AI 新聞寄送失敗" "$SUBJECT_PREFIX：$REASON"
  log "NOTIFY: 寄送失敗，已發桌面通知。原因：$REASON"
fi

echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=$RC) [$SUBJECT_PREFIX] =====" >> "$LOG"
exit $RC
