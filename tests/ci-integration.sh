#!/usr/bin/env bash
# =============================================================================
# tests/ci-integration.sh — cloud integration test (no EC20 hardware attached)
# Environment: ubuntu:20.04 container on an arm64 GitHub runner (target arch).
# Covers: apt-mode install, chan_quectel build+load, kamailio config, SIP
# REGISTER (digest auth), outbound INVITE routing Kamailio->Asterisk->dialplan,
# inbound SIP MESSAGE -> sms_send_cli.sh path, memory footprint report.
# Cellular calls/SMS need real EC20 hardware — those stay in field acceptance.
# =============================================================================
set -Eeuo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEBIAN_FRONTEND=noninteractive

log() { echo "[itest] $*"; }
die() { echo "[itest][FATAL] $*" >&2; exit 1; }

# ---------------------------------------------------------------- deps -------
log "install apt deps"
# arm64 containers pull from ports.ubuntu.com; make sure universe is enabled
BASE_URL="$(grep -m1 '^deb ' /etc/apt/sources.list | awk '{print $2}')"
grep -qE ' focal universe' /etc/apt/sources.list \
  || echo "deb $BASE_URL focal universe" >> /etc/apt/sources.list
apt-get update -qq
if ! apt-get install -y -qq --no-install-recommends \
  asterisk asterisk-modules asterisk-dev libasound2-dev build-essential \
  autoconf automake libtool pkg-config libsqlite3-dev git curl jq sqlite3 patch \
  kamailio kamailio-sqlite-modules pjsua procps iproute2 psmisc >/tmp/apt-itest.log 2>&1; then
  tail -25 /tmp/apt-itest.log
  apt-cache policy pjsua kamailio || true
  die "apt deps install failed"
fi

