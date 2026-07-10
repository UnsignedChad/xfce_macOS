#!/usr/bin/env bash
#
# harden.sh
# ------------------------------------------------------------------------------
# Debian 13 XFCE desktop/laptop hardening -- standalone, no SIEM required.
#   - ufw (deny incoming, allow outgoing) + network sysctl hardening
#   - disable print/discovery/modem/bluetooth daemons that aren't needed
#   - automatic security updates + laptop power management (TLP)
#   - FILE INTEGRITY, cryptographic:  debsums (packaged files) + AIDE (full hash DB)
#   - syscall auditing (auditd) on the files attackers touch
#   - periodic rootkit/audit scans (rkhunter, chkrootkit, lynis) on systemd timers
#   - a daily consolidated digest -> journald + desktop notification on any finding
#
# Run standalone (`./harden.sh`) or via setup-whitesur-macos.sh. Re-runnable.
# The first run builds the integrity baselines, so run it on a KNOWN-GOOD system.
# ------------------------------------------------------------------------------
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }

# ------------------------------------------------------------------------------
say "Installing and enabling ufw"
sudo apt-get install -y ufw
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw --force enable
sudo ufw status verbose | head -5

# ------------------------------------------------------------------------------
say "Network sysctl hardening (safe on hostile Wi-Fi, and behind Docker/VPN)"
# ignore ICMP redirects + source routing, anti-spoof (loose rp_filter so VPN/Docker
# asymmetric routing still works), SYN cookies, drop broadcast pings, log spoofs.
# ip_forward is intentionally left untouched (Docker/WireGuard need it).
sudo tee /etc/sysctl.d/99-harden-net.conf >/dev/null <<'EOF'
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.log_martians = 1
EOF
sudo sysctl --system >/dev/null 2>&1 || true
echo "  applied /etc/sysctl.d/99-harden-net.conf"

# ------------------------------------------------------------------------------
say "Disabling unneeded services"
# Services to stop + disable at boot. Edit to taste:
#   cups*           printing (closes :631)
#   avahi-daemon    mDNS/zeroconf .local discovery (closes :5353)
#   bluetooth       only if you use no Bluetooth peripherals
#   ModemManager    cellular/dial-up modems — useless on ethernet/Wi-Fi
DISABLE_SERVICES=(
  cups.service cups.socket cups.path
  cups-browsed.service
  avahi-daemon.service avahi-daemon.socket
  bluetooth.service
  ModemManager.service
)
for unit in "${DISABLE_SERVICES[@]}"; do
  if systemctl list-unit-files "${unit}" >/dev/null 2>&1 \
     && systemctl cat "${unit}" >/dev/null 2>&1; then
    sudo systemctl disable --now "${unit}" 2>/dev/null || true
    echo "  disabled ${unit}"
  fi
done

# Mask cups-browsed specifically — it's the component behind the 2024 CUPS RCE
# chain; masking guarantees nothing can socket-activate it back on.
sudo systemctl mask cups-browsed.service 2>/dev/null || true

# Bluetooth is disabled above, so suppress the blueman tray applet's autostart
# (a user-level override of the system /etc/xdg/autostart entry; ~60 MB saved).
# Delete ~/.config/autostart/blueman.desktop if you re-enable Bluetooth.
if [ -f /etc/xdg/autostart/blueman.desktop ]; then
  mkdir -p "${HOME}/.config/autostart"
  cat > "${HOME}/.config/autostart/blueman.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=blueman-applet
Exec=blueman-applet
X-GNOME-Autostart-enabled=false
Hidden=true
EOF
  pkill -x blueman-applet 2>/dev/null || true
fi

# ------------------------------------------------------------------------------
say "Installing security tooling (integrity, audit, rootkit scanners)"
sudo apt-get install -y \
  debsums aide aide-common auditd audispd-plugins \
  rkhunter chkrootkit lynis needrestart sysstat
[ -f /etc/default/sysstat ] && sudo sed -i 's/^ENABLED=.*/ENABLED="true"/' /etc/default/sysstat
sudo systemctl enable --now sysstat 2>/dev/null || true

