#!/usr/bin/env bash
# =============================================================================
# sms_forward.sh — push incoming SMS / missed calls to DingTalk + email
# Called by Asterisk dialplan:
#   sms_forward.sh sms  "<CALLERID(num)>" "<SMS_BASE64>"
#   sms_forward.sh call "<CALLERID(num)>"
# Manual tests (used by the web panel too):
#   sms_forward.sh test_dingtalk
#   sms_forward.sh test_email
# =============================================================================
set -u

CONF="/etc/ec20-gateway.conf"

cfg() { grep -E "^$1=" "$CONF" 2>/dev/null | head -n1 | cut -d= -f2- | sed 's/[[:space:]]*$//'; }

LOG_FILE="$(cfg LOG_FILE)";      LOG_FILE="${LOG_FILE:-/var/log/ec20-gateway.log}"
INBOX_FILE="$(cfg INBOX_FILE)";  INBOX_FILE="${INBOX_FILE:-/var/lib/ec20-gateway/inbox.jsonl}"
ENABLE_DINGTALK="$(cfg ENABLE_DINGTALK)"
DINGTALK_WEBHOOK="$(cfg DINGTALK_WEBHOOK)"
DINGTALK_SECRET="$(cfg DINGTALK_SECRET)"
ENABLE_EMAIL="$(cfg ENABLE_EMAIL)"
EMAIL_TO="$(cfg EMAIL_TO)"
ENABLE_MISSED_CALL="$(cfg ENABLE_MISSED_CALL)"
ENABLE_MISSED_CALL="${ENABLE_MISSED_CALL:-yes}"

glog() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }

send_dingtalk() {
  local text="$1" ts sts sign body resp rc
  if [[ "$ENABLE_DINGTALK" == "no" ]]; then return 0; fi
  if [[ "$ENABLE_DINGTALK" == "auto" && -z "$DINGTALK_WEBHOOK" ]]; then return 0; fi
  if [[ -z "$DINGTALK_WEBHOOK" ]]; then glog "dingtalk: webhook empty, skip"; return 1; fi

  ts="$(date +%s%3N)"
  # DingTalk sign: hmac_sha256(key=secret, msg="timestamp\nsecret"), base64, urlencode
  sign="$(printf '%b' "${ts}\\n${DINGTALK_SECRET}" \
          | openssl dgst -sha256 -hmac "$DINGTALK_SECRET" -binary \
          | openssl base64)"
  sign="$(jq -rn --arg s "$sign" '$s|@uri')"
  body="$(jq -cn --arg t "$text" '{msgtype:"text",text:{content:$t}}')"

  resp="$(curl -sS --connect-timeout 5 --max-time 10 \
           -H 'Content-Type: application/json' -d "$body" \
           "${DINGTALK_WEBHOOK}&timestamp=${ts}&sign=${sign}" 2>&1)"
  rc=$?
  if [[ $rc -eq 0 && "$resp" == *'"errcode":0'* ]]; then
    glog "dingtalk: delivered"
    return 0
  fi
  glog "dingtalk: FAILED rc=$rc resp=$resp (errcode 310000 usually = sign/secret mismatch)"
  return 1
}

send_email() {
  local subject="$1" text="$2" hdr
  if [[ "$ENABLE_EMAIL" == "no" ]]; then return 0; fi
  if [[ "$ENABLE_EMAIL" == "auto" && -z "$EMAIL_TO" ]]; then return 0; fi
  if [[ -z "$EMAIL_TO" ]]; then glog "email: EMAIL_TO empty, skip"; return 1; fi
  if ! command -v msmtp >/dev/null 2>&1; then glog "email: msmtp missing"; return 1; fi

  hdr="From: ec20-gateway <ec20-gateway@gateway.local>"
  hdr="$hdr"$'\n'"To: ${EMAIL_TO}"
  hdr="$hdr"$'\n'"Subject: ${subject}"
  hdr="$hdr"$'\n'"Content-Type: text/plain; charset=UTF-8"
  hdr="$hdr"$'\n'"MIME-Version: 1.0"
  hdr="$hdr"$'\n''\n'
  if printf '%b\n%s\n' "$hdr" "$text" | msmtp -a default -t 2>>"$LOG_FILE"; then
    glog "email: delivered to ${EMAIL_TO}"
    return 0
  fi
  glog "email: msmtp failed (check /etc/msmtprc and /var/log/msmtp.log)"
  return 1
}

push_sms() {
  local from="$1" text="$2" ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  glog "sms: from=${from} text=${text}"

  # inbox for the web panel (JSONL, one message per line)
  mkdir -p "$(dirname "$INBOX_FILE")"
  jq -cn --arg ts "$ts" --arg from "$from" --arg text "$text" \
     '{ts:$ts,from:$from,text:$text}' >> "$INBOX_FILE" 2>>"$LOG_FILE" \
    || glog "inbox: append failed"

  local ok_d=0 ok_e=0
  send_dingtalk "📩 短信来自 ${from}
${ts}
${text}" || ok_d=1
  send_email "[ec20-gateway] SMS from ${from}" "来自 ${from} 的短信 (${ts}):
${text}" || ok_e=1
  [[ $ok_d -eq 0 || $ok_e -eq 0 ]] && return 0
  return 1
}

push_missed_call() {
  local from="$1" ts
  if [[ "$ENABLE_MISSED_CALL" != "yes" ]]; then return 0; fi
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  glog "call: missed call from=${from}"
  send_dingtalk "📵 未接来电来自 ${from}
${ts}
（分机 30 秒内未接听）" || return 1
  send_email "[ec20-gateway] Missed call from ${from}" "未接来电 ${from} @ ${ts}" || return 1
  return 0
}

case "${1:-}" in
  sms)
    [[ $# -ge 3 ]] || { echo "usage: $0 sms <from> <text_base64>" >&2; exit 2; }
    text="$(printf '%s' "${3}" | base64 -d 2>/dev/null)"
    push_sms "${2}" "$text"
    ;;
  call)
    [[ $# -ge 2 ]] || { echo "usage: $0 call <from>" >&2; exit 2; }
    push_missed_call "${2}"
    ;;
  test_dingtalk)
    send_dingtalk "✅ ec20-gateway 测试消息 $(date '+%F %T')" ; exit $? ;;
  test_email)
    send_email "[ec20-gateway] test mail" "ec20-gateway test @ $(date '+%F %T')" ; exit $? ;;
  *)
    echo "usage: $0 {sms <from> <b64> | call <from> | test_dingtalk | test_email}" >&2
    exit 2 ;;
esac
