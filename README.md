# AI News Digest 📰

每天、每週、每月自動把最新 AI 新聞（英文原文 + 繁體中文翻譯）寄到你的 Gmail 收件匣。

由 **macOS launchd** 排程 → 從多家可信媒體的 **RSS** 抓最新新聞 → 觸發 **headless Claude Code**（`claude -p`）從候選清單挑重點並翻譯 → 透過 **Gmail SMTP** 寄信。Gmail App Password 存放在 **macOS Keychain**，個人設定放在 gitignore 的 `config.env`，repo 不含任何明文密碼或私人信箱。

> 新聞來源是一份你可自行增減的 RSS 清單（`feeds.txt`），並會記住近 7 天寄過的連結避免重複，而不是讓 Claude 自由上網搜尋。
>
> 信件採柔和卡片版型（英文標題在上、中文在下、每則一個分類徽章），10 則各用一種柔和底色，且**配色每天輪換一格**，天天看起來都有點新鮮。

<p align="center">
  <img src="docs/preview.png" alt="每日 AI 新聞信件示意圖" width="520">
  <br>
  <em>每天早上收到的信件示意（內容為範例）</em>
</p>

---

## 架構

**每日信**：本機只負責「產稿」，寄出交給雲端（跟筆電是否開機、有沒有網路脫鉤）。
**每週 / 每月信**：仍由本機直接寄出。

新聞主力來源（iThome 等）約中午才大批上架，故每日信走「中午版」：等池子長滿再產、午後寄出，較能湊足 10 則。

```
本機（launchd 備稿）                          雲端
─────────────────────────────                ─────────────────────────────
每天 12:15 / 12:50 / 13:30 備稿               Cloudflare Worker digest-cron（準點鬧鐘）
  ├─ 同步 state 分支（pull 失敗即放棄本時段）    台北 13:00 主班 / 14:00 最後一班(slot=last)
  ├─ 已寄過/已備妥？→ 秒跳過                       │ GitHub API workflow_dispatch（立即執行，不排隊）
  ├─ 抓 RSS → claude 產稿 → HTML                 ▼
  └─ 寫 outbox → push 上 state 分支 ────────→   daily-send.yml（GitHub Actions）
                                               ├─ 已寄過？→ 秒跳過（marker 去重）
                                               ├─ outbox 是今天的稿？→ 寄出（標題日期蓋成寄出當天）
每週日 08:10 / 10:30 / 13:00   ┐               ├─ 沒稿且是最後一班 → 寄「沒稿」警示信（一天一封）
每月1日 08:20 / 11:00 / 15:00  ┴ 本機直寄       └─ 打 marker、記已寄連結 → 推回 state 分支
```

跨班次狀態放在獨立 **state 分支**（本機用旁邊的 worktree `../ai-news-state` 操作），
main 分支永遠不被每日紀錄洗版：

- `state/daily-YYYY-MM-DD` — 今天寄過了（所有班次先查它去重）
- `state/outbox.json` — 有稿待寄（含產稿日期，只有「今天的稿」才會被寄出，過期稿不寄）
- `state/noprep-YYYY-MM-DD` — 今天「沒稿」警示過了（警示信一天最多一封）
- `state/seen_urls.json` — 已寄連結（跨日去重）

### 可靠性設計

筆電在「電池 + 闔蓋」時，macOS 只做 **DarkWake**（螢幕不亮、電池模式下網路受限），排程任務可能在沒有網路時被觸發而失敗。與其用 `disablesleep` 強迫機器整天清醒（耗電發熱、與系統省電機制對著幹），本專案選擇**順著系統設計**：

- **多時段觸發**：每天排多個時段，總有一個會落在「你已開電腦、FullWake + 網路正常」的時候。
- **marker 去重**：每個週期（日/週/月）成功寄出後寫一個 `state/` 記號，後續時段命中就**秒跳過**，確保每週期只寄一次（exactly-once）。
- **等網路 + 逾時 + 重試**：喚醒後先探測網路就緒才呼叫 claude；單次有逾時上限；失敗自動重試。
- **失敗不寄垃圾**：驗證輸出為有效 HTML 才寄；失敗只記 `run.log`，留待後續時段補跑，不會把錯誤訊息當成新聞寄出。

> 結果：只要中午任一備稿時段筆電是醒的，13:00（或 14:00 補寄）就收到信；整天都沒開機則 14:00 收到警示信。你只要記兩個時間：**13:00 收信、14:00 沒信看警示**。

> 💡 為什麼觸發用 Cloudflare 而非 GitHub schedule？實測 GitHub schedule 延遲 1~4 小時、台北 08:00 前後的班次會整班靜默消失。Cloudflare Workers Cron 準點開槍、數十秒內 GitHub run 就建立。
> 💡 為什麼產稿仍在本機？產稿靠 claude CLI（本機已登入、不另花 API 費用）；寄信才是怕筆電沒開的環節，所以只把「寄出」搬上雲端。

