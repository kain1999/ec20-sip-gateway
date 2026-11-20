#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ec20-gateway web panel — Python3 standard library only (zero deps, ~15MB RSS).

Pages:
  /login /logout          password login (sha256 vs WEB_PASS_HASH in config)
  /                       dashboard: services, memory, EC20 state, inbox size
  /sms                    inbox + send SMS form
  /logs                   gateway / asterisk / kamailio log tails
  /config                 edit DingTalk / email / missed-call / QAUDMOD settings
  POST /action            restart services, reload dialplan, push test messages

Run:  python3 app.py      (systemd unit ec20-web.service)
Config: /etc/ec20-gateway.conf (flat key=value)
"""
import base64
import hashlib
import hmac
import html
import json
import os
import re
import subprocess
import sys
import time
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

CONF_PATH = "/etc/ec20-gateway.conf"
LOG_CANDIDATES = [
    ("gateway", "/var/log/ec20-gateway.log"),
    ("asterisk", "/var/log/asterisk/messages"),
    ("kamailio", "/var/log/kamailio/kamailio.log"),
]
INBOX_DEFAULT = "/var/lib/ec20-gateway/inbox.jsonl"

# ---------------------------------------------------------------- config I/O --
def load_config():
    cfg = {}
    try:
        with open(CONF_PATH, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, val = line.partition("=")
                cfg[key.strip()] = val.strip()
    except FileNotFoundError:
        pass
    return cfg


def save_config(cfg, updates):
    """Rewrite known keys, keep unknown lines/comments in order."""
    keep = {
        "WEB_BIND", "WEB_PORT", "WEB_PASS_HASH", "WEB_SESSION_SECRET",
        "ENABLE_DINGTALK", "DINGTALK_WEBHOOK", "DINGTALK_SECRET",
        "ENABLE_EMAIL", "EMAIL_TO", "ENABLE_MISSED_CALL",
        "DEV_NAME", "QAUDMOD_MODE", "LOG_FILE", "INBOX_FILE",
    }
    cfg.update({k: v for k, v in updates.items() if k in keep})
    lines = []
    with open(CONF_PATH, "r", encoding="utf-8") as fh:
        for line in fh:
            stripped = line.strip()
            if stripped and not stripped.startswith("#") and "=" in stripped:
                key = stripped.split("=", 1)[0].strip()
                if key in cfg and key in keep:
                    lines.append("%s=%s\n" % (key, cfg[key]))
                    continue
            lines.append(line if line.endswith("\n") else line + "\n")
    # append keys missing from the file entirely
    existing = {ln.split("=", 1)[0].strip() for ln in lines if "=" in ln and not ln.strip().startswith("#")}
    for key in sorted(keep):
        if key not in existing and key in cfg:
            lines.append("%s=%s\n" % (key, cfg[key]))
    tmp = CONF_PATH + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.writelines(lines)
    os.chmod(tmp, 0o600)
    os.replace(tmp, CONF_PATH)


CFG = load_config()


def cfg(key, default=""):
    return CFG.get(key, default)


# ------------------------------------------------------------------ sessions --
SESSIONS = {}  # token -> {"ts": float, "csrf": str}


def secret():
    return cfg("WEB_SESSION_SECRET", "change-me")


def new_session():
    token = hmac.new(secret().encode(), str(time.time_ns()).encode(), hashlib.sha256).hexdigest()
    SESSIONS[token] = {
        "ts": time.time(),
        "csrf": hmac.new(secret().encode(), ("csrf" + token).encode(), hashlib.sha256).hexdigest()[:32],
    }
    return token


def session_valid(token):
    sess = SESSIONS.get(token or "")
    if not sess:
        return None
    if time.time() - sess["ts"] > 86400:
        SESSIONS.pop(token, None)
        return None
    sess["ts"] = time.time()
    return sess


def login_ok(password):
    want = cfg("WEB_PASS_HASH", "")
    if not want:
        return False
    got = hashlib.sha256(password.encode("utf-8", "replace")).hexdigest()
    return hmac.compare_digest(got, want)


# ------------------------------------------------------------------ commands --
def run_cmd(argv, timeout=15, stdin_text=None):
    try:
        proc = subprocess.run(argv, capture_output=True, text=True, timeout=timeout,
                              input=stdin_text)
        return proc.returncode, (proc.stdout or "") + (proc.stderr or "")
    except Exception as exc:  # noqa: BLE001
        return 127, "error: %s" % exc


def is_active(unit):
    rc, _ = run_cmd(["systemctl", "is-active", "--quiet", unit], timeout=5)
    return rc == 0


def tail_file(path, lines=200):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return "".join(fh.readlines()[-lines:])
    except FileNotFoundError:
        return "(file not found: %s)" % path


def read_inbox(limit=100):
    path = cfg("INBOX_FILE", INBOX_DEFAULT)
    items = []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                try:
                    items.append(json.loads(line))
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        pass
    return items[-limit:][::-1]  # newest first


# -------------------------------------------------------------------- views --
STYLE = """
  body{font-family:system-ui,-apple-system,"Segoe UI",Roboto,"PingFang SC","Microsoft YaHei",sans-serif;
       margin:0;background:#0f172a;color:#e2e8f0}
  a{color:#7dd3fc;text-decoration:none}
  nav{display:flex;gap:18px;padding:12px 20px;background:#1e293b;border-bottom:1px solid #334155}
  nav b{color:#38bdf8;margin-right:12px}
  main{padding:20px;max-width:980px;margin:0 auto}
  h2{color:#38bdf8;font-size:18px;margin:18px 0 8px}
  table{border-collapse:collapse;width:100%}
  td,th{border:1px solid #334155;padding:6px 10px;font-size:14px;text-align:left}
  th{background:#1e293b;color:#94a3b8}
  pre{background:#111827;border:1px solid #334155;padding:10px;border-radius:6px;
      overflow:auto;font-size:12px;white-space:pre-wrap}
  .ok{color:#4ade80}.bad{color:#f87171}.muted{color:#94a3b8}
  input,select,button,textarea{background:#1e293b;color:#e2e8f0;border:1px solid #475569;
      border-radius:4px;padding:6px 10px;font-size:14px}
  button{cursor:pointer}button:hover{border-color:#38bdf8}
  form.inline{display:inline}
  .grid{display:grid;grid-template-columns:1fr 1fr;gap:14px}
  .card{background:#1e293b;border:1px solid #334155;border-radius:8px;padding:14px}
  .flash{background:#064e3b;border:1px solid #10b981;padding:8px 12px;border-radius:6px;margin-bottom:12px}
  .errflash{background:#450a0a;border:1px solid #f87171}
"""


def layout(title, body, flash=""):
    nav = """
  <nav><b>ec20-gateway</b>
    <a href="/">仪表盘</a><a href="/sms">短信</a><a href="/logs">日志</a>
    <a href="/config">配置</a><a href="/logout">退出</a>
  </nav>"""
    flash_html = '<div class="flash">%s</div>' % html.escape(flash) if flash else ""
    return ("<!doctype html><html lang='zh'><head><meta charset='utf-8'>"
            "<meta name='viewport' content='width=device-width,initial-scale=1'>"
            "<title>%s :: ec20-gateway</title><style>%s</style></head>"
            "<body>%s<main>%s%s</main></body></html>"
            % (html.escape(title), STYLE, nav, flash_html, body))


def csrf_input(sess):
    return "<input type='hidden' name='csrf' value='%s'>" % sess["csrf"]


def page_login(err=""):
    body = """
<div style="max-width:360px;margin:10vh auto" class="card">
  <h2>ec20-gateway 登录</h2>
  <form method="post" action="/login">
    <input type="password" name="password" placeholder="面板密码" style="width:90%%" autofocus>
    <button type="submit">登录</button>
  </form>%s
</div>""" % ('<div class="errflash flash">%s</div>' % html.escape(err) if err else "")
    return layout("login", body)


def status_chip(active):
    return "<span class='ok'>● 运行</span>" if active else "<span class='bad'>● 停止</span>"


def page_dashboard(sess):
    units = ["asterisk", "kamailio", "ec20-web"]
    rows = "".join("<tr><td>%s</td><td>%s</td></tr>" % (u, status_chip(is_active(u))) for u in units)

    _, meminfo = run_cmd(["free", "-m"])
    dev_name = cfg("DEV_NAME", "ec20")
    _, dev_state = run_cmd(["asterisk", "-rx", "quectel show device state %s" % dev_name], timeout=10)
    inbox = read_inbox(limit=6)
    inbox_rows = "".join(
        "<tr><td>%s</td><td>%s</td><td>%s</td></tr>"
        % (html.escape(str(it.get("ts", ""))), html.escape(str(it.get("from", ""))),
           html.escape(str(it.get("text", ""))[:120]))
        for it in inbox) or "<tr><td colspan='3' class='muted'>暂无短信</td></tr>"

    _, disk = run_cmd(["df", "-h", "/"])
    _, memtop = run_cmd(["ps", "aux", "--sort=-%mem"], timeout=10)
    top_lines = "\n".join(memtop.splitlines()[:6])

    acts = [("restart_asterisk", "重启 Asterisk"), ("restart_kamailio", "重启 Kamailio"),
            ("reload_dialplan", "重载拨号计划"), ("modem_prep", "AT 预备(QAUDMOD)"),
            ("test_dingtalk", "测试钉钉"), ("test_email", "测试邮件")]
    buttons = "".join(
        "<form class='inline' method='post' action='/action'>%s"
        "<input type='hidden' name='action' value='%s'>"
        "<button type='submit'>%s</button></form>&nbsp;"
        % (csrf_input(sess), name, html.escape(label)) for name, label in acts)

    body = """
<div class="grid">
 <div class="card"><h2>服务状态</h2><table>%s</table></div>
 <div class="card"><h2>EC20 (chan_quectel)</h2><pre>%s</pre></div>
 <div class="card"><h2>内存</h2><pre>%s</pre></div>
 <div class="card"><h2>磁盘</h2><pre>%s</pre></div>
</div>
<h2>最新短信（<a href="/sms">收件箱/发送</a>）</h2>
<table><tr><th>时间</th><th>来自</th><th>内容</th></tr>%s</table>
<h2>进程占用 Top</h2><pre>%s</pre>
<h2>操作</h2><div>%s</div>
""" % (rows, html.escape(dev_state.strip() or "(no output)"),
       html.escape(meminfo.strip()), html.escape(disk.strip()),
       inbox_rows, html.escape(top_lines), buttons)
    return layout("dashboard", body)


def page_sms(sess):
    inbox = read_inbox()
    rows = "".join(
        "<tr><td>%s</td><td>%s</td><td>%s</td></tr>"
        % (html.escape(str(it.get("ts", ""))), html.escape(str(it.get("from", ""))),
           html.escape(str(it.get("text", ""))))
        for it in inbox) or "<tr><td colspan='3' class='muted'>收件箱为空</td></tr>"
    body = """
<div class="card">
  <h2>发短信（经 EC20）</h2>
  <form method="post" action="/sms/send">
    %s
    <input name="dest" placeholder="目标号码" pattern="\\+?[0-9]{3,20}" required>
    <input name="text" placeholder="短信内容" size="40" required>
    <button type="submit">发送</button>
  </form>
  <p class="muted">多段超长短信由 SIM 网络侧决定；正文最多 200 字符。</p>
</div>
<h2>收件箱（最近 %d 条）</h2>
<table><tr><th>时间</th><th>来自</th><th>内容</th></tr>%s</table>
""" % (csrf_input(sess), len(inbox), rows)
    return layout("sms", body)


def page_logs(sel):
    tabs = []
    content = ""
    for name, path in LOG_CANDIDATES:
        mark = " <b>" if name == sel else " "
        tabs.append("%s<a href='/logs?type=%s'>%s</a> " % (mark, name, name))
        if name == sel:
            content = tail_file(path)
    body = """
<p>日志： %s</p>
<pre>%s</pre>
""" % ("".join(tabs), html.escape(content.strip() or "(empty)"))
    return layout("logs", body)


def page_config(sess):
    def field(key, label, placeholder="", size=50, kind="text"):
        return ("<label>%s<br><input name='%s' value='%s' size='%d' placeholder='%s'></label><br><br>"
                % (html.escape(label), key, html.escape(cfg(key)), size,
                   html.escape(placeholder)))

    body = """
<div class="card">
  <h2>推送与 modem 配置（保存到 /etc/ec20-gateway.conf）</h2>
  <form method="post" action="/config/save">
    %s
    <h2>钉钉机器人（加签）</h2>
    <label><input type='checkbox' name='ENABLE_DINGTALK' value='yes' %s> 启用</label><br><br>
    <input name='DINGTALK_WEBHOOK' value='%s' size='70' placeholder='https://oapi.dingtalk.com/robot/send?access_token=...'><br><br>
    <input name='DINGTALK_SECRET' value='%s' size='50' placeholder='SEC...'><br><br>
    <h2>邮件</h2>
    <label><input type='checkbox' name='ENABLE_EMAIL' value='yes' %s> 启用</label><br><br>
    <input name='EMAIL_TO' value='%s' size='50' placeholder='you@example.com'><br><br>
    <h2>其他</h2>
    <label><input type='checkbox' name='ENABLE_MISSED_CALL' value='yes' %s> 未接来电也推送</label><br><br>
    <label>QAUDMOD 音频模式 (0=handset, 3=raw PCM 防杂音)
      <select name='QAUDMOD_MODE'>%s</select></label><br><br>
    <button type="submit">保存</button>
  </form>
  <p class="muted">邮件 SMTP 账号在 /etc/msmtprc（面板不改密码，改完配置记得测试）。</p>
</div>
""" % (
        csrf_input(sess),
        "checked" if cfg("ENABLE_DINGTALK", "auto") in ("yes", "auto") and cfg("DINGTALK_WEBHOOK") else "",
        html.escape(cfg("DINGTALK_WEBHOOK")),
        html.escape(cfg("DINGTALK_SECRET")),
        "checked" if cfg("ENABLE_EMAIL", "auto") in ("yes", "auto") and cfg("EMAIL_TO") else "",
        html.escape(cfg("EMAIL_TO")),
        "checked" if cfg("ENABLE_MISSED_CALL", "yes") == "yes" else "",
        "".join("<option value='%s'%s>%s</option>" % (
            n, " selected" if n == cfg("QAUDMOD_MODE", "3") else "",
            {0: "0 handset(EC/NS)", 1: "1 headset", 2: "2 speaker", 3: "3 raw PCM(推荐)"}[n])
            for n in (0, 1, 2, 3)),
    )
    return layout("config", body)


# ------------------------------------------------------------------ handlers --
class Handler(BaseHTTPRequestHandler):
    server_version = "ec20gw/1.0"

    # -- plumbing -----------------------------------------------------------
    def log_message(self, fmt, *args):  # noqa: A003
        sys.stderr.write("%s %s\n" % (self.address_string(), fmt % args))

    def _session(self):
        c = cookies.SimpleCookie(self.headers.get("Cookie", ""))
        morsel = c.get("ec20gw_session")
        return session_valid(morsel.value) if morsel else None

    def _send(self, status, body, ctype="text/html; charset=utf-8", set_cookie=None):
        data = body.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Cache-Control", "no-store")
        if set_cookie:
            self.send_header("Set-Cookie", set_cookie)
        self.end_headers()
        try:
            self.wfile.write(data)
        except BrokenPipeError:
            pass

    def _redirect(self, location):
        self.send_response(303)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _form(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        return parse_qs(self.rfile.read(length).decode("utf-8", "replace"), keep_blank_values=True)

    # -- GET ----------------------------------------------------------------
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/login":
            self._send(200, page_login())
            return
        sess = self._session()
        if not sess:
            self._redirect("/login")
            return
        if path == "/logout":
            SESSIONS.pop(self._session_token(), None)
            self._send(200, layout("bye", "<p>已退出。</p><p><a href='/login'>重新登录</a></p>"),
                       set_cookie="ec20gw_session=; Max-Age=0; Path=/")
            return
        if path == "/":
            self._send(200, page_dashboard(sess))
        elif path == "/sms":
            self._send(200, page_sms(sess))
        elif path == "/logs":
            sel = parse_qs(urlsplit(self.path).query).get("type", ["gateway"])[0]
            sel = sel if any(n == sel for n, _ in LOG_CANDIDATES) else "gateway"
            self._send(200, page_logs(sel))
        elif path == "/config":
            self._send(200, page_config(sess))
        else:
            self._send(404, layout("404", "<p>not found</p>"))

    def _session_token(self):
        c = cookies.SimpleCookie(self.headers.get("Cookie", ""))
        morsel = c.get("ec20gw_session")
        return morsel.value if morsel else ""

    # -- POST ---------------------------------------------------------------
    def do_POST(self):
        path = urlsplit(self.path).path
        form = self._form()

        if path == "/login":
            pw = form.get("password", [""])[0]
            if login_ok(pw):
                token = new_session()
                self.send_response(303)
                self.send_header("Location", "/")
                self.send_header("Set-Cookie",
                                 "ec20gw_session=%s; Path=/; HttpOnly; SameSite=Lax" % token)
                self.send_header("Content-Length", "0")
                self.end_headers()
            else:
                self._send(200, page_login("密码错误"))
            return

        sess = self._session()
        if not sess:
            self._redirect("/login")
            return
        if form.get("csrf", [""])[0] != sess["csrf"]:
            self._send(403, layout("403", "<p>CSRF 校验失败，请刷新页面重试。</p>"))
            return

        if path == "/sms/send":
            dest = form.get("dest", [""])[0].strip()
            text = form.get("text", [""])[0]
            if not re.match(r"^\+?[0-9]{3,20}$", dest) or not text.strip():
                self._send(200, page_sms(sess) + "<div class='flash errflash'>号码或内容不合法</div>")
                return
            b64 = base64.b64encode(text.encode("utf-8")).decode()
            rc, out = run_cmd(["/usr/local/sbin/sms_send_cli.sh", dest, b64], timeout=30)
            self._send(200, layout("sms", "<div class='flash'>发送 rc=%d %s</div>" % (
                rc, html.escape(out.strip()[:300]))) + page_sms(sess))
            return

        if path == "/config/save":
            def yn(key, default="no"):
                return "yes" if form.get(key, [""])[0] == "yes" else default
            updates = {
                "ENABLE_DINGTALK": "no" if not form.get("ENABLE_DINGTALK") else "yes",
                "DINGTALK_WEBHOOK": form.get("DINGTALK_WEBHOOK", [""])[0].strip(),
                "DINGTALK_SECRET": form.get("DINGTALK_SECRET", [""])[0].strip(),
                "ENABLE_EMAIL": "no" if not form.get("ENABLE_EMAIL") else "yes",
                "EMAIL_TO": form.get("EMAIL_TO", [""])[0].strip(),
                "ENABLE_MISSED_CALL": yn("ENABLE_MISSED_CALL", "no"),
                "QAUDMOD_MODE": form.get("QAUDMOD_MODE", ["3"])[0],
            }
            global CFG
            save_config(CFG, updates)
            CFG = load_config()
            self._send(200, page_config(sess) + "<div class='flash'>已保存</div>")
            return

        if path == "/action":
            action = form.get("action", [""])[0]
            rc, out = self._dispatch_action(action)
            self._send(200, layout("action",
                        "<div class='flash %s'>%s → rc=%d <pre>%s</pre></div>" % (
                            "errflash" if rc else "",
                            html.escape(action), rc, html.escape(out.strip()[:500])))
                        + page_dashboard(sess))
            return

        self._send(404, layout("404", "<p>not found</p>"))

    def _dispatch_action(self, action):
        if action == "restart_asterisk":
            return run_cmd(["systemctl", "restart", "asterisk"], timeout=60)
        if action == "restart_kamailio":
            return run_cmd(["systemctl", "restart", "kamailio"], timeout=60)
        if action == "reload_dialplan":
            return run_cmd(["asterisk", "-rx", "dialplan reload"], timeout=30)
        if action == "modem_prep":
            return run_cmd(["/usr/local/sbin/ec20_modem_prep.sh"], timeout=30)
        if action == "test_dingtalk":
            return run_cmd(["/usr/local/sbin/sms_forward.sh", "test_dingtalk"], timeout=20)
        if action == "test_email":
            return run_cmd(["/usr/local/sbin/sms_forward.sh", "test_email"], timeout=30)
        return 127, "unknown action"


def main():
    bind = cfg("WEB_BIND", "0.0.0.0")
    try:
        port = int(cfg("WEB_PORT", "8090"))
    except ValueError:
        port = 8090
    server = ThreadingHTTPServer((bind, port), Handler)
    print("ec20-gateway web panel on %s:%d" % (bind, port), flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
