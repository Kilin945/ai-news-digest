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
set -u
DIR="$(cd "$(dirname "$0")" && pwd)"

"$DIR/run_ai_news.sh" prompt.txt         "每日 AI 新聞 Top 10" daily
"$DIR/run_ai_news.sh" prompt_weekly.txt  "每週 AI 新聞回顧"    weekly
"$DIR/run_ai_news.sh" prompt_monthly.txt "每月 AI 新聞回顧"    monthly

exit 0