## 檔案

| 檔案 | 作用 |
|------|------|
| `install.sh` | 安裝器：偵測路徑、產生並安裝 launchd 排程、設定喚醒 |
| `run_ai_news.sh` | 主腳本，串接 抓 RSS → Claude → 寄信；自動偵測所在目錄、讀 config.env |
| `fetch_feeds.py` | 抓各家 RSS、濾時間窗、排除近 7 天寄過的連結，輸出候選清單；另有記錄已寄連結的模式 |
| `feeds.txt` | 新聞來源清單（一行一個 RSS），自行增減即可，不用改程式 |
| `requirements.txt` | Python 依賴（`feedparser`）|
| `send_ai_news.py` | SMTP 寄信，設定讀 config.env、密碼讀環境變數（雲端）或 Keychain（本機）|
| `outbox.py` | state 分支上 outbox 的存取（存稿 / 驗稿 / 取稿蓋日期 / 清除）|
| `.github/workflows/daily-send.yml` | 雲端寄信（由 Cloudflare Worker digest-cron 準點觸發）|
| `config.env.example` | 個人設定範本（**進版控**）|
| `config.env` | 你的實際設定（**被 .gitignore**）|
| `prompt.txt` / `prompt_weekly.txt` / `prompt_monthly.txt` | 三種版本的指令 |
| `launchd/*.plist.template` | launchd 排程範本（含 `__PROJECT_DIR__` 佔位）|

## 快速安裝

```bash
# 1. 把 Gmail App Password 存進 Keychain（先開兩步驟驗證並建立 App Password）
#    https://myaccount.google.com/apppasswords
security add-generic-password -U \
  -a "你的@gmail.com" -s "ai-news-gmail" \
  -w "你的16碼AppPassword" -T /usr/bin/security

# 2. 跑安裝器（第一次會生成 config.env，請編輯填入你的信箱後再跑一次）
./install.sh
```

`install.sh` 會自動：偵測 `claude` / `python3` 路徑寫進 `config.env` → 由範本產生 plist（填入本專案絕對路徑）→ 安裝並載入三個排程 → 詢問是否設定每天 07:05 定時喚醒。

雲端寄信另需一次性設定（已完成則免）：GitHub repo secrets `GMAIL_USER` / `MAIL_TO` / `GMAIL_APP_PASSWORD`，以及 `~/Workspace/digest-cron` Worker 的 TARGETS 時刻表（見該專案 README）。

## 手動測試

```bash
./run_ai_news.sh                                      # 每日版
./run_ai_news.sh prompt_weekly.txt  "每週 AI 新聞回顧"   # 每週版
./run_ai_news.sh prompt_monthly.txt "每月 AI 新聞回顧"   # 每月版
tail -30 run.log                                       # 看執行紀錄
```

## 自訂

- **加 / 減新聞來源** → 編輯 `feeds.txt`（一行一個 `RSS網址 <tab或|> 顯示名稱`，`#` 為註解）
- **改挑選規則 / 則數 / 排版** → 編輯對應的 `prompt*.txt`
- **改寄送時間** → 編輯 `launchd/*.plist.template` 的 `Hour`/`Minute`，重跑 `./install.sh`；並同步調整 `pmset` 喚醒時間
- **改寄件信箱 / 路徑 / 模型** → 編輯 `config.env`
- **換密碼** → 用 `security add-generic-password -U ...` 更新 Keychain 項目

## 設定項（config.env）

| 變數 | 說明 |
|------|------|
| `GMAIL_USER` | 登入 / 寄件信箱 |
| `MAIL_TO` | 收件信箱（通常同上）|
| `KEYCHAIN_SERVICE` | Keychain 內 App Password 的 service 名稱 |
| `CLAUDE_BIN` / `PYTHON_BIN` | 執行檔路徑（install.sh 自動偵測）|
| `CLAUDE_MODEL` | 使用的模型（預設 `sonnet`）|

> 🔒 **安全**：`config.env` 與 `*.log` 已被 `.gitignore`；密碼只在 macOS Keychain，不在任何檔案。

## 移除

```bash
for n in ai-news ai-news-weekly ai-news-monthly; do
  launchctl unload ~/Library/LaunchAgents/com.kilin.$n.plist
  rm ~/Library/LaunchAgents/com.kilin.$n.plist
done
sudo pmset repeat cancel
security delete-generic-password -s "ai-news-gmail"
```

## 需求

- macOS（launchd / pmset / Keychain）
- [Claude Code](https://claude.com/claude-code) CLI（已登入）
- Python 3 + `feedparser`（`install.sh` 會自動安裝；或手動 `pip install -r requirements.txt`）
- 一個啟用兩步驟驗證、可建立 App Password 的 Gmail 帳號

## 授權

[MIT](LICENSE) © 2026 Kilin Yeh
