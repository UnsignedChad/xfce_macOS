#!/usr/bin/env bash
#
# harden.sh
# ------------------------------------------------------------------------------
# Light desktop hardening for Debian 13 XFCE:
#   - install + enable ufw (deny incoming, allow outgoing)
#   - disable print/discovery/modem/bluetooth daemons that aren't needed
#
# Run standalone (`./harden.sh`) or it is invoked by setup-whitesur-macos.sh.
# Uses sudo for the privileged steps; re-runnable.
#
# To KEEP a service, comment out its line in the DISABLE_SERVICES list below.
# ------------------------------------------------------------------------------
set -euo pipefail

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
say "Hardening summary"
sudo ufw status verbose | head -3
echo "Listening sockets remaining:"
sudo ss -tulpnH | awk '{print "  " $1, $5}' | sort -u
cat <<'NOTE'

Done. Notes:
  - Re-enable any service with:  sudo systemctl enable --now <name>
  - For a Bluetooth GUI later:    sudo apt install blueman
  - A remaining local socket from mullvad-daemon (if present) is your VPN — keep it.
NOTE
