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
# 網路就緒最多等 90×5=450 秒（7.5 分鐘）。
# 120 秒是照「WiFi 喚醒後慢個幾十秒」設的，對固定 WiFi 夠，對手機熱點遠遠不夠：
# Mac 要先用藍牙把 iPhone 叫醒、iPhone 才開始廣播、再關聯、再 DHCP，整串常要好幾分鐘。
# 7/27 實測：12:00:04 開跑、12:02:02 等滿 120 秒放棄，網路 12:04:09 才通，差 2 分 7 秒。
# 放寬的代價趨近於零——真的沒網路時只是多空轉，那時機器本來就在睡。
NET_WAIT_MAX=90

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

# 桌面通知（僅用於「不會自己好」的錯誤，例如寄信憑證失效、連續備稿失敗）
notify() {  # $1=標題 $2=內文
  /usr/bin/osascript -e "display notification \"$2\" with title \"$1\" sound name \"Basso\"" >/dev/null 2>&1
}

# ── git 同步（state 分支）──
# pull 失敗即放棄本時段：拿過期狀態會誤判「已寄過/已備妥」而漏寄（java-learn 6/27 教訓）。
# git 網路操作一律包這個，理由是 2026-08-02/03 連兩天的教訓：
# 憑證助手拿不到 Keychain（errSecInteractionNotAllowed）時不會失敗，而是無限等下去。
# git push 因此永不返回，launchd 同一個 label 前一次還在跑就不會再啟動，
# 一卡就吃掉當天剩下所有班次——08-03 那次從 12:02 卡到 18:00，13:00 那班完全沒跑，
# 稿明明產好了卻留在本機，雲端 14:00 只能寄缺稿警示。
# BatchMode / TERMINAL_PROMPT 讓 git 不要問（要問就直接失敗，交給重試邏輯）；
# watchdog 是保險：就算還是卡住，時限一到強制收掉，至少 log 留下痕跡、班次能往下走。
GIT_NET_TIMEOUT="${GIT_NET_TIMEOUT:-60}"
git_timeout() {
  local pid wd rc
  GIT_TERMINAL_PROMPT=0 \
  GIT_SSH_COMMAND='ssh -o ConnectTimeout=10 -o BatchMode=yes' \
    "$@" >>"$LOG" 2>&1 &
  pid=$!
  # 先收子進程再收自己：git 會生 remote-https / credential 這些孫子，只殺父的話它們會留著。
  ( sleep "$GIT_NET_TIMEOUT"; pkill -9 -P "$pid" 2>/dev/null; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  wd=$!
  wait "$pid"; rc=$?
  kill "$wd" 2>/dev/null
  [ "$rc" -ge 128 ] && log "WARN: git 操作超過 ${GIT_NET_TIMEOUT}s 被強制中止（若不中止會無限等待）。"
  return "$rc"
}

git_pull() {
  [ "$REPO_SYNC" = 1 ] || return 0
  local i=1 out reason
  while [ $i -le 3 ]; do
    # BatchMode/TERMINAL_PROMPT：不准問憑證或 host key，要問就失敗——問了就是卡死。
    if out="$(GIT_TERMINAL_PROMPT=0 GIT_SSH_COMMAND='ssh -o ConnectTimeout=10 -o BatchMode=yes' git -C "$STATE_WT" pull --rebase --autostash 2>&1)"; then
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
  git_timeout git -C "$STATE_WT" pull --rebase --autostash || true
  local i=1
  while [ $i -le 3 ]; do
    if git_timeout git -C "$STATE_WT" push; then
      log "INFO: state 已推上 origin（第 $i 次嘗試，共 $ahead 個 commit）。"
      return 0
    fi
    log "WARN: git push 第 $i/3 次失敗。"
    i=$((i+1)); [ $i -le 3 ] && sleep 5
  done
  log "WARN: git push 連續 3 次失敗（稿在本機 worktree，下個班次會再推）。"
  return 1
}

# 每個時段留一行結果，方便事後一眼看完當天發生什麼事：
#   2026-07-26 13:00:12 RESULT daily FAIL claude 逾時
# 沒有這行就代表「這個時段根本沒被觸發」（機器沒醒），跟「跑了但失敗」是兩回事，
# 混在一起就無從除錯——今天 7/26 就是靠逐行對時間戳才確定機器是醒著的。
result() {  # $1=OK|SKIP|FAIL  $2=說明
  log "RESULT $KIND $1 $2"
}

# 最後一班仍然失敗 → 當下直接寄警示信，不等雲端 14:00 那班。
# 本機寄不出去（多半是沒網路）就不寫 marker，雲端看不到 marker 會補寄，兩層不會重複。
# 順序不可顛倒：一定要「確認寄信成功」才寫 marker，反過來會變成沒信也沒人知道。
send_local_alert() {  # $1=失敗原因
  local why="$1" today attempts body
  today="$(date +%F)"
  attempts="$STATE_DIR/attempts-$today.log"
  # 平常成功的日子不留檔，只有出事這天才把當天各時段的結果送上 state 分支供雲端引用
  grep "^$today .*RESULT " "$LOG" > "$attempts" 2>/dev/null || true
  body="<div style=\"font-family:-apple-system,sans-serif\">
<h3>⚠️ $SUBJECT_PREFIX 今天備稿失敗</h3>
<p>最後一個備稿時段仍然失敗，今天不會自動寄出。</p>
<p><b>原因：</b>${why:-詳見 run.log}</p>
<p><b>今天各時段：</b></p>
<pre style=\"background:#f6f7f9;padding:10px;border-radius:6px;font-size:12px\">$(cat "$attempts" 2>/dev/null)</pre>
</div>"
  if print -r -- "$body" | "$PYTHON" "$DIR/send_ai_news.py" "⚠️ $SUBJECT_PREFIX 備稿失敗" >>"$LOG" 2>&1; then
    date '+%Y-%m-%d %H:%M:%S' > "$STATE_DIR/alert-$KIND-$today"
    log "INFO: 已從本機寄出警示信並標記 alert-$KIND-$today。"
  else
    log "WARN: 本機警示信寄送失敗，改由雲端 14:00 那班補寄。"
  fi
  git_push_state
}

# 等待網路就緒（喚醒後 WiFi 常需數秒～數十秒才連上）
# 主呼叫點在主流程開頭、git 同步之前；產稿迴圈裡再呼叫一次是防中途斷線，網路正常時會立即返回。
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

START_HHMM="$(date +%H%M)"   # 本次啟動時間，用來判斷自己是不是當天最後一個備稿班
echo "===== $(date '+%Y-%m-%d %H:%M:%S') 開始 [$SUBJECT_PREFIX] (kind=$KIND) =====" >> "$LOG"

# ── 今天該備這種稿嗎？──
# 純日期運算，不碰網路也不碰 state，所以放在最前面：非備稿日的週期（平日的週報、
# 月中的月報）在這裡秒退，不會白跑一趟 git pull，也不會跟同時段的其他週期搶 worktree。
# 週報週六備（週日可補備）、月報當月倒數第二天備（最後一天可補備），都比寄出日早一天。
# 判斷寫在腳本裡而不是 launchd，是因為「當月最後一天」沒辦法用固定日期表示
# （31 號在小月不存在、2 月更短）。
if ! "$PYTHON" "$DIR/outbox.py" --prep-due "$KIND" >/dev/null 2>&1; then
  result SKIP "今天不是 $KIND 的備稿日"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=0, 非備稿日) [$SUBJECT_PREFIX] =====" >> "$LOG"
  exit 0
