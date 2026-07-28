#!/bin/zsh
# 一個備稿時段要做的事：依序把三種週期都問一遍。由 launchd 在 12:00 / 13:00 觸發。
#
# 為什麼合成一個 job 而不是三個 plist 各排 12:00：
#   三個 job 同時觸發會同時對 ../ai-news-state 這個 worktree 做 git pull，
#   互搶 index.lock，先到的成功、後到的莫名其妙失敗。依序跑就沒有這個問題，
#   也把三次 git pull 省成實際需要的次數。
#
# 非備稿日的週期（平日的週報、月中的月報）會在 run_ai_news.sh 最前面秒退，
# 純日期判斷、不碰網路，所以每天多問兩次幾乎沒有成本。
#
# 觸發來源有兩種：
#   1. launchd StartCalendarInterval — 12:00 / 13:00 兩個固定班
#   2. launchd WatchPaths — 網路設定一變（例如熱點接上）就觸發
#
# 有 (2) 是因為固定班會漏。7/27 那天機器「醒著且有網路」的時間是 12:04–12:29，
# 12:00 那班早了 4 分鐘、13:00 那班晚了 31 分鐘，兩班都沒踩進那個窗口。
# 多排幾班只是多買彩券；真正的解是不要賭時刻，網路一通就動手。
#
# (2) 會在一天中任何時刻觸發，所以要有時間窗擋住：
#   太早 → 新聞主力（iThome 等）約中午才上架，湊不足 10 則
#   太晚 → 雲端 14:00 已經寄過或警示過，這時備稿也用不到（稿綁當天週期，隔天作廢）
# 窗內重複觸發無害：已備妥 / 已寄過都會在 run_ai_news.sh 前段秒退。
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

WINDOW_START=1200
WINDOW_END=1345
NOW="$((10#$(date +%H%M)))"   # 10# 強制十進位，免得 0900 這種前導零被當八進位
if [ "$NOW" -lt "$WINDOW_START" ] || [ "$NOW" -gt "$WINDOW_END" ]; then
  # 刻意不寫進 run.log：網路設定一天會變很多次，窗外觸發若每次記一行，
  # 幾百行雜訊會把真正要看的 RESULT 淹掉。改成覆寫一個時間戳檔，
  # 想確認「WatchPaths 到底有沒有在動」時看它就好，檔案不會長大。
  date '+%Y-%m-%d %H:%M:%S 窗外觸發，未動作' > "$DIR/.last-trigger.log"
  exit 0
fi

"$DIR/run_ai_news.sh" prompt.txt         "每日 AI 新聞 Top 10" daily
"$DIR/run_ai_news.sh" prompt_weekly.txt  "每週 AI 新聞回顧"    weekly
"$DIR/run_ai_news.sh" prompt_monthly.txt "每月 AI 新聞回顧"    monthly

exit 0
