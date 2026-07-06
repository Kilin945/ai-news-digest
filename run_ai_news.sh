#!/bin/zsh
# AI 新聞：由 launchd 觸發。可共用於每日/每週/每月。
# 用法：run_ai_news.sh [prompt檔名] [主旨前綴] [kind]
#   kind = daily(預設) | weekly | monthly
#
# 架構（daily 已雲端化）：
#   daily   → 本機只「產稿」進 state 分支的 outbox，寄出交給雲端 GitHub Actions
#             （Cloudflare Worker 準點觸發 daily-send.yml：台北 08:00/12:00/14:00）
#   weekly / monthly → 仍由本機直接寄出（照舊）
#
# 跨班次狀態放在獨立 state 分支（worktree ../ai-news-state）：
#   state/daily-YYYY-MM-DD  = 今天寄過了（雲端寄完打的 marker）
#   state/outbox.json       = 有稿待寄（含產稿日期，雲端寄前驗證是今天的稿才寄）
#   state/noprep-YYYY-MM-DD = 今天「沒稿」警示信寄過了
#   state/seen_urls.json    = 已寄 URL（跨日去重，雲端寄完更新）

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
# 長效 OAuth token 給 headless 環境用（launchd 讀不到桌面 session 的互動憑證，
# 公司帳號的互動 token 又不給背景程序用，故改用 setup-token 產的長效 token）。
[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && export CLAUDE_CODE_OAUTH_TOKEN

CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
PYTHON="${PYTHON_BIN:-/opt/homebrew/bin/python3}"
MODEL="${CLAUDE_MODEL:-sonnet}"

PROMPT_FILE="${1:-prompt.txt}"
SUBJECT_PREFIX="${2:-每日 AI 新聞 Top 10}"
KIND="${3:-daily}"

# ── state 分支 worktree（跨班次狀態的同步通道）──
REPO_SYNC="${REPO_SYNC:-1}"
STATE_WT="${STATE_WT:-$(dirname "$DIR")/ai-news-state}"
STATE_DIR="$STATE_WT/state"
export AI_NEWS_STATE_DIR="$STATE_DIR"

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

# 桌面通知（僅用於「不會自己好」的錯誤，例如寄信憑證失效、連續備稿失敗）
notify() {  # $1=標題 $2=內文
  /usr/bin/osascript -e "display notification \"$2\" with title \"$1\" sound name \"Basso\"" >/dev/null 2>&1
}

# ── git 同步（state 分支）──
# pull 失敗即放棄本時段：拿過期狀態會誤判「已寄過/已備妥」而漏寄（java-learn 6/27 教訓）。
git_pull() {
  [ "$REPO_SYNC" = 1 ] || return 0
  local i=1 out reason
  while [ $i -le 3 ]; do
    if out="$(GIT_SSH_COMMAND='ssh -o ConnectTimeout=10' git -C "$STATE_WT" pull --rebase --autostash 2>&1)"; then
      [ -n "$out" ] && echo "$out" >> "$LOG"
      return 0
    fi
    echo "$out" >> "$LOG"
    reason="$(print -r -- "$out" | grep -iE 'ssh:|Permission denied|timed out|Connection (refused|reset)|Could not resolve' | head -1 | tr -d '"\\' | cut -c1-180)"
    [ -z "$reason" ] && reason="$(print -r -- "$out" | grep -iE 'fatal|error|致命|無法' | tail -1 | tr -d '"\\' | cut -c1-180)"
    [ -z "$reason" ] && reason="$(print -r -- "$out" | tail -1 | cut -c1-180)"
    log "WARN: git pull 第 $i/3 次失敗：${reason:-原因不明}。5 秒後重試。"
    i=$((i+1)); sleep 5
  done
  log "WARN: git pull 連續 3 次失敗，本機狀態可能過期。"
  return 1
}

# push 失敗最多重試 3 次；仍失敗只記 log，稿留在 worktree，下個班次會再推（java-learn 7/2 教訓）。
git_push_state() {
  [ "$REPO_SYNC" = 1 ] || return 0
  git -C "$STATE_WT" add -A >>"$LOG" 2>&1 || true
  git -C "$STATE_WT" diff --cached --quiet \
    || git -C "$STATE_WT" commit -m "chore: 本機備妥 $(date +%F) 的稿" >>"$LOG" 2>&1 || true
  local ahead
  ahead="$(git -C "$STATE_WT" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 1)"
  [ "$ahead" = 0 ] && return 0
  git -C "$STATE_WT" pull --rebase --autostash >>"$LOG" 2>&1 || true
  local i=1
  while [ $i -le 3 ]; do
    if git -C "$STATE_WT" push >>"$LOG" 2>&1; then
      log "INFO: state 已推上 origin（第 $i 次嘗試，共 $ahead 個 commit）。"
      return 0
    fi
    log "WARN: git push 第 $i/3 次失敗。"
    i=$((i+1)); [ $i -le 3 ] && sleep 5
  done
  log "WARN: git push 連續 3 次失敗（稿在本機 worktree，下個班次會再推）。"
  return 1
}

# 依 kind 算出本週期的識別字串
period_key() {
  case "$KIND" in
    weekly)  date +%G-W%V ;;   # ISO 年-週
    monthly) date +%Y-%m ;;
    *)       date +%F ;;       # 每日 YYYY-MM-DD
  esac
}

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

