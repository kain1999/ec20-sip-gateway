#!/usr/bin/env bash
# =============================================================================
# ec20_modem_prep.sh — one-shot AT preparation before asterisk starts
#   * AT+QPCMV=0        : disarm any stale UAC session from a previous run
#   * AT+QAUDMOD=<n>    : audio DSP profile (NVM-persistent; 3 = raw PCM, fixes
#                         garbled/one-way audio on many EC20/EC25 units)
# Writes only; replies are drained by a background reader. Never open the AT
# port while asterisk is running — chan_quectel owns it then.
# =============================================================================
set -u

CONF="/etc/ec20-gateway.conf"
cfg() { grep -E "^$1=" "$CONF" 2>/dev/null | head -n1 | cut -d= -f2- | sed 's/[[:space:]]*$//'; }

MODE="$(cfg QAUDMOD_MODE)"; MODE="${MODE:-3}"
case "$MODE" in 0|1|2|3) ;; *) MODE=3 ;; esac

PORT="/dev/ec20-at"
[[ -e "$PORT" ]] || PORT="/dev/ttyUSB2"
if [[ ! -e "$PORT" ]]; then
  echo "ec20_modem_prep: no AT port found, skip" >&2
  exit 0
fi

LOG="${LOG:-$(cfg LOG_FILE)}"
LOG="${LOG:-/var/log/ec20-gateway.log}"
REPLY="/tmp/ec20-at-prep.$$"

# drain URCs/replies in background while we write
timeout 4 cat "$PORT" > "$REPLY" 2>/dev/null &
drain_pid=$!
sleep 0.3

at() {
  printf '%s\r' "$1" > "$PORT"
  sleep 0.6
}

at "AT"
at "AT+QPCMV=0"
at "AT+QAUDMOD=${MODE}"
at "AT+QAUDMOD?"

sleep 0.5
kill "$drain_pid" 2>/dev/null || true
wait "$drain_pid" 2>/dev/null || true

got_ok=0
[[ -s "$REPLY" ]] && grep -qa 'OK' "$REPLY" && got_ok=1

{
  echo "$(date '+%Y-%m-%d %H:%M:%S') ec20_modem_prep: port=${PORT} QAUDMOD=${MODE} got_ok=${got_ok}"
  echo "  reply dump:"
  sed 's/^/    /' "$REPLY" 2>/dev/null
} >> "$LOG"
rm -f "$REPLY"
exit 0
