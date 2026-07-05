#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""每日/每週/每月 AI 新聞寄信腳本。
從 stdin 讀取 HTML 內文，透過 Gmail SMTP (STARTTLS) 寄到收件匣。

設定來源（優先序）：環境變數 > 同目錄 config.env。
Gmail App Password 依序讀取：環境變數 GMAIL_APP_PASSWORD（雲端 CI 的 secret）
> macOS Keychain（本機），程式碼/設定檔都不含明文。

用法：echo "<html>" | python3 send_ai_news.py ["主旨前綴"]
"""
import os
import sys
import ssl
import smtplib
import datetime
import subprocess
from email.mime.text import MIMEText
from email.utils import formataddr

SMTP_HOST = "smtp.gmail.com"
SMTP_PORT = 587


def load_config() -> dict:
    """讀取同目錄 config.env（KEY="value" 格式），環境變數優先。"""
    cfg = {}
    here = os.path.dirname(os.path.abspath(__file__))
    path = os.path.join(here, "config.env")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                v = os.path.expandvars(v.strip().strip('"').strip("'"))
                cfg[k.strip()] = v

    def get(key, default=None):
        return os.environ.get(key) or cfg.get(key) or default

    return {
        "GMAIL_USER": get("GMAIL_USER"),
        "MAIL_TO": get("MAIL_TO") or get("GMAIL_USER"),
        "KEYCHAIN_SERVICE": get("KEYCHAIN_SERVICE", "ai-news-gmail"),
    }


def get_app_password(gmail_user: str, service: str) -> str:
    """取得 Gmail App Password：環境變數優先（雲端 CI 用），其次 macOS Keychain。"""
    env_pw = os.environ.get("GMAIL_APP_PASSWORD", "").strip()
    if env_pw:
        return env_pw
    try:
        out = subprocess.run(
            ["security", "find-generic-password",
             "-a", gmail_user, "-s", service, "-w"],
            check=True, capture_output=True, text=True,
        )
        return out.stdout.strip()
    except subprocess.CalledProcessError as e:
        print(f"ERROR: 無法從 Keychain 讀取密碼: {e.stderr.strip()}", file=sys.stderr)
        sys.exit(3)


def main():
    conf = load_config()
    if not conf["GMAIL_USER"]:
        print("ERROR: 未設定 GMAIL_USER（請建立 config.env，參考 config.env.example）", file=sys.stderr)
        sys.exit(4)

    html_body = sys.stdin.read()

    # 防呆：Claude 偶爾會包 ```html ... ``` 圍欄，去掉它
    stripped = html_body.strip()
    if stripped.startswith("```"):
        lines = stripped.splitlines()
        if lines and lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].strip().startswith("```"):
            lines = lines[:-1]
        html_body = "\n".join(lines)

    if not html_body.strip():
        print("ERROR: 收到空的內文，停止寄送。", file=sys.stderr)
        sys.exit(2)

    today = datetime.date.today().strftime("%Y-%m-%d")
    subject_prefix = sys.argv[1] if len(sys.argv) > 1 else "每日 AI 新聞 Top 10"
    subject = f"{subject_prefix} — {today}"

    app_password = get_app_password(conf["GMAIL_USER"], conf["KEYCHAIN_SERVICE"])

    msg = MIMEText(html_body, "html", "utf-8")
    msg["Subject"] = subject
    msg["From"] = formataddr(("每日 AI 新聞", conf["GMAIL_USER"]))
    msg["To"] = conf["MAIL_TO"]

    try:
        ctx = ssl.create_default_context()
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=60) as s:
            s.starttls(context=ctx)
            s.login(conf["GMAIL_USER"], app_password)
            s.send_message(msg)
        print(f"OK: 寄送成功 -> {conf['MAIL_TO']}（主旨：{subject}）")
    except Exception as e:
        print(f"ERROR: 寄送失敗: {e!r}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