# 帶逾時執行 claude，stdout 寫入 $1；stderr 另存一份供失敗時擷取原因，並一律附進 run.log
run_claude() {
  local outfile="$1"
  : > "$outfile"
  CLAUDE_LAST_ERR="${TMPDIR:-/tmp}/ai-news-claude-err"
  : > "$CLAUDE_LAST_ERR"
  "$CLAUDE" -p "$PROMPT" \
    --model "$MODEL" \
    --permission-mode default \
    --output-format text > "$outfile" 2>"$CLAUDE_LAST_ERR" &
  local cpid=$!
  ( sleep "$CLAUDE_TIMEOUT"; kill -TERM "$cpid" 2>/dev/null ) &
  local wpid=$!
  wait "$cpid" 2>/dev/null
  local rc=$?
  kill "$wpid" 2>/dev/null; wait "$wpid" 2>/dev/null
  cat "$CLAUDE_LAST_ERR" >> "$LOG"
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

# ── 同步 state 分支（worktree 不在就先建）──
if [ "$REPO_SYNC" = 1 ] && [ ! -d "$STATE_WT" ]; then
  git -C "$DIR" fetch origin state >>"$LOG" 2>&1
  if ! git -C "$DIR" worktree add "$STATE_WT" state >>"$LOG" 2>&1; then
    log "ERROR: 建立 state worktree（$STATE_WT）失敗，放棄本時段。"
    exit 6
  fi
  log "INFO: 已建立 state worktree：$STATE_WT"
fi
if ! git_pull; then
  log "WARN: state 分支同步失敗，放棄本時段（避免用過期狀態誤判）。"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=1, 同步失敗) [$SUBJECT_PREFIX] =====" >> "$LOG"
  exit 1
fi
mkdir -p "$STATE_DIR"

MARKER="$STATE_DIR/${KIND}-$(period_key)"

# ── 去重：本週期已成功寄過就跳過（補跑時段會大量命中這裡）──
if [ -f "$MARKER" ]; then
  log "SKIP: [$SUBJECT_PREFIX] 本週期已寄過（$(basename "$MARKER")），跳過。"
  exit 0
fi

# daily：今天的稿已備妥就不重產，但要確保有推上 origin（補推之前失敗的 push）
if [ "$KIND" = "daily" ] && "$PYTHON" "$DIR/outbox.py" --ready >/dev/null 2>&1; then
  log "SKIP: 今日稿已備妥（outbox），確保已推上 origin 後跳過。"
  git_push_state
  exit 0
fi

BASE_PROMPT="$(cat "$DIR/$PROMPT_FILE")"
TMP_OUT="$(mktemp -t ai-news)"

HTML=""
why=""
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
  PALETTE_TBL="$("$PYTHON" "$DIR/fetch_feeds.py" palette 2>>"$LOG")"   # 每天輪換的卡片配色
  PROMPT="$BASE_PROMPT"$'\n\n=== 候選新聞清單（只能從這裡面挑）===\n'"$CANDIDATES"$'\n\n=== 今日顏色表（第 N 則用第 N 列）===\n'"$PALETTE_TBL"

  run_claude "$TMP_OUT"; crc=$?
  OUT="$(cat "$TMP_OUT")"
  if [ $crc -eq 0 ] && looks_valid "$OUT"; then
    HTML="$OUT"
    log "INFO: 第 $attempt 次嘗試成功。"
    break
  fi
  # 失敗原因優先取 claude 的 stdout（錯誤多半印在這），其次取 stderr 末 3 行，皆空標示無輸出。
  why="$(print -r -- "$OUT" | tr '\n' ' ' | tr -s ' ' | tr -d '"\\' | cut -c1-200)"
  [ -z "$why" ] && why="$(tail -n 3 "$CLAUDE_LAST_ERR" 2>/dev/null | tr '\n' ' ' | tr -s ' ' | tr -d '"\\' | cut -c1-200)"
  [ -z "$why" ] && why="claude 未輸出任何內容。"
  log "WARN: 第 $attempt/$MAX_TRIES 次嘗試失敗 (rc=$crc, 長度=${#OUT})：$why"
  attempt=$((attempt+1))
  [ $attempt -le $MAX_TRIES ] && sleep 30
done
rm -f "$TMP_OUT"

if [ -z "$HTML" ]; then
  # 失敗：不寄垃圾、只記 log，留待後續備稿班次補跑。
  # 桌面通知只在「最後一個備稿班（過 13:00）」仍失敗時才發——此時今天不會再自動好，
  # 通知才代表「該動手了」；前面班次失敗默默記 log，不製造模稜兩可的提醒。
  if [ "$KIND" = "daily" ] && [ "$(date +%H%M)" -ge 1300 ]; then
    notify "⚠️ 今天的 AI 新聞備不出來" "原因：${why:-詳見 run.log}。今天不會自動寄了，請開電腦執行 claude 後跑 /login。"
  fi
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=1, 失敗待補跑) [$SUBJECT_PREFIX] =====" >> "$LOG"
  exit 1
fi

if [ "$KIND" = "daily" ]; then
  # ── daily：產稿進 outbox 並推上 state 分支，寄出交給雲端 ──
  if ! print -r -- "$HTML" | "$PYTHON" "$DIR/outbox.py" --to-outbox >>"$LOG" 2>&1; then
    log "ERROR: 寫入 outbox 失敗，本時段放棄（下個班次會重產）。"
    echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=1, outbox 失敗) [$SUBJECT_PREFIX] =====" >> "$LOG"
    exit 1
  fi
  git_push_state
  log "INFO: 今日稿已備妥並推上 state 分支，等雲端班次（08:00/12:00/14:00）寄出。"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=0, 備稿完成) [$SUBJECT_PREFIX] =====" >> "$LOG"
  exit 0
fi

# ── weekly / monthly：照舊由本機直接寄出 ──
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
  git_push_state
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
