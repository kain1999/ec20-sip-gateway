#!/usr/bin/env bash
# =============================================================================
# sms_send_cli.sh — send SMS via chan_quectel CLI from the dialplan/web panel
#   sms_send_cli.sh "<dest>" "<text_base64>"
# The base64 hop exists so dialplan ${MESSAGE(body)} survives commas/quotes.
# =============================================================================
set -u

CONF="/etc/ec20-gateway.conf"
cfg() { grep -E "^$1=" "$CONF" 2>/dev/null | head -n1 | cut -d= -f2- | sed 's/[[:space:]]*$//'; }

DEST="${1:-}"
B64="${2:-}"
DEV="$(cfg DEV_NAME)"; DEV="${DEV:-ec20}"
AST="${AST:-/usr/sbin/asterisk}"

[[ "$DEST" =~ ^\+?[0-9]{3,20}$ ]] || { echo "invalid destination: $DEST" >&2; exit 2; }
[[ -n "$B64" ]] || { echo "empty payload" >&2; exit 2; }

TEXT="$(printf '%s' "$B64" | base64 -d 2>/dev/null | tr -d '\r\n')"
# defence in depth: strip chars that could be interpreted by shells downstream
TEXT="${TEXT//\$/S}"
TEXT="${TEXT//\`/Q}"
TEXT="${TEXT:0:200}"
[[ -n "$TEXT" ]] || { echo "sms body empty after sanitise" >&2; exit 2; }

if [[ ! -x "$AST" ]]; then
  AST="$(command -v asterisk || true)"
  [[ -n "$AST" ]] || { echo "asterisk binary not found" >&2; exit 3; }
fi

"$AST" -rx "quectel sms ${DEV} ${DEST} ${TEXT}" >/dev/null 2>&1
rc=$?
if [[ $rc -eq 0 ]]; then
  echo "sms queued: ${DEV} -> ${DEST}"
else
  echo "asterisk CLI rc=$rc (check device state: asterisk -rx 'quectel show devices')" >&2
fi
exit $rc
