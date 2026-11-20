#!/usr/bin/env bash
# =============================================================================
# ec20-sip-gateway installer
# Target: Ubuntu 20.04 LTS aarch64, RAM <= 500MB
# Stack : Kamailio (5060, registrar/router) + Asterisk 20 (5062, media gw only)
#         + chan_quectel (EC20 AT + UAC audio) + SMS forward (DingTalk/mail)
#         + Python3-stdlib web panel (8090)
# =============================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- defaults ---------------------------------------------------------------
MODE="trim"                       # trim | apt
EXTENSIONS="1001,1002"
SIP_PASS=""
WEB_PASS=""
WEB_BIND="0.0.0.0"
WEB_PORT="8090"
DINGTALK_WEBHOOK=""
DINGTALK_SECRET=""
EMAIL_TO=""
SMTP_HOST=""
SMTP_PORT="465"
SMTP_USER=""
SMTP_PASS=""
SMTP_FROM=""
QAUDMOD="3"
PROXY=""
NO_SWAP="0"
NO_PATCH="0"
SKIP_BUILD="0"
SKIP_DEPLOY="0"

CHAN_QUECTEL_REPO="${CHAN_QUECTEL_REPO:-https://github.com/IchthysMaranatha/asterisk-chan-quectel.git}"
CHAN_QUECTEL_REF="${CHAN_QUECTEL_REF:-3d45c7f072131296a7e3c1a4faf5bb18751dbd87}"
ASTERISK_URL="${ASTERISK_URL:-https://downloads.asterisk.org/pub/telephony/asterisk/asterisk-20-current.tar.gz}"

SRC_ROOT="/usr/src"
AST_SRC_DIR=""
ASTVER=""
AT_PORT=""
ALSADEV=""

C_DINGTALK_WEBHOOK=""
C_DINGTALK_SECRET=""
C_EMAIL_TO=""

log()  { echo -e "\033[1;32m[install]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*" >&2; }
err()  { echo -e "\033[1;31m[error]\033[0m $*" >&2; }

# --- args -------------------------------------------------------------------
usage() { grep '^#  --' "$0" | sed 's/^#//'; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)              MODE="$2"; shift 2 ;;
    --ext)               EXTENSIONS="$2"; shift 2 ;;
    --sip-pass)          SIP_PASS="$2"; shift 2 ;;
    --web-pass)          WEB_PASS="$2"; shift 2 ;;
    --web-bind)          WEB_BIND="$2"; shift 2 ;;
    --web-port)          WEB_PORT="$2"; shift 2 ;;
    --webhook)           C_DINGTALK_WEBHOOK="$2"; shift 2 ;;
    --dingtalk-secret)   C_DINGTALK_SECRET="$2"; shift 2 ;;
    --email)             C_EMAIL_TO="$2"; shift 2 ;;
    --smtp-host)         SMTP_HOST="$2"; shift 2 ;;
    --smtp-port)         SMTP_PORT="$2"; shift 2 ;;
    --smtp-user)         SMTP_USER="$2"; shift 2 ;;
    --smtp-pass)         SMTP_PASS="$2"; shift 2 ;;
    --smtp-from)         SMTP_FROM="$2"; shift 2 ;;
    --qaudmod)           QAUDMOD="$2"; shift 2 ;;
    --proxy)             PROXY="$2"; shift 2 ;;
    --no-swap)           NO_SWAP="1"; shift ;;
    --no-patch)          NO_PATCH="1"; shift ;;
    --skip-build)        SKIP_BUILD="1"; shift ;;
    --skip-deploy)       SKIP_BUILD="1"; SKIP_DEPLOY="1"; shift ;;
    -h|--help)           usage ;;
    *) err "unknown arg: $1"; usage ;;
  esac
done

[[ $EUID -ne 0 ]] && { err "run as root: sudo ./install.sh"; exit 1; }
if ! dpkg --print-architecture 2>/dev/null | grep -q arm64; then
  warn "not arm64 (detected: $(dpkg --print-architecture 2>/dev/null || echo '?')); script targets aarch64, continuing anyway"
fi

