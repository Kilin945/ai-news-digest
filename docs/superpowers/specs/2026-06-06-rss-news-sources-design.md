# 設計：改用 RSS feed 當新聞來源（取代 WebSearch）

日期：2026-06-06
狀態：待使用者審閱

## 背景與問題

目前每日 AI 新聞簡報由 `run_ai_news.sh` 呼叫 `claude -p`，讓 Claude 用 **WebSearch** 以一組通用關鍵字（見 `prompt.txt`）即時搜尋，再挑 10 則輸出 HTML 寄信。

實際使用發現兩個問題：

1. **沒重點**：WebSearch 依搜尋引擎 SEO 排序，容易撈到懶人包、聚合站、SEO 部落格，而非高質量一手報導。
2. **重複**：每天跑同一組關鍵字，同一則大新聞連續多天洗版；現有去重只在「當天 10 則之內」生效，管不到跨日。

根因是「靠 WebSearch」。改 prompt（只挑指定媒體）或改用 `site:` 查詢都只是打補丁，排序與新鮮度仍由搜尋引擎決定。

## 目標

- 來源限定在數家高質量媒體與官方源頭，且「天生有重點、可去重」。
- 跨日不重複（7 天內寄過的不再出現）。
- 維持現有寄信、補跑、去重 marker 等可靠性機制不變。
- feed 清單可由使用者自行增減，不必改程式。

## 非目標

- 不做內文深讀／全文摘要爬取（使用者只需標題＋一句摘要，想深入自己點連結）。
- 不解決付費牆全文問題（只取標題與簡介，付費牆不影響）。
- 不引入資料庫或外部服務（維持單機 + 檔案狀態）。

## 方案決策

採 **方向 C：直接讀各家 RSS/Atom feed**。理由：

- RSS 是各媒體編輯選好、排序好的內容 → 天生「有重點」。
- 每筆有發布時間 → 可精準濾掉舊聞。
- 每筆有唯一 URL → 跨日去重簡單可靠。
- 沒有搜尋引擎 SEO 雜訊與重複。

被否決的替代方案：A（改 prompt 限定媒體）、B（`site:` 逐家搜尋）——皆仍依賴 WebSearch，無法根治排序與重複問題。

## 架構

```
run_ai_news.sh
   │
   ├─① fetch_feeds.py    抓 feeds.txt 內所有 feed
   │                      → 濾最近 48h（不足放寬到 72h）
   │                      → 排除 state/seen_urls.json 內 7 天內寄過的 URL
   │                      → 輸出候選清單（英文標題 / 中文標題暫無 / 來源 / 連結 / 發布時間 / 原文簡介）
   │
   ├─② claude -p          把候選清單注入 prompt，請 Claude：
   │                      挑 Top 10「主題多元、同事件只留一則、依重要性排序」
   │                      翻譯標題與摘要、輸出 HTML（不再需要 WebSearch）
   │
   ├─③ send_ai_news.py    寄信（不變）
   │
   └─④ 寄成功後           把這次採用的 URL 寫入 state/seen_urls.json（保留 7 天，自動清理過期）
```

Claude 的角色從「搜尋＋挑＋翻譯」縮小為「**從固定候選池挑重點＋翻譯**」，更快、更省、輸入可控。

## 元件

### `feeds.txt`（新增）
- 一行一個來源，格式：`<URL>\t<來源顯示名稱>`（以 tab 或 `|` 分隔），`#` 開頭為註解。
- 使用者可自行增減，無需改程式。
- 預設清單（實作時逐一驗證 URL 可抓到才納入；抓不到的標記註解保留）：

| 分類 | 來源 |
|------|------|
| 主流科技新聞 | TechCrunch (AI)、The Verge (AI)、VentureBeat (AI) |
| 深度科技媒體 | Ars Technica、Wired (AI)、MIT Technology Review |
| 官方源頭 | OpenAI、Anthropic、Google DeepMind |
| 中文/亞洲 AI 源 | 機器之心、iThome（擇可抓到且穩定者納入） |

> 註：Reuters / Bloomberg 近年關閉公開 RSS，抓不穩，先不納入；標題層級用上述已足夠涵蓋。

