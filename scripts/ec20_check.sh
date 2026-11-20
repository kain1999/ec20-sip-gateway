#!/usr/bin/env bash
# =============================================================================
# ec20_check.sh — full-chain health check for the ec20-sip-gateway appliance
# Exit 0 only when every critical item passes.
# =============================================================================
set -u

CONF="/etc/ec20-gateway.conf"
cfg() { grep -E "^$1=" "$CONF" 2>/dev/null | head -n1 | cut -d= -f2- | sed 's/[[:space:]]*$//'; }

OK()   { printf '  [\033[32m OK \033[0m] %s\n' "$*"; }
FAIL() { printf '  [\033[31mFAIL\033[0m] %s\n' "$*"; FAILED=1; }
WARN() { printf '  [\033[33mWARN\033[0m] %s\n' "$*"; }
hdr()  { printf '\n== %s ==\n' "$*"; }

FAILED=0

hdr "hardware / EC20"
if lsusb 2>/dev/null | grep -qi '2c7c'; then
  OK "Quectel USB device present: $(lsusb | grep -i 2c7c | head -n1)"
else
  FAIL "no Quectel USB device (2c7c:xxxx) — check power/cable"
fi
if [[ -e /dev/ec20-at ]]; then
  OK "AT port: /dev/ec20-at ($(readlink -f /dev/ec20-at))"
else
  WARN "/dev/ec20-at missing (udev rule not applied yet?); falling back"
  if [[ -e /dev/ttyUSB2 ]]; then OK "fallback AT port: /dev/ttyUSB2"; else FAIL "no /dev/ttyUSB2"; fi
fi
if grep -qiE 'ec20|usb-audio' /proc/asound/cards 2>/dev/null; then
  OK "UAC sound card: $(grep -iE 'ec20|usb-audio' /proc/asound/cards | head -n1 | sed 's/^[[:space:]]*//')"
  alsadev="$(cfg 'alsadev' 2>/dev/null || true)"
  q="$(grep -E '^alsadev' /etc/asterisk/quectel.conf 2>/dev/null | cut -d= -f2-)"
  [[ -n "$q" ]] && OK "quectel.conf alsadev: $q"
else
  FAIL "/proc/asound/cards has no EC20/USB-Audio entry (firmware UAC support?)"
fi

hdr "services"
for s in asterisk kamailio ec20-web ec20-modem-prep; do
  if systemctl is-active --quiet "$s"; then OK "$s active"; else FAIL "$s not active"; fi
done

hdr "asterisk internals"
if command -v asterisk >/dev/null 2>&1; then
  if asterisk -rx "module show like chan_quectel" 2>/dev/null | grep -q "1 modules loaded"; then
    OK "chan_quectel loaded"
  else
    FAIL "chan_quectel not loaded (see /var/log/asterisk/messages)"
  fi
  out="$(asterisk -rx "quectel show devices" 2>/dev/null)"
  if echo "$out" | grep -qE 'ec20'; then
    OK "quectel device:"
    echo "$out" | sed 's/^/        /'
  else
    FAIL "no quectel device bound (AT port busy? ModemManager?)"
  fi
else
  FAIL "asterisk binary missing"
fi

hdr "kamailio"
if command -v kamailio >/dev/null 2>&1; then
  if kamailio -c -f /etc/kamailio/kamailio.cfg >/dev/null 2>&1; then
    OK "config syntax OK"
  else
    FAIL "kamailio.cfg invalid"
  fi
  if ss -lun 2>/dev/null | grep -q ':5060 '; then OK "listening udp/5060"; else FAIL "not listening udp/5060"; fi
else
  FAIL "kamailio binary missing"
fi
if ss -lun 2>/dev/null | grep -q ':5062 '; then OK "asterisk signalling udp/5062"; else WARN "asterisk not listening udp/5062 yet"; fi
if ss -ltn 2>/dev/null | grep -q ":$(cfg WEB_PORT || echo 8090) "; then OK "web panel listening"; else WARN "web panel not listening"; fi

hdr "memory (500MB budget)"
free -m | awk 'NR==1||/Mem|Swap/' | sed 's/^/        /'
top_avail="$(free -m | awk '/^Mem:/{print $7}')"
if [[ -n "$top_avail" && "$top_avail" -lt 30 ]]; then
  WARN "available RAM ${top_avail}MB < 30MB — consider bigger zram or fewer modules"
else
  OK "available RAM: ${top_avail:-?}MB"
fi
ps aux --sort=-%mem 2>/dev/null | awk 'NR<=2 || /asterisk|kamailio|python3/' | head -6 | sed 's/^/        /'

hdr "sms push config"
[[ -n "$(cfg DINGTALK_WEBHOOK)" ]] && OK "DingTalk webhook configured" || WARN "DingTalk webhook empty (web panel -> Config)"
[[ -n "$(cfg EMAIL_TO)" ]] && OK "EMAIL_TO configured" || WARN "EMAIL_TO empty"
[[ -r /etc/msmtprc ]] && OK "/etc/msmtprc present" || WARN "/etc/msmtprc missing"
[[ -s "$(cfg INBOX_FILE || echo /var/lib/ec20-gateway/inbox.jsonl)" ]] && OK "inbox has messages" || WARN "inbox empty"

printf '\n'
if [[ $FAILED -eq 0 ]]; then
  printf '\033[32mALL CRITICAL CHECKS PASSED\033[0m\n'; exit 0
fi
printf '\033[31mFAILURES PRESENT\033[0m — see docs/TROUBLESHOOTING.md\n'; exit 1