# validate extensions: must be 1XXX (4 digits starting with 1)
IFS=',' read -r -a EXT_ARR <<< "$EXTENSIONS"
for e in "${EXT_ARR[@]}"; do
  [[ "$e" =~ ^1[0-9]{3}$ ]] || { err "extension '$e' invalid; must be 4 digits starting with 1 (e.g. 1001)"; exit 1; }
done

# --- proxy plumbing ---------------------------------------------------------
CURL_PROXY=()
GIT_PROXY_ARGS=()
if [[ -n "$PROXY" ]]; then
  CURL_PROXY=(--proxy "$PROXY")
  GIT_PROXY_ARGS=(-c "http.proxy=$PROXY")
  export http_proxy="$PROXY" https_proxy="$PROXY" HTTP_PROXY="$PROXY" HTTPS_PROXY="$PROXY"
  export all_proxy="$PROXY" ALL_PROXY="$PROXY"
  log "proxy enabled: $PROXY"
fi

# --- stage 0: swap for low-RAM compile ---------------------------------------
setup_swap() {
  if [[ "$NO_SWAP" == "1" ]]; then warn "--no-swap given, skip swap setup"; return; fi
  local mem_kb swap_total
  mem_kb="$(awk '/MemTotal/{print $2}' /proc/meminfo)"
  swap_total="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"
  if [[ "${swap_total:-0}" -ge 1000000 ]]; then log "swap >= 1G already present"; return; fi
  if [[ "$mem_kb" -gt 900000 ]]; then log "RAM > 900MB, swap optional; creating 1G anyway for safety"; fi
  log "creating 1G swapfile /swapfile (protects Asterisk compile on 500MB boards)"
  if [[ -e /swapfile ]]; then rm -f /swapfile; fi
  dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none
  chmod 600 /swapfile
  mkswap -q /swapfile
  swapon /swapfile
  grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  log "swap active: $(awk '/SwapTotal/{printf "%.0fMB", $2/1024}' /proc/meminfo)"
}

# --- stage 1: packages --------------------------------------------------------
APT_PACKAGES_COMMON=(curl wget jq openssl sqlite3 patch udev msmtp ca-certificates)
APT_PACKAGES_TRIM=(build-essential libncurses5-dev libssl-dev libxml2-dev libsqlite3-dev \
                   uuid-dev libjansson-dev pkg-config autoconf automake libtool bison flex git)
APT_PACKAGES_APT=(asterisk asterisk-modules asterisk-dev)

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log "apt-get update"
  apt-get update -y
  log "apt-get install common deps"
  apt-get install -y --no-install-recommends "${APT_PACKAGES_COMMON[@]}" "${APT_PACKAGES_TRIM[@]}" || apt-get install -y "${APT_PACKAGES_COMMON[@]}" "${APT_PACKAGES_TRIM[@]}"
  if [[ "$MODE" == "apt" ]]; then
    log "apt-get install asterisk (binary mode)"
    apt-get install -y "${APT_PACKAGES_APT[@]}"
  fi
  log "apt-get install kamailio + sqlite driver"
  apt-get install -y kamailio kamailio-sqlite-modules || {
    err "kamailio install failed; check sources.list has universe"; exit 1;
  }
  # modem manager grabs the EC20 AT port and fights chan_quectel
  if systemctl is-active --quiet ModemManager 2>/dev/null; then
    log "stopping ModemManager (conflicts with chan_quectel AT port)"
    systemctl stop ModemManager
    systemctl disable ModemManager 2>/dev/null || true
  fi
}