### `fetch_feeds.py`（新增）
- 依賴：`feedparser`（需 `pip install feedparser`，比硬解 XML 穩）。
- 流程：讀 `feeds.txt` → 逐 feed 抓取（單 feed 逾時即跳過）→ 解析出 `{title, link, published, summary, source}` → 時間窗過濾 → 對 `seen_urls.json` 去重 → 輸出候選清單（純文字或 JSON，供 shell 注入 prompt）。
- 時間窗：預設 48h；若去重後候選 < 10，自動放寬到 72h；仍不足則有幾則用幾則。
- 容錯：任一 feed 失敗只記 log、跳過，不影響其他；全部為空才回非零 exit code（交由 `run_ai_news.sh` 的補跑機制處理）。
- 參數化：時間窗（小時）可由參數/環境變數調整，供 weekly(7天) / monthly(30天) 重用。

### `state/seen_urls.json`（新增狀態檔）
- 結構：`{ "<url>": "<YYYY-MM-DD 寄出日期>", ... }`。
- 寄信「成功後」才寫入本次採用的 URL；寄失敗不寫，配合既有補跑。
- 每次執行時清理超過 7 天的項目。

### `prompt.txt` / `prompt_weekly.txt` / `prompt_monthly.txt`（修改）
- 移除「用 WebSearch 搜尋」段落，改為「以下是候選新聞清單，請從中挑選」。
- 挑選規則：主題多元、同一事件只留最具代表性一則、依重要性排序、優先近期。
- 輸出格式調整（見下）。

### `run_ai_news.sh`（修改）
- 在呼叫 claude 前先跑 `fetch_feeds.py`，把候選清單併入 prompt。
- 移除 `--allowedTools WebSearch WebFetch`（改為不需要工具，或僅保留 WebFetch 備用——預設移除）。
- 寄信成功後呼叫狀態更新，把採用的 URL 記入 `seen_urls.json`。
- 既有的網路就緒等待、逾時、重試、marker 去重、寄失敗桌面通知等機制全部保留。

## 輸出格式（每則）

順序顛倒為「英文主、中文副」，摘要保留 1～2 句：

```
1. <English title>                 ← 粗體、主視覺
   <繁體中文標題>                    ← 小字、灰
   <English summary, 1–2 sentences>
   <繁體中文摘要，1～2 句>            ← 小字
   <來源名稱> ｜ <原文連結>
```

- 共 10 則（候選不足則有幾則用幾則）。
- 最上方保留一行日期標題。
- 沿用簡潔 inline style，確保 Gmail 可讀。

## 資料流與去重時序

1. `fetch_feeds.py` 讀 `seen_urls.json` → 抓 feeds → 過濾時間窗 → 排除已 seen 的 URL → 輸出候選。
2. Claude 從候選挑 10 則 → HTML。
3. `send_ai_news.py` 寄出。
4. 寄成功 → 把採用的 URL 寫入 `seen_urls.json`（日期＝今天）並清理過期。

> 去重比對對象是「已寄出的 URL」，不是候選池；確保只壓制真的寄過的，不會誤殺。

## 錯誤處理

| 情況 | 行為 |
|------|------|
| 單一 feed 逾時/解析失敗 | 跳過該 feed、記 log，繼續其他 |
| 所有 feed 皆失敗（候選為空） | `fetch_feeds.py` 回非零；`run_ai_news.sh` 視為失敗，不寄空信，留待補跑 |
| 去重後候選 < 10 | 放寬時間窗 48h→72h；仍不足則寄出實際則數並記 log |
| Claude 輸出無效/含錯誤訊息 | 沿用既有 `looks_valid` 檢查與重試 |
| 寄信失敗（憑證等） | 沿用既有桌面通知；**不**寫入 seen_urls（下次補跑可重寄） |

## 測試與驗證

- `fetch_feeds.py` 可單獨執行，印出候選清單供人工檢視（先驗證每個 feed URL 真的抓得到）。
- 以 `--hours` 參數驗證時間窗與放寬邏輯。
- 連跑兩天（或手動塞假 `seen_urls.json`）驗證跨日去重生效。
- 端到端：手動觸發 `run_ai_news.sh`，確認信件格式（英文主/中文副）、無重複、來源皆在 `feeds.txt` 名單內。

## 對既有可靠性機制的影響

- marker 去重（每週期只寄一次）、網路等待、逾時重試、補跑、寄失敗通知 —— 全部不動，僅在「取得新聞內容」這一步換掉來源。
