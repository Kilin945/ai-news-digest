#!/usr/bin/env bash
# AI News Digest 安裝器：自動偵測路徑、產生並安裝 launchd 排程、設定定時喚醒。
# 用法：./install.sh
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
LA_DIR="$HOME/Library/LaunchAgents"
WAKE_TIME="07:58:00"   # 每天喚醒時間（排在最早一個任務之前）

say() { printf '\033[1;34m▸ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m⚠ %s\033[0m\n' "$*"; }
ok()  { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }

# ── 1. 偵測執行檔路徑 ──
detect_bin() {
  local name="$1"; shift
  local found; found="$(command -v "$name" 2>/dev/null || true)"
  if [ -n "$found" ]; then echo "$found"; return; fi
  for p in "$@"; do [ -x "$p" ] && { echo "$p"; return; }; done
  echo ""
}
CLAUDE_BIN="$(detect_bin claude "$HOME/.local/bin/claude" /opt/homebrew/bin/claude /usr/local/bin/claude)"
PYTHON_BIN="$(detect_bin python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3)"
[ -n "$CLAUDE_BIN" ] || { warn "找不到 claude CLI，請先安裝 Claude Code 或手動填入 config.env 的 CLAUDE_BIN"; }
[ -n "$PYTHON_BIN" ] || { warn "找不到 python3，請手動填入 config.env 的 PYTHON_BIN"; }
say "claude  -> ${CLAUDE_BIN:-未偵測到}"
say "python3 -> ${PYTHON_BIN:-未偵測到}"

# ── 2. 建立 config.env（若不存在）並填入偵測到的路徑 ──
if [ ! -f "$PROJECT_DIR/config.env" ]; then
  cp "$PROJECT_DIR/config.env.example" "$PROJECT_DIR/config.env"
  [ -n "$CLAUDE_BIN" ]  && sed -i '' "s|^CLAUDE_BIN=.*|CLAUDE_BIN=\"$CLAUDE_BIN\"|"  "$PROJECT_DIR/config.env"
  [ -n "$PYTHON_BIN" ]  && sed -i '' "s|^PYTHON_BIN=.*|PYTHON_BIN=\"$PYTHON_BIN\"|"  "$PROJECT_DIR/config.env"
  warn "已建立 config.env，請編輯它填入你的 GMAIL_USER / MAIL_TO 後再重跑本腳本。"
  exit 0
fi
ok "已找到 config.env"

# 讀取設定以檢查 Keychain
# shellcheck disable=SC1091
source "$PROJECT_DIR/config.env"

# ── 3. 檢查 Keychain 是否已有 App Password ──
if security find-generic-password -a "$GMAIL_USER" -s "${KEYCHAIN_SERVICE:-ai-news-gmail}" -w >/dev/null 2>&1; then
  ok "Keychain 已有 App Password（service=${KEYCHAIN_SERVICE:-ai-news-gmail}）"
else
  warn "Keychain 尚無 App Password。請執行："
  echo "    security add-generic-password -U -a \"$GMAIL_USER\" -s \"${KEYCHAIN_SERVICE:-ai-news-gmail}\" -w \"你的16碼AppPassword\" -T /usr/bin/security"
fi

# ── 4. 由範本產生 plist 並安裝 ──
mkdir -p "$LA_DIR"
for tmpl in "$PROJECT_DIR"/launchd/*.plist.template; do
  label="$(basename "$tmpl" .plist.template)"
  dest="$LA_DIR/$label.plist"
  sed "s|__PROJECT_DIR__|$PROJECT_DIR|g" "$tmpl" > "$dest"
  launchctl unload "$dest" 2>/dev/null || true
  launchctl load "$dest"
  ok "已安裝並載入 $label"
done

# ── 5. 設定定時喚醒（需 sudo）──
echo
read -r -p "要設定每天 ${WAKE_TIME} 自動喚醒 Mac 嗎？（需要 sudo 密碼）[y/N] " ans
if [[ "$ans" =~ ^[Yy]$ ]]; then
  sudo pmset repeat wakeorpoweron MTWRFSU "$WAKE_TIME"
  ok "已設定定時喚醒（pmset）"
else
  warn "略過 pmset。蓋著螢幕時排程可能不會準時（需電腦醒著）。"
fi

echo
ok "安裝完成！手動測試：./run_ai_news.sh"
echo "  目前排程："
launchctl list | grep ai-news || true
