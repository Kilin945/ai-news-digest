# AI News Digest 📰

每天、每週、每月自動把最新 AI 新聞（英文原文 + 繁體中文翻譯）寄到你的 Gmail 收件匣。

由 **macOS launchd** 排程 → 觸發 **headless Claude Code**（`claude -p`）搜尋並翻譯新聞 → 透過 **Gmail SMTP** 寄信。Gmail App Password 存放在 **macOS Keychain**，個人設定放在 gitignore 的 `config.env`，repo 不含任何明文密碼或私人信箱。

---

## 架構

```
每天 07:58  pmset 喚醒 Mac（接電源，蓋著螢幕也會醒）
─────────────────────────────────────────────────────
每天   08:00  launchd → run_ai_news.sh
每週日 08:10  launchd → run_ai_news.sh prompt_weekly.txt  "每週 AI 新聞回顧"
每月1日 08:20  launchd → run_ai_news.sh prompt_monthly.txt "每月 AI 新聞回顧"
                  │
                  ├─ claude -p（只用 WebSearch / WebFetch）→ 產出 HTML 新聞
                  └─ send_ai_news.py → Gmail SMTP 寄進收件匣
```

> 💡 為什麼用本機而非雲端排程？Anthropic 雲端沙箱封鎖所有外送 SMTP 埠（25/465/587），無法直接寄信進收件匣。改用本機 launchd 後，本機 SMTP 暢通，可直接送達。

## 檔案

| 檔案 | 作用 |
|------|------|
| `install.sh` | 安裝器：偵測路徑、產生並安裝 launchd 排程、設定喚醒 |
| `run_ai_news.sh` | 主腳本，串接 Claude → 寄信；自動偵測所在目錄、讀 config.env |
| `send_ai_news.py` | SMTP 寄信，設定讀 config.env、密碼讀 Keychain |
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

`install.sh` 會自動：偵測 `claude` / `python3` 路徑寫進 `config.env` → 由範本產生 plist（填入本專案絕對路徑）→ 安裝並載入三個排程 → 詢問是否設定每天 07:58 定時喚醒。

## 手動測試

```bash
./run_ai_news.sh                                      # 每日版
./run_ai_news.sh prompt_weekly.txt  "每週 AI 新聞回顧"   # 每週版
./run_ai_news.sh prompt_monthly.txt "每月 AI 新聞回顧"   # 每月版
tail -30 run.log                                       # 看執行紀錄
```

## 自訂

- **改新聞主題 / 則數 / 排版** → 編輯對應的 `prompt*.txt`
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
- Python 3
- 一個啟用兩步驟驗證、可建立 App Password 的 Gmail 帳號

## 授權

[MIT](LICENSE) © 2026 Kilin Yeh