# ------------------------------------------------------------------------------
say "Syscall auditing (auditd) — watch the files attackers touch"
{
  echo '-w /etc/passwd -p wa -k identity'
  echo '-w /etc/shadow -p wa -k identity'
  echo '-w /etc/sudoers -p wa -k sudoers'
  echo '-w /etc/sudoers.d/ -p wa -k sudoers'
  echo '-w /etc/ssh/sshd_config -p wa -k sshdconfig'
  echo '-w /etc/ld.so.preload -p wa -k preload'
  echo '-w /etc/crontab -p wa -k cron'
  echo '-w /etc/cron.d/ -p wa -k cron'
  echo '-w /etc/systemd/system/ -p wa -k systemd'
  echo '-w /etc/rc.local -p wa -k rc'
  echo '-w /usr/bin/sudo -p x -k privesc'
  echo '-w /root/.ssh/ -p wa -k sshkeys'
  for d in /home/*/.ssh; do [ -d "$d" ] && echo "-w $d -p wa -k sshkeys"; done
} | sudo tee /etc/audit/rules.d/zz-harden.rules >/dev/null
sudo augenrules --load 2>/dev/null || true
sudo systemctl enable --now auditd 2>/dev/null || true
echo "  auditd rules active: $(sudo auditctl -l 2>/dev/null | wc -l)   (query later: sudo ausearch -k sshkeys)"

# ------------------------------------------------------------------------------
say "File-integrity baselines (cryptographic) — run on a KNOWN-GOOD system"
# 1) debsums — verify every packaged file against its distro checksum.
if sudo debsums -s 2>/dev/null | grep -vE '^/etc/' | grep -q .; then
  warn "debsums: MODIFIED packaged files found — investigate:"; sudo debsums -s 2>/dev/null | grep -vE '^/etc/' | sed 's/^/    /'
else
  echo "  debsums: clean (all packaged binaries/libs match their checksums)"
fi
# 2) AIDE — full cryptographic hash DB of the system (first build takes a few minutes).
if [ ! -f /var/lib/aide/aide.db.gz ]; then
  echo "  AIDE: building the initial cryptographic baseline (a few minutes)…"
  sudo aideinit -y -f >/dev/null 2>&1 || sudo aideinit >/dev/null 2>&1 || true
  [ -f /var/lib/aide/aide.db.new.gz ] && sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
  echo "  AIDE baseline -> /var/lib/aide/aide.db.gz"
else
  echo "  AIDE baseline already present (re-baseline after INTENDED changes: sudo aideinit && sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz)"
fi
# 3) rkhunter — update signatures + baseline file properties.
sudo rkhunter --update >/dev/null 2>&1 || true
sudo rkhunter --propupd >/dev/null 2>&1 || true
echo "  rkhunter file-property baseline set"

# ------------------------------------------------------------------------------
say "Periodic scans (systemd timers) + a daily digest"
sudo mkdir -p /var/log/chkrootkit
# Digest: roll the latest results into one journald line; desktop-notify on a real finding.
sudo tee /usr/local/bin/harden-scan.sh >/dev/null <<'SCAN'
#!/bin/bash
# Consolidate latest integrity/rootkit results -> journald (+ desktop notify on a finding). No SIEM needed.
finding=0; parts=()
mod=$(debsums -s 2>/dev/null | grep -vcE '^/etc/|^debsums:'); mod=${mod:-0}
parts+=("debsums=${mod}mod"); [ "$mod" -gt 0 ] && finding=1
if [ -f /var/lib/aide/aide.db.gz ]; then
  ac=$(aide --check 2>/dev/null | grep -icE '^(changed|added|removed)'); ac=${ac:-0}
  parts+=("aide=${ac}chg"); [ "$ac" -gt 0 ] && finding=1
fi
if [ -f /var/log/rkhunter.log ]; then rk=$(grep -icE '\[ Warning \]' /var/log/rkhunter.log 2>/dev/null); parts+=("rkhunter=${rk:-0}w"); fi
if [ -f /var/log/chkrootkit/log.today ]; then
  ci=$(grep -E 'INFECTED' /var/log/chkrootkit/log.today 2>/dev/null | grep -vc 'not infected'); ci=${ci:-0}
  parts+=("chkrootkit=${ci}inf"); [ "$ci" -gt 0 ] && finding=1
fi
if [ -f /var/log/lynis-report.dat ]; then idx=$(grep -E '^hardening_index=' /var/log/lynis-report.dat 2>/dev/null|tail -1|cut -d= -f2); parts+=("lynis=idx${idx:-?}"); fi
tag="SCAN OK"; [ "$finding" -eq 1 ] && tag="SCAN FINDING"
logger -t harden-scan "$tag ${parts[*]}"
if [ "$finding" -eq 1 ]; then
  u=$(who 2>/dev/null | awk '/\(:0\)|:0 /{print $1; exit}'); [ -z "$u" ] && u=$(loginctl list-sessions --no-legend 2>/dev/null | awk 'NR==1{print $3}')
  if [ -n "$u" ]; then uid=$(id -u "$u" 2>/dev/null); sudo -u "$u" DISPLAY=:0 DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" notify-send -u critical "Security scan: FINDING" "${parts[*]}  —  journalctl -t harden-scan" 2>/dev/null || true; fi
fi
SCAN
sudo chmod 755 /usr/local/bin/harden-scan.sh

mk_timer() {  # $1 name  $2 OnCalendar  $3 ExecStart
  printf '[Unit]\nDescription=%s\n[Service]\nType=oneshot\nNice=15\nIOSchedulingClass=idle\nExecStart=%s\n' "$1" "$3" | sudo tee /etc/systemd/system/"$1".service >/dev/null
  printf '[Unit]\nDescription=%s timer\n[Timer]\nOnCalendar=%s\nPersistent=true\nRandomizedDelaySec=900\n[Install]\nWantedBy=timers.target\n' "$1" "$2" | sudo tee /etc/systemd/system/"$1".timer >/dev/null
}
mk_timer harden-rkhunter   "Sat *-*-* 00:20:00" "/usr/bin/rkhunter --check --sk --nocolors --report-warnings-only"
mk_timer harden-chkrootkit "Sat *-*-* 00:10:00" "/bin/sh -c '/usr/sbin/chkrootkit > /var/log/chkrootkit/log.today 2>&1'"
mk_timer harden-lynis      "Sat *-*-* 00:30:00" "/usr/bin/lynis audit system --cronjob --quick"
mk_timer harden-aide       "Sun *-*-* 01:00:00" "/usr/bin/aide --check"
mk_timer harden-scan       "*-*-* 08:00:00"     "/usr/local/bin/harden-scan.sh"
sudo systemctl daemon-reload
for t in harden-rkhunter harden-chkrootkit harden-lynis harden-aide harden-scan; do
  sudo systemctl enable --now "$t".timer 2>/dev/null || true
done
echo "  weekly rkhunter/chkrootkit/lynis + weekly AIDE check + daily digest scheduled"
echo "  see results with:  journalctl -t harden-scan   (FINDING also pops a desktop alert)"

# ------------------------------------------------------------------------------
say "AppArmor"
if command -v aa-status >/dev/null 2>&1; then
  sudo aa-status 2>/dev/null | grep -E 'profiles are loaded|profiles are in enforce' | sed 's/^/  /'
else
  warn "AppArmor tools missing (sudo apt install apparmor apparmor-utils)"
fi

# ------------------------------------------------------------------------------
say "Auto security updates + laptop power management"
# Apply security patches automatically.
sudo apt-get install -y unattended-upgrades
sudo tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
sudo systemctl enable unattended-upgrades 2>/dev/null || true

# TLP for battery life — only on laptops (skip on desktops / no battery).
if ls /sys/class/power_supply/ 2>/dev/null | grep -qi bat; then
  sudo apt-get install -y tlp
  sudo systemctl enable --now tlp 2>/dev/null || true
  echo "  TLP installed and enabled (laptop detected)"
else
  echo "  no battery detected — skipping TLP"
fi

# ------------------------------------------------------------------------------
say "Hardening summary"
sudo ufw status verbose | head -3
echo "Integrity + scanning in place:"
echo "  debsums (packaged files) · AIDE (full crypto DB) · rkhunter/chkrootkit/lynis timers · auditd"
echo "Listening sockets remaining:"
sudo ss -tulpnH | awk '{print "  " $1, $5}' | sort -u
cat <<'NOTE'

Done. Notes:
  - Scan results:               journalctl -t harden-scan     (a FINDING also raises a desktop alert)
  - After intended system changes, re-baseline integrity:
        sudo aideinit && sudo mv /var/lib/aide/aide.db.new.gz /var/lib/aide/aide.db.gz
        sudo rkhunter --propupd
  - Re-enable any service with:  sudo systemctl enable --now <name>
  - For a Bluetooth GUI later:    sudo apt install blueman
  - A remaining local socket from mullvad-daemon (if present) is your VPN — keep it.
NOTE