# --- stage 2: Asterisk (trim: source build with menuselect whitelist) ----------
build_asterisk_trim() {
  log "downloading Asterisk 20 source (${ASTERISK_URL})"
  mkdir -p "$SRC_ROOT"
  curl -fsSL "${CURL_PROXY[@]}" -o "$SRC_ROOT/asterisk-20.tar.gz" "$ASTERISK_URL"
  rm -rf "$SRC_ROOT"/asterisk-20.*
  tar xzf "$SRC_ROOT/asterisk-20.tar.gz" -C "$SRC_ROOT"
  AST_SRC_DIR="$(ls -d "$SRC_ROOT"/asterisk-20.* | head -n1)"
  cd "$AST_SRC_DIR"

  log "configure (pjproject bundled)"
  if ! ./configure --with-pjproject-bundled >> /tmp/ast-configure.log 2>&1; then
    warn "configure with bundled pjproject failed; falling back to system libpjproject"
    apt-get install -y libpjproject-dev || true
    ./configure >> /tmp/ast-configure.log 2>&1
  fi

  log "menuselect: whitelist trim (PJSIP + chan_quectel needs only)"
  make menuselect.makeopts
  MS="menuselect/menuselect"
  # compiler flags
  $MS --disable BUILD_NATIVE menuselect.makeopts
  $MS --enable  LOW_MEMORY  menuselect.makeopts
  # channels: only chan_pjsip (chan_quectel is compiled separately)
  $MS --disable-category MENUSELECT_CHANNELS menuselect.makeopts
  $MS --enable chan_pjsip menuselect.makeopts
  # apps
  $MS --disable-category MENUSELECT_APPS menuselect.makeopts
  for a in app_dial app_echo app_playback app_system app_verbose; do
    $MS --enable "$a" menuselect.makeopts || true
  done
  # funcs
  $MS --disable-category MENUSELECT_FUNCS menuselect.makeopts
  for f in func_callerid func_base64 func_strings; do
    $MS --enable "$f" menuselect.makeopts || true
  done
  # codecs: EC20 UAC is 8kHz narrowband PCM; G.711 only
  $MS --disable-category MENUSELECT_CODECS menuselect.makeopts
  for c in codec_alaw codec_ulaw; do
    $MS --enable "$c" menuselect.makeopts || true
  done
  # formats
  $MS --disable-category MENUSELECT_FORMATS menuselect.makeopts
  for f in format_sln format_wav format_pcm; do
    $MS --enable "$f" menuselect.makeopts || true
  done
  # bridges
  $MS --disable-category MENUSELECT_BRIDGES menuselect.makeopts
  for b in bridge_simple bridge_native_rtp; do
    $MS --enable "$b" menuselect.makeopts || true
  done
  # pbx
  $MS --disable-category MENUSELECT_PBX menuselect.makeopts
  $MS --enable pbx_config menuselect.makeopts
  # cdr/cel/tests off
  $MS --disable-category MENUSELECT_CDR  menuselect.makeopts || true
  $MS --disable-category MENUSELECT_CEL  menuselect.makeopts || true
  $MS --disable-category MENUSELECT_TESTS menuselect.makeopts || true
  # res: keep all (dependency safety), then knock out heavy unused ones
  for r in res_xmpp res_phoneprov res_snmp res_odbc res_fax res_fax_spandsp res_pktccops \
           res_hep res_hep_pjsip res_stasis res_ari res_ari_asterisk res_ari_channels \
           res_ari_endpoints res_ari_events res_ari_model res_ari_playbacks res_ari_recordings \
           res_ari_device_states res_http_websocket res_adsi res_smdi res_security_log \
           res_musiconhold res_parking res_agi res_calendar res_calendar_caldav res_calendar_ews \
           res_calendar_exchange res_calendar_icalendar res_corosync res_statsd; do
    $MS --disable "$r" menuselect.makeopts || true
  done

  log "compiling Asterisk with -j1 (low RAM; 30-90 min on ARM boards)"
  make -j1
  make install
  # systemd unit from contrib
  if [[ -f contrib/systemd/asterisk.service ]]; then
    cp contrib/systemd/asterisk.service /lib/systemd/system/asterisk.service
  fi
  log "modules installed: $(ls /usr/lib/asterisk/modules/*.so 2>/dev/null | wc -l) .so files (trimmed baseline)"
}

setup_asterisk_apt() {
  log "using Ubuntu asterisk package (mode=apt)"
  ASTVER="$(asterisk -V 2>/dev/null | awk '{print $2}')"
}

