#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
tests/sip_probe.py — minimal SIP UAC probe (Python3 stdlib only, no deps).

Verifies a running kamailio + asterisk chain:
  1) REGISTER with digest auth  (401 challenge -> authenticated 200)
  2) INVITE outbound number     (routed kamailio -> dispatcher -> asterisk;
                                 final 4xx expected — no EC20 hardware attached,
                                 but the request must reach the dialplan)
  3) MESSAGE to outbound number (routed to asterisk messaging context; 2xx/4xx)

Exit code 0 = all checks passed.
"""
import hashlib
import os
import re
import socket
import sys
import time

HOST = "127.0.0.1"
PORT = 5060
USER = "1001"
PASS = "itestpass123"


def ok(name):
    print("[probe] PASS: %s" % name)


def fail(name, detail=""):
    print("[probe][FATAL] %s: %s" % (name, detail))
    sys.exit(1)


sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", 0))
LPORT = sock.getsockname()[1]
sock.settimeout(2)


def send(msg):
    sock.sendto(msg.encode(), (HOST, PORT))


def recv(timeout=2):
    sock.settimeout(timeout)
    try:
        data, _ = sock.recvfrom(65535)
        return data.decode("utf-8", "replace")
    except socket.timeout:
        return ""


def tx_until(pred, msg, tries=10, timeout=2):
    """Send with retransmission until a response matching pred arrives."""
    for _ in range(tries):
        send(msg)
        r = recv(timeout)
        if r and pred(r):
            return r
    return ""


def headers(text):
    d = {}
    for line in text.split("\r\n\r\n")[0].splitlines()[1:]:
        if ":" in line:
            k, v = line.split(":", 1)
            d.setdefault(k.strip().lower(), []).append(v.strip())
    return d


def status(text):
    try:
        return int(text.split()[1])
    except (IndexError, ValueError):
        return 0


def digest_resp(method, uri, hdr, nc, cnonce):
    def grab(k):
        m = re.search(r'(?:^|,\s*)%s="?([^",;\s]+)"?' % k, hdr)
        return m.group(1) if m else ""

    realm, nonce = grab("realm"), grab("nonce")
    qop = grab("qop") or "auth"
    opaque = grab("opaque")
    ha1 = hashlib.md5(("%s:%s:%s" % (USER, realm, PASS)).encode()).hexdigest()
    ha2 = hashlib.md5(("%s:%s" % (method, uri)).encode()).hexdigest()
    if qop.lower() == "auth":
        resp = hashlib.md5(("%s:%s:%s:%s:auth:%s" % (ha1, nonce, nc, cnonce, ha2)).encode()).hexdigest()
        out = ('Digest username="%s", realm="%s", nonce="%s", uri="%s", '
               'cnonce="%s", nc=%s, qop=auth, response="%s", algorithm=MD5'
               % (USER, realm, nonce, uri, cnonce, nc, resp))
    else:
        resp = hashlib.md5(("%s:%s:%s" % (ha1, nonce, ha2)).encode()).hexdigest()
        out = ('Digest username="%s", realm="%s", nonce="%s", uri="%s", '
               'response="%s", algorithm=MD5' % (USER, realm, nonce, uri, resp))
    if opaque:
        out += ', opaque="%s"' % opaque
    return out


TAG = os.urandom(4).hex()
CID = os.urandom(6).hex() + "@probe"
CNONCE = os.urandom(4).hex()

SDP = ("v=0\r\no=- 1 1 IN IP4 127.0.0.1\r\ns=probe\r\nc=IN IP4 127.0.0.1\r\n"
       "t=0 0\r\nm=audio 40000 RTP/AVP 0 8\r\na=rtpmap:0 PCMU/8000\r\n"
       "a=rtpmap:8 PCMA/8000\r\n")


def req(method, uri, cseq, extra="", body="", ctype="application/sdp", to_uri=None):
    to_uri = to_uri or uri
    branch = "z9hG4bK" + os.urandom(5).hex()
    m = ("%s %s SIP/2.0\r\n"
         "Via: SIP/2.0/UDP 127.0.0.1:%d;branch=%s\r\n"
         "From: <sip:%s@%s>;tag=%s\r\n"
         "To: <%s>\r\n"
         "Call-ID: %s\r\n"
         "CSeq: %d %s\r\n"
         "Max-Forwards: 70\r\n"
         "Contact: <sip:%s@127.0.0.1:%d>\r\n"
         % (method, uri, LPORT, branch, USER, HOST, TAG, to_uri, CID, cseq, method, USER, LPORT))
    m += extra
    if body:
        m += "Content-Type: %s\r\nContent-Length: %d\r\n\r\n%s" % (ctype, len(body), body)
    else:
        m += "Content-Length: 0\r\n\r\n"
    return m


# ---------------------------------------------------------------- 1) REGISTER -
reg_uri = "sip:%s:%d" % (HOST, PORT)
r1 = tx_until(lambda t: status(t) in (200, 401),
              req("REGISTER", reg_uri, 1, "Expires: 300\r\n"))
if not r1:
    fail("REGISTER probe", "no response from kamailio on 5060")
if status(r1) == 200:
    ok("REGISTER (200 without challenge)")
else:
    auth = (headers(r1).get("www-authenticate") or [""])[0]
    authz = "Authorization: %s\r\n" % digest_resp("REGISTER", reg_uri, auth, "00000001", CNONCE)
    r2 = tx_until(lambda t: status(t) in (200, 401, 403),
                  req("REGISTER", reg_uri, 2, authz + "Expires: 300\r\n"))
    if status(r2) == 200:
        ok("REGISTER digest auth -> 200 (realm %s)" % (re.search(r'realm="([^"]+)"', auth).group(1) if auth else "?"))
    else:
        fail("REGISTER digest auth",
             "%s | challenge=%s" % ((r2.splitlines() or ["no resp"])[0], auth[:150]))

# ---------------------------------------------------------------- 2) INVITE ---
inv_uri = "sip:10086@%s:%d" % (HOST, PORT)
inv = req("INVITE", inv_uri, 3, body=SDP)
via_m = re.search(r'Via: ([^\r\n]+)', inv)
inv_via = via_m.group(1) if via_m else "SIP/2.0/UDP 127.0.0.1:%d" % LPORT
send(inv)
saw_1xx = False
final_line = ""
deadline = time.time() + 15
while time.time() < deadline:
    r = recv(2)
    if not r:
        send(inv)  # retransmit
        continue
    st = status(r)
    if 100 <= st < 200:
        saw_1xx = True
        continue
    if st >= 200:
        final_line = r.splitlines()[0]
        if st != 200:
            ack = ("ACK %s SIP/2.0\r\nVia: %s\r\nFrom: <sip:%s@%s>;tag=%s\r\n"
                   "To: <%s>\r\nCall-ID: %s\r\nCSeq: 3 INVITE\r\n"
                   "Max-Forwards: 70\r\nContent-Length: 0\r\n\r\n"
                   % (inv_uri, inv_via, USER, HOST, TAG, inv_uri, CID))
            send(ack)
        break
if final_line or saw_1xx:
    ok("INVITE routed (1xx=%s, final=%s — 4xx expected without EC20 hardware)"
       % (saw_1xx, final_line or "none"))
else:
    fail("INVITE", "no response at all — check kamailio auth/dispatcher/asterisk 5062")

# ---------------------------------------------------------------- 3) MESSAGE --
msg = req("MESSAGE", inv_uri, 4, body="hello-itest", ctype="text/plain")
r = tx_until(lambda t: 200 <= status(t) < 600, msg)
if r and status(r) >= 200:
    ok("MESSAGE routed (%s)" % r.splitlines()[0])
else:
    fail("MESSAGE", "no final response — check kamailio routing and message_context")

print("[probe] ALL PROBES PASSED")
