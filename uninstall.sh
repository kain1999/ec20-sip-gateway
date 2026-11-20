#!/usr/bin/env bash
# =============================================================================
# ec20-sip-gateway uninstaller — stops services, restores backups, removes
# deployed files. Asterisk/Kamailio packages stay installed (remove with apt).
# =============================================================================
set -euo pipefail

log()  { echo -e "\033[1;32m[uninstall]\033[0m $*"; }
warn() { echo -e "\033[1;33m[warn]\033[0m $*" >&2; }

[[ $EUID -ne 0 ]] && { echo "run as root: sudo ./uninstall.sh"; exit 1; }

log "stopping services"
for s in ec20-web ec20-modem-prep kamailio asterisk; do
  systemctl stop "$s" 2>/dev/null || true
  systemctl disable "$s" 2>/dev/null || true
done

log "removing units / drop-ins / rules"
rm -f /etc/systemd/system/ec20-web.service \
      /etc/systemd/system/ec20-modem-prep.service \
      /etc/systemd/system/kamailio.service.d/oom.conf \
      /etc/systemd/system/asterisk.service.d/oom.conf \
      /etc/udev/rules.d/99-ec20.rules \
      /etc/rsyslog.d/ec20-gateway.conf \
      /etc/logrotate.d/ec20-gateway
rmdir /etc/systemd/system/kamailio.service.d 2>/dev/null || true
rmdir /etc/systemd/system/asterisk.service.d 2>/dev/null || true
systemctl daemon-reload
systemctl restart rsyslog 2>/dev/null || true

log "restoring backups (newest backup of each config tree wins)"
restore() {
  local dir="$1"
  local latest
  latest="$(ls -1dt "${dir}".backup.* 2>/dev/null | head -n1 || true)"
  if [[ -n "$latest" ]]; then
    local backup_root
    backup_root="$(dirname "$latest")/$(basename "${dir%%.*}").backup.tmp.$$"
    rm -rf "$dir"
    cp -a "$latest" "$dir"
    rm -rf "$backup_root"
    log "restored $dir from $latest"
  else
    warn "no backup found for $dir (left as is)"
  fi
}
restore /etc/asterisk
restore /etc/kamailio

log "removing deployed files"
rm -f /usr/local/sbin/sms_forward.sh /usr/local/sbin/sms_send_cli.sh \
      /usr/local/sbin/ec20_check.sh /usr/local/sbin/ec20_modem_prep.sh
rm -rf /opt/ec20-gateway-web
rm -f /etc/ec20-gateway.conf
rm -rf /var/lib/ec20-gateway

log "optionally remove chan_quectel module"
rm -f /usr/lib/asterisk/modules/chan_quectel.so

log "uninstall done."
log "note: asterisk/kamailio packages and /swapfile were kept; remove manually if desired:"
echo "  apt-get remove -y asterisk kamailio && sed -i '/\\/swapfile/d' /etc/fstab && swapoff /swapfile && rm -f /swapfile"