# --- stage 3: chan_quectel ----------------------------------------------------
build_chan_quectel() {
  log "fetching chan_quectel: $CHAN_QUECTEL_REPO @ $CHAN_QUECTEL_REF"
  rm -rf "$SRC_ROOT/chan_quectel"
  git clone "${GIT_PROXY_ARGS[@]}" "$CHAN_QUECTEL_REPO" "$SRC_ROOT/chan_quectel"
  cd "$SRC_ROOT/chan_quectel"
  git checkout "${GIT_PROXY_ARGS[@]}" -q "$CHAN_QUECTEL_REF"

  if [[ "$NO_PATCH" != "1" ]]; then
    if patch -p1 --fuzz=3 -N < "$SCRIPT_DIR/patches/0001-quectel-reset-qpcmv-on-hangup.patch" \
         && grep -q 'AT+QPCMV=0' channel.c; then
      log "patch applied: QPCMV reset on hangup (fixes silent 2nd call)"
    elif grep -q 'snd_pcm_drop(pvt->icard); at_enqueue_user_cmd' channel.c; then
      log "QPCMV hangup reset already present in source"
    elif sed -i 's|if (strcmp(CONF_UNIQ(pvt, quec_uac),"1") == 0) snd_pcm_drop(pvt->icard);|if (strcmp(CONF_UNIQ(pvt, quec_uac),"1") == 0) { snd_pcm_drop(pvt->icard); at_enqueue_user_cmd(cpvt, "AT+QPCMV=0"); }|' channel.c \
         && grep -q 'AT+QPCMV=0' channel.c; then
      log "patch applied via sed fallback"
    else
      warn "could not apply QPCMV hangup patch; symptom: 2nd call may be silent until asterisk restart"
    fi
  fi

  log "bootstrap + configure (astversion=$ASTVER)"
  ./bootstrap
  ./configure --with-asterisk=/usr/include --with-astversion="$ASTVER"
  make -j1
  make install
  [[ -f /usr/lib/asterisk/modules/chan_quectel.so ]] || { err "chan_quectel.so missing after make install"; exit 1; }
  log "chan_quectel.so installed"
}

# --- hardware probes -----------------------------------------------------------
probe_devices() {
  log "probing EC20 hardware"
  if ! lsusb | grep -qi '2c7c'; then
    warn "no Quectel USB device (2c7c:xxxx) found — plug the EC20 and rerun install.sh"
  fi
  # AT port: udev symlink after rules reload, fallback ttyUSB2
  AT_PORT="/dev/ec20-at"
  [[ -e "$AT_PORT" ]] || AT_PORT="/dev/ttyUSB2"
  [[ -e "$AT_PORT" ]] || { AT_PORT="/dev/ttyUSB2"; warn "AT port not found; defaulting to $AT_PORT (plug EC20, rerun if needed)"; }
  log "AT port: $AT_PORT"

  # ALSA card: EC20 UAC card name from /proc/asound/cards (e.g. EC20CEHDLG)
  local card_name=""
  card_name="$(grep -iE 'ec20' /proc/asound/cards 2>/dev/null | head -n1 | sed -n 's/^ *[0-9]* *\[\([^]]*\) *\].*/\1/p')"
  if [[ -z "$card_name" ]]; then
    card_name="$(grep -iE 'usb-audio' /proc/asound/cards 2>/dev/null | head -n1 | sed -n 's/^ *[0-9]* *\[\([^]]*\) *\].*/\1/p')"
  fi
  if [[ -n "$card_name" ]]; then
    ALSADEV="plughw:CARD=${card_name},DEV=0"
    log "ALSA device: $ALSADEV"
  else
    ALSADEV="plughw:CARD=EC20CEHDLG,DEV=0"
    warn "no UAC sound card found in /proc/asound/cards"
    warn "  - if EC20 UAC is not enumerated, see docs/EC20-DEBUG.md (AT+QPCMV / firmware)"
    warn "  - alsadev placeholder written: $ALSADEV ; fix and rerun or edit /etc/asterisk/quectel.conf"
  fi
}