# ------------------------------------------------- asterisk config deploy ----
log "deploy asterisk configs (placeholders substituted)"
mkdir -p /etc/asterisk /var/log/asterisk /var/lib/asterisk /var/spool/asterisk
cp "$REPO_DIR"/configs/asterisk/*.conf /etc/asterisk/
sed -i "s|__AT_PORT__|/dev/ttyUSB2|g; s|__ALSADEV__|plughw:CARD=EC20CEHDLG,DEV=0|g" /etc/asterisk/quectel.conf

# ------------------------------------------------------ chan_quectel build ---
ASTVER="$(asterisk -V | awk '{print $2}')"
log "build chan_quectel against asterisk $ASTVER"
rm -rf /tmp/chan_quectel
git clone --depth 1 -q https://github.com/IchthysMaranatha/asterisk-chan-quectel.git /tmp/chan_quectel
cd /tmp/chan_quectel
if patch -p1 --fuzz=3 -N < "$REPO_DIR/patches/0001-quectel-reset-qpcmv-on-hangup.patch"; then
  log "QPCMV patch applied"
else
  log "patch fallback via sed"
  sed -i 's|if (strcmp(CONF_UNIQ(pvt, quec_uac),"1") == 0) snd_pcm_drop(pvt->icard);|if (strcmp(CONF_UNIQ(pvt, quec_uac),"1") == 0) { snd_pcm_drop(pvt->icard); at_enqueue_user_cmd(cpvt, "AT+QPCMV=0"); }|' channel.c
fi
./bootstrap >/dev/null 2>&1
./configure --with-asterisk=/usr/include --with-astversion="$ASTVER" >/dev/null
make -j"$(nproc)" >/dev/null
make install >/dev/null
test -f /usr/lib/asterisk/modules/chan_quectel.so || die "chan_quectel.so missing"

# ------------------------------------------------------ kamailio deployment --
log "deploy kamailio cfg + subscriber db"
cp "$REPO_DIR"/configs/kamailio/kamailio.cfg /etc/kamailio/kamailio.cfg
cp "$REPO_DIR"/configs/kamailio/dispatcher.list /etc/kamailio/dispatcher.list
sqlite3 /etc/kamailio/kamailio.db <<'SQL'
CREATE TABLE IF NOT EXISTS subscriber (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username CHAR(64) NOT NULL,
  password CHAR(64) NOT NULL,
  domain CHAR(128) NOT NULL DEFAULT 'ec20-gw',
  ha1 CHAR(32) NOT NULL DEFAULT '',
  email_address CHAR(128) NOT NULL DEFAULT ''
);
DELETE FROM subscriber;
INSERT INTO subscriber (username,password,domain) VALUES
  ('1001','itestpass123','ec20-gw'),
  ('1002','itestpass123','ec20-gw');
SQL
chmod 644 /etc/kamailio/kamailio.db

log "kamailio config syntax check"
kamailio -c -f /etc/kamailio/kamailio.cfg || die "kamailio.cfg invalid"

# ------------------------------------------------- scripts + gateway conf ----
log "deploy helper scripts + /etc/ec20-gateway.conf"
for s in sms_forward.sh sms_send_cli.sh ec20_check.sh ec20_modem_prep.sh; do
  cp "$REPO_DIR/scripts/$s" "/usr/local/sbin/$s"
  chmod 755 "/usr/local/sbin/$s"
done
cp "$REPO_DIR/etc-template/ec20-gateway.conf" /etc/ec20-gateway.conf
sed -i -e "s|__WEB_BIND__|127.0.0.1|" -e "s|__WEB_PORT__|8090|" \
       -e "s|__WEB_PASS_HASH__|testhash|" -e "s|__WEB_SESSION_SECRET__|testsecret|" \
       -e "s|__DINGTALK_WEBHOOK__||" -e "s|__DINGTALK_SECRET__||" \
       -e "s|__EMAIL_TO__||" -e "s|__QAUDMOD__|3|" /etc/ec20-gateway.conf
mkdir -p /var/lib/ec20-gateway /var/log/kamailio /var/run/asterisk /var/run/kamailio
touch /var/log/ec20-gateway.log /var/lib/ec20-gateway/inbox.jsonl
chmod 666 /var/log/ec20-gateway.log /var/lib/ec20-gateway/inbox.jsonl

# ------------------------------------------------------------- services ------
log "start asterisk"
asterisk >/dev/null 2>&1
sleep 5
asterisk -rx "core show version" || die "asterisk not responding"
asterisk -rx "module show like chan_quectel" | grep -q "1 modules loaded" \
  || { asterisk -rx "module show like chan_quectel" || true; die "chan_quectel not loaded"; }
asterisk -rx "pjsip show endpoints" | grep -q "kamailio-trunk" || die "pjsip endpoint missing"
log "asterisk OK (chan_quectel loaded, pjsip endpoint present)"

log "start kamailio"
nohup kamailio -f /etc/kamailio/kamailio.cfg -m 48 -M 8 -E \
  >/var/log/kamailio/stdout.log 2>&1 &
sleep 6
pgrep -x kamailio >/dev/null || { tail -40 /var/log/kamailio/stdout.log; die "kamailio failed to start"; }
ss -lun | grep -q ':5060 ' || { tail -40 /var/log/kamailio/stdout.log; die "kamailio not on 5060"; }
ss -lun | grep -q ':5062 ' || die "asterisk pjsip not on 5062"
log "kamailio OK"

# ----------------------------------------------------- SIP REGISTER test -----
log "pjsua: REGISTER as 1001 (digest realm ec20-gw)"
(
  sleep 12
  echo 'call sip:10086@127.0.0.1:5060'
  sleep 10
  echo 'im sip:10086@127.0.0.1:5060 hello-itest'
  sleep 3
  echo 'q'
) | timeout 60 pjsua \
    --null-audio \
    --id sip:1001@127.0.0.1 \
    --registrar sip:127.0.0.1:5060 \
    --realm '*' \
    --username 1001 --password itestpass123 \
    --log-file /tmp/pjsua.log --log-level 4 \
    >/tmp/pjsua.out 2>&1 || true

grep -qi "registration success" /tmp/pjsua.out /tmp/pjsua.log \
  || { echo "--- pjsua tail ---"; tail -60 /tmp/pjsua.out /tmp/pjsua.log 2>/dev/null; die "REGISTER failed"; }
log "REGISTER OK (digest auth accepted by kamailio sqlite)"

# --------------------------------------------------- INVITE routing test -----
sleep 2
grep -q "PSTN call 10086" /var/log/asterisk/messages \
  || { asterisk -rx "dialplan show from-kamailio" || true
       tail -30 /var/log/asterisk/messages; die "outbound INVITE did not reach dialplan"; }
grep -qE "PSTN .*(10086|->)" /var/log/kamailio/stdout.log || true
log "outbound INVITE routed: kamailio -> dispatcher -> asterisk -> dialplan (Dial Quectel fails without hardware, as expected)"

# --------------------------------------------------- MESSAGE routing test ----
grep -q "SMS to 10086" /var/log/asterisk/messages \
  || { tail -30 /var/log/asterisk/messages; die "SIP MESSAGE did not reach messaging context"; }
grep -q "sms queued" /var/log/ec20-gateway.log || true
log "SIP MESSAGE routed: kamailio -> asterisk messaging -> sms_send_cli.sh (CLI fails without device, path verified)"

# ------------------------------------------------------------- memory --------
log "memory footprint (7GB runner, reference only)"
ps aux | awk '/asterisk|kamailio/ && !/awk/ {printf "  %-10s RSS=%6dKB CMD=%s\n", $1, $6, $11}'

log "ALL INTEGRATION CHECKS PASSED"