fi

# ── 等網路就緒（必須在任何連外動作之前）──
# 順序很重要，別把這段移到 git 同步後面（見 docs/decisions/2026-07-26-schedule-alignment-and-alerts.md）：
# 闔蓋 + 電池時 launchd 鬧醒機器只會進 DarkWake，CPU 醒著但 WiFi 還沒連上。
# 先 git pull 就會立刻「Could not resolve host」三連敗、放棄整個時段，
# 這段本來就是為 DarkWake 寫的等待邏輯反而永遠跑不到，等於整套多時段補跑機制失效。
if ! wait_for_network; then
  log "WARN: 網路未就緒，放棄本時段（留待下個補跑時段）。"
  result FAIL "網路未就緒"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=1, 網路未就緒) [$SUBJECT_PREFIX] =====" >> "$LOG"
  exit 1
fi

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
  result FAIL "state 分支同步失敗"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=1, 同步失敗) [$SUBJECT_PREFIX] =====" >> "$LOG"
  exit 1
fi
mkdir -p "$STATE_DIR"

PERIOD="$("$PYTHON" "$DIR/outbox.py" --period-key "$KIND")"
MARKER="$STATE_DIR/${KIND}-$PERIOD"

# ── 去重：本週期已成功寄過就跳過（補跑時段會大量命中這裡）──
if [ -f "$MARKER" ]; then
  result SKIP "本週期已寄過（$(basename "$MARKER")）"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=0, 已寄過) [$SUBJECT_PREFIX] =====" >> "$LOG"
  exit 0
fi

# 本週期的稿已備妥就不重產，但要確保有推上 origin（補推之前失敗的 push）
if "$PYTHON" "$DIR/outbox.py" --ready "$KIND" >/dev/null 2>&1; then
  result SKIP "本週期稿已備妥（outbox）"
  git_push_state
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=0, 已備妥) [$SUBJECT_PREFIX] =====" >> "$LOG"
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
  # 失敗：不寄垃圾，留待後續備稿班次補跑。
  result FAIL "${why:-產稿失敗，詳見 run.log}"
  # 只有「最後一個備稿班」失敗才警示——此時今天不會再自動好，通知才代表「該動手了」；
  # 前面班次失敗默默記 log，不製造模稜兩可的提醒。
  # 判斷用「本次啟動時間」而非現在時間：12:00 那班若跑很久拖過 13:00，
  # 它不該搶著發警示，13:00 那班還沒開始跑。
  if [ "$START_HHMM" -ge 1300 ] && [ ! -f "$STATE_DIR/alert-$KIND-$(date +%F)" ]; then
    notify "⚠️ $SUBJECT_PREFIX 備不出來" "原因：${why:-詳見 run.log}。已寄警示信。"
    send_local_alert "$why"
  fi
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=1, 失敗待補跑) [$SUBJECT_PREFIX] =====" >> "$LOG"
  exit 1
fi

# ── 三種週期一律進 outbox，寄出全部交給雲端 ──
# 本機不再直接寄任何信：寄信要成功得筆電醒著又有網路，那正是最不可靠的環節。
# 本機只做「產稿」（靠已登入的 claude CLI，雲端做不到），寄出交給一定會跑的 GitHub Actions。
if ! print -r -- "$HTML" | "$PYTHON" "$DIR/outbox.py" --to-outbox "$KIND" >>"$LOG" 2>&1; then
  log "ERROR: 寫入 outbox 失敗，本時段放棄（下個班次會重產）。"
  result FAIL "寫入 outbox 失敗"
  echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=1, outbox 失敗) [$SUBJECT_PREFIX] =====" >> "$LOG"
  exit 1
fi
git_push_state
result OK "備稿完成（週期 $PERIOD）"
echo "===== $(date '+%Y-%m-%d %H:%M:%S') 結束 (rc=0, 備稿完成) [$SUBJECT_PREFIX] =====" >> "$LOG"
exit 0