# --- stage 4: config deployment --------------------------------------------------
deploy_asterisk_configs() {
  local ts; ts="$(date +%Y%m%d%H%M%S)"
  log "backing up /etc/asterisk -> /etc/asterisk.backup.$ts"
  if [[ -d /etc/asterisk ]]; then cp -a /etc/asterisk "/etc/asterisk.backup.$ts"; fi
  mkdir -p /etc/asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk

  install -m 644 "$SCRIPT_DIR/configs/asterisk/pjsip.conf"       /etc/asterisk/pjsip.conf
  install -m 644 "$SCRIPT_DIR/configs/asterisk/extensions.conf"  /etc/asterisk/extensions.conf
  install -m 644 "$SCRIPT_DIR/configs/asterisk/modules.conf"     /etc/asterisk/modules.conf
  install -m 644 "$SCRIPT_DIR/configs/asterisk/logger.conf"      /etc/asterisk/logger.conf
  install -m 644 "$SCRIPT_DIR/configs/asterisk/rtp.conf"         /etc/asterisk/rtp.conf
  sed -e "s|__AT_PORT__|$AT_PORT|g" -e "s|__ALSADEV__|$ALSADEV|g" \
      "$SCRIPT_DIR/configs/asterisk/quectel.conf" > /etc/asterisk/quectel.conf
  chmod 644 /etc/asterisk/*.conf
}

deploy_kamailio() {
  local ts; ts="$(date +%Y%m%d%H%M%S)"
  log "deploying Kamailio config"
  [[ -d /etc/kamailio ]] && cp -a /etc/kamailio "/etc/kamailio.backup.$ts"
  install -m 644 "$SCRIPT_DIR/configs/kamailio/kamailio.cfg" /etc/kamailio/kamailio.cfg
  install -m 644 "$SCRIPT_DIR/configs/kamailio/dispatcher.list" /etc/kamailio/dispatcher.list

  # subscriber database (digest auth, plain password column + calculate_ha1)
  log "creating SQLite subscriber DB: /etc/kamailio/kamailio.db"
  sqlite3 /etc/kamailio/kamailio.db <<'SQL'
CREATE TABLE IF NOT EXISTS subscriber (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  username CHAR(64) NOT NULL,
  password CHAR(64) NOT NULL,
  domain CHAR(128) NOT NULL DEFAULT 'ec20-gw',
  ha1 CHAR(32) NOT NULL DEFAULT '',
  email_address CHAR(128) NOT NULL DEFAULT ''
);
SQL
  sqlite3 /etc/kamailio/kamailio.db "DELETE FROM subscriber;"
  for e in "${EXT_ARR[@]}"; do
    sqlite3 /etc/kamailio/kamailio.db \
      "INSERT INTO subscriber (username,password,domain) VALUES ('${e}','${SIP_PASS}','ec20-gw');"
  done
  chmod 640 /etc/kamailio/kamailio.db
  if getent passwd kamailio >/dev/null 2>&1; then
    chown kamailio:kamailio /etc/kamailio/kamailio.db
  else
    chmod 644 /etc/kamailio/kamailio.db
  fi

  # memory knobs for 500MB boards (per phase-3 plan)
  touch /etc/default/kamailio
  sed -i '/^RUN_KAMAILIO=/d; /^SHM_MEMORY=/d; /^PKG_MEMORY=/d' /etc/default/kamailio
  { echo "RUN_KAMAILIO=yes"; echo "SHM_MEMORY=48"; echo "PKG_MEMORY=8"; } >> /etc/default/kamailio

  # OOM protection: kamailio must survive, asterisk may be sacrificed
  install -m 644 "$SCRIPT_DIR/configs/systemd/kamailio.service.d/oom.conf" \
    /etc/systemd/system/kamailio.service.d/oom.conf 2>/dev/null || {
    mkdir -p /etc/systemd/system/kamailio.service.d
    install -m 644 "$SCRIPT_DIR/configs/systemd/kamailio.service.d/oom.conf" \
      /etc/systemd/system/kamailio.service.d/oom.conf
  }
  mkdir -p /etc/systemd/system/asterisk.service.d
  install -m 644 "$SCRIPT_DIR/configs/systemd/asterisk.service.d/oom.conf" \
    /etc/systemd/system/asterisk.service.d/oom.conf
}

deploy_udev_and_perms() {
  log "deploying udev rules + device permissions"
  install -m 644 "$SCRIPT_DIR/configs/udev/99-ec20.rules" /etc/udev/rules.d/99-ec20.rules
  udevadm control --reload-rules 2>/dev/null || true
  udevadm trigger 2>/dev/null || true
  sleep 2
  id asterisk &>/dev/null || useradd -r -s /usr/sbin/nologin -d /var/lib/asterisk asterisk
  usermod -aG audio,dialout asterisk
  chown -R asterisk:asterisk /var/lib/asterisk /var/log/asterisk /var/spool/asterisk
  if [[ "$MODE" == "trim" ]]; then
    chown -R asterisk:asterisk /usr/lib/asterisk/modules 2>/dev/null || true
  fi
  if [[ -e "$AT_PORT" ]]; then
    chown root:dialout "$AT_PORT" 2>/dev/null || true
    chmod 660 "$AT_PORT" 2>/dev/null || true
  fi
}

deploy_scripts_and_gateway_conf() {
  log "installing helper scripts"
  for s in sms_forward.sh sms_send_cli.sh ec20_check.sh ec20_modem_prep.sh; do
    install -m 755 "$SCRIPT_DIR/scripts/$s" "/usr/local/sbin/$s"
  done

  if [[ -z "$SIP_PASS" ]];  then SIP_PASS="$(openssl rand -hex 12)";  fi
  if [[ -z "$WEB_PASS" ]];  then WEB_PASS="$(openssl rand -hex 6)";   fi
  WEB_PASS_HASH="$(printf '%s' "$WEB_PASS" | openssl dgst -sha256 | awk '{print $2}')"
  WEB_SECRET="$(openssl rand -hex 24)"

  log "writing /etc/ec20-gateway.conf"
  sed -e "s|__WEB_BIND__|$WEB_BIND|g" \
      -e "s|__WEB_PORT__|$WEB_PORT|g" \
      -e "s|__WEB_PASS_HASH__|$WEB_PASS_HASH|g" \
      -e "s|__WEB_SESSION_SECRET__|$WEB_SECRET|g" \
      -e "s|__DINGTALK_WEBHOOK__|$C_DINGTALK_WEBHOOK|g" \
      -e "s|__DINGTALK_SECRET__|$C_DINGTALK_SECRET|g" \
      -e "s|__EMAIL_TO__|$C_EMAIL_TO|g" \
      -e "s|__QAUDMOD__|$QAUDMOD|g" \
      "$SCRIPT_DIR/etc-template/ec20-gateway.conf" > /etc/ec20-gateway.conf
  chmod 600 /etc/ec20-gateway.conf

  if [[ -n "$SMTP_HOST" ]]; then
    log "writing /etc/msmtprc"
    cat > /etc/msmtprc <<MSTMPRC
# ec20-gateway mail relay (msmtp)
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           ${SMTP_HOST}
port           ${SMTP_PORT}
from           ${SMTP_FROM:-${SMTP_USER}}
user           ${SMTP_USER}
password       ${SMTP_PASS}
MSMTPRC
    chmod 600 /etc/msmtprc
  else
    warn "no --smtp-host given; edit /etc/msmtprc manually to enable email push"
    cat > /etc/msmtprc <<'MSTMPRC'
# ec20-gateway mail relay (msmtp) -- FILL ME
defaults
auth           on
tls            on
tls_trust_file /etc/ssl/certs/ca-certificates.crt
logfile        /var/log/msmtp.log

account        default
host           smtp.example.com
port           465
from           you@example.com
user           you@example.com
password       CHANGE_ME
MSTMPRC
    chmod 600 /etc/msmtprc
  fi

  mkdir -p /var/lib/ec20-gateway
  touch /var/log/ec20-gateway.log /var/lib/ec20-gateway/inbox.jsonl
  chmod 664 /var/log/ec20-gateway.log /var/lib/ec20-gateway/inbox.jsonl
  chown asterisk:asterisk /var/log/ec20-gateway.log /var/lib/ec20-gateway/inbox.jsonl 2>/dev/null || true
}

deploy_system_and_web() {
  log "deploying systemd units"
  mkdir -p /etc/systemd/system
  install -m 644 "$SCRIPT_DIR/configs/systemd/ec20-modem-prep.service" /etc/systemd/system/ec20-modem-prep.service
  install -m 644 "$SCRIPT_DIR/configs/systemd/ec20-web.service" /etc/systemd/system/ec20-web.service

  log "deploying web panel"
  mkdir -p /opt/ec20-gateway-web
  install -m 755 "$SCRIPT_DIR/web/app.py" /opt/ec20-gateway-web/app.py

  log "deploying rsyslog + logrotate"
  install -m 644 "$SCRIPT_DIR/configs/rsyslog/ec20-gateway.conf" /etc/rsyslog.d/ec20-gateway.conf
  mkdir -p /var/log/kamailio
  install -m 644 "$SCRIPT_DIR/configs/logrotate/ec20-gateway" /etc/logrotate.d/ec20-gateway

  systemctl daemon-reload
  systemctl restart rsyslog 2>/dev/null || true

  log "enabling services: ec20-modem-prep -> asterisk -> kamailio -> ec20-web"
  systemctl enable --now ec20-modem-prep 2>/dev/null || true
  systemctl enable asterisk >/dev/null 2>&1 || true
  systemctl enable kamailio >/dev/null 2>&1 || true
  systemctl enable ec20-web >/dev/null 2>&1 || true
  systemctl restart asterisk
  systemctl restart kamailio
  systemctl restart ec20-web
}

verify() {
  log "verification"
  sleep 4
  local ok=1
  systemctl is-active --quiet asterisk || { warn "asterisk not active"; ok=0; }
  systemctl is-active --quiet kamailio || { warn "kamailio not active"; ok=0; }
  systemctl is-active --quiet ec20-web || { warn "ec20-web not active"; ok=0; }
  if asterisk -rx "module show like chan_quectel" 2>/dev/null | grep -q "1 modules loaded"; then
    log "chan_quectel module loaded"
  else
    warn "chan_quectel module not loaded (check /var/log/asterisk/messages)"
    ok=0
  fi
  asterisk -rx "quectel show devices" 2>/dev/null || true
  kamailio -c -f /etc/kamailio/kamailio.cfg >/dev/null 2>&1 || warn "kamailio config check returned nonzero (service may still run)"
  return $((1 - ok))
}

print_report() {
  local ip; ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  echo
  echo "========================= ec20-sip-gateway installed ========================="
  echo " SIP (Kamailio)     : udp://${ip:-<board-ip>}:5060   realm: ec20-gw"
  echo " Extensions         : ${EXT_ARR[*]}   password: ${SIP_PASS}"
  echo " Web panel          : http://${ip:-<board-ip>}:${WEB_PORT}   password: ${WEB_PASS}"
  echo " Asterisk (loopback): udp://0.0.0.0:5062 (Kamailio-only signalling)"
  echo " AT port / ALSA     : ${AT_PORT} / ${ALSADEV}"
  echo " DingTalk webhook   : ${C_DINGTALK_WEBHOOK:+configured}${C_DINGTALK_WEBHOOK:-not set (use web panel)}"
  echo " Email to           : ${C_EMAIL_TO:-not set (edit /etc/msmtprc + web panel)}"
  echo "------------------------------------------------------------------------------"
  echo " Next steps:"
  echo "   1. register a softphone to 5060 with extension/password above (codec alaw)"
  echo "   2. dial any mobile number from the softphone -> EC20 dials out"
  echo "   3. call the SIM number from another phone -> extensions ring"
  echo "   4. text the SIM number -> message arrives at DingTalk/mail + web inbox"
  echo "   5. verify:  ./scripts/ec20_check.sh"
  echo "=============================================================================="
}

main() {
  [[ "$MODE" == "trim" || "$MODE" == "apt" ]] || { err "--mode must be trim|apt"; exit 1; }
  if [[ "$SKIP_BUILD" != "1" ]]; then
    setup_swap
    install_packages
    if [[ "$MODE" == "trim" ]]; then
      build_asterisk_trim
    else
      setup_asterisk_apt
    fi
    build_chan_quectel
  else
    log "--skip-build: reusing existing asterisk/channels on this machine"
  fi
  ASTVER="${ASTVER:-$(asterisk -V 2>/dev/null | awk '{print $2}')}"
  [[ -n "$ASTVER" ]] || { err "cannot detect asterisk version (asterisk -V)"; exit 1; }
  log "asterisk version: $ASTVER"
  if [[ "$SKIP_DEPLOY" == "1" ]]; then
    log "--skip-deploy: build-only run finished (see docs/CROSS-COMPILE.md for packing)"
    exit 0
  fi
  probe_devices
  deploy_asterisk_configs
  deploy_kamailio
  deploy_udev_and_perms
  deploy_scripts_and_gateway_conf
  deploy_system_and_web
  if verify; then log "ALL SERVICES UP"; else warn "some services need attention (see warnings above)"; fi
  print_report
}

main "$@"
