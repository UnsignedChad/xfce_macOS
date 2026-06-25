#!/usr/bin/env bash
#
# setup-whitesur-macos.sh
# ------------------------------------------------------------------------------
# Turn a fresh Debian 13 (Trixie) XFCE desktop into a macOS Big Sur look using
# the WhiteSur theme set, Plank, and a global (app)menu.
#
# Ships alongside `xfce4-panel.xml` (your exact panel layout). Keep both files
# together; the script installs that XML verbatim.
#
# Re-runnable: safe to run more than once.
# Needs sudo only for the apt step.
# ------------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${HOME}/.cache/whitesur-build"
PANEL_XML_SRC="${SCRIPT_DIR}/xfce4-panel.xml"
PANEL_XML_DST="${HOME}/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml"
WALLPAPER_DIR="${HOME}/Pictures/Wallpapers"
PLANK_DOCK="/net/launchpad/plank/docks/dock1/"

say()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }

# ------------------------------------------------------------------------------
say "1/10 Installing packages (sudo required)"
# - plank ........................ the dock
# - xfce4-appmenu-plugin ......... global menu panel widget
# - appmenu-gtk3-module .......... lets GTK3 apps export their menus
# - xfce4-{battery,cpugraph,netload}-plugin .. extra panel plugins in the layout
# - sassc / git / curl ........... build + fetch deps
sudo apt-get update
sudo apt-get install -y \
  plank \
  xfce4-appmenu-plugin appmenu-gtk3-module \
  xfce4-battery-plugin xfce4-cpugraph-plugin xfce4-netload-plugin \
  sassc git curl

# ------------------------------------------------------------------------------
say "2/10 Cloning WhiteSur repositories"
mkdir -p "${BUILD_DIR}"
clone() { # url dir
  local url="$1" dir="${BUILD_DIR}/$2"
  rm -rf "${dir}"
  git clone --depth=1 "${url}" "${dir}"
}
clone https://github.com/vinceliuice/whitesur-gtk-theme.git  whitesur-gtk-theme
clone https://github.com/vinceliuice/WhiteSur-icon-theme.git WhiteSur-icon-theme
clone https://github.com/vinceliuice/WhiteSur-cursors.git    WhiteSur-cursors

# ------------------------------------------------------------------------------
say "3/10 Installing WhiteSur GTK theme"
# NOTE: the installer tries to build the GNOME Shell theme unconditionally and
# fails on non-GNOME systems because SHELL_VERSION is empty. Pinning it to 48
# (the project's own no-gnome default) makes the build succeed; the resulting
# gnome-shell.css is simply unused under XFCE.
( cd "${BUILD_DIR}/whitesur-gtk-theme" && SHELL_VERSION=48 ./install.sh )

# ------------------------------------------------------------------------------
say "4/10 Installing WhiteSur icons and cursors"
"${BUILD_DIR}/WhiteSur-icon-theme/install.sh"
( cd "${BUILD_DIR}/WhiteSur-cursors" && ./install.sh )

# ------------------------------------------------------------------------------
say "5/10 Installing Plank theme and wallpaper"
mkdir -p "${HOME}/.local/share/plank/themes/WhiteSur"
cp "${BUILD_DIR}/whitesur-gtk-theme/other/plank/theme-Dark/dock.theme" \
   "${HOME}/.local/share/plank/themes/WhiteSur/dock.theme"
mkdir -p "${WALLPAPER_DIR}"
# Populate the folder with 100 4K (>=3840x2160) landscape wallpapers.
# fetch_4k_landscapes.py ships next to this script; it pulls from dharmx/walls,
# keeps only true-4K images, and writes landscape-NNN.jpg into the folder.
if [ -f "${SCRIPT_DIR}/fetch_4k_landscapes.py" ]; then
  python3 "${SCRIPT_DIR}/fetch_4k_landscapes.py" 100 || warn "wallpaper fetch failed"
else
  warn "fetch_4k_landscapes.py not found next to this script — no wallpapers downloaded."
fi

# ------------------------------------------------------------------------------
say "6/10 Applying theme, icons, cursor and wallpaper (xfconf)"
xfconf-query -c xsettings -p /Net/ThemeName       -s "WhiteSur-Dark"
xfconf-query -c xfwm4     -p /general/theme        -s "WhiteSur-Dark"
xfconf-query -c xsettings -p /Net/IconThemeName    -s "WhiteSur-dark"
xfconf-query -c xsettings -p /Gtk/CursorThemeName  -s "WhiteSur-cursors"
# Slightly transparent window titlebars (needs the compositor enabled).
xfconf-query -c xfwm4 -p /general/use_compositing -s true
xfconf-query -c xfwm4 -p /general/frame_opacity   -s 90
# Wallpapers were downloaded to ${WALLPAPER_DIR} in step 5.
# Configure rotation/selection yourself in Settings → Desktop (Background tab).

# ------------------------------------------------------------------------------
say "7/10 Configuring Plank dock"
# Start once so its gsettings schema/path is live.
pkill -x plank 2>/dev/null || true; sleep 1
nohup plank >/dev/null 2>&1 & sleep 2
gset() { gsettings set "net.launchpad.plank.dock.settings:${PLANK_DOCK}" "$1" "$2" || true; }
gset theme        "'WhiteSur'"
gset position     "'bottom'"
gset icon-size    36
gset hide-mode    "'intelligent'"
gset zoom-enabled true
gset zoom-percent 130

# Dock launchers (Files, Brave[Safari icon], Terminal, Mousepad, App Finder)
# Brave points at the custom launcher created in step 10 (Safari icon + dark mode).
LD="${HOME}/.config/plank/dock1/launchers"; mkdir -p "${LD}"; rm -f "${LD}"/*.dockitem
mkitem() { printf '[PlankDockItemPreferences]\nLauncher=file://%s\n' "$1" > "${LD}/$2.dockitem"; }
mkitem /usr/share/applications/thunar.desktop            00-thunar
mkitem "${HOME}/.local/share/applications/brave-browser.desktop" 01-brave
mkitem /usr/share/applications/xfce4-terminal.desktop    02-terminal
mkitem /usr/share/applications/org.xfce.mousepad.desktop 03-mousepad
mkitem /usr/share/applications/xfce4-appfinder.desktop   04-appfinder
gset dock-items "['00-thunar.dockitem','01-brave.dockitem','02-terminal.dockitem','03-mousepad.dockitem','04-appfinder.dockitem']"

# Autostart Plank on login
mkdir -p "${HOME}/.config/autostart"
cat > "${HOME}/.config/autostart/plank.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Plank
Exec=plank
X-GNOME-Autostart-enabled=true
Hidden=false
EOF

# ------------------------------------------------------------------------------
say "8/10 Enabling the global menu (GTK module export)"
# GTK3 apps only export their menus to the appmenu plugin when launched with
# this module loaded. Takes effect for every app at the next login.
MODLINE='export GTK_MODULES="${GTK_MODULES:+$GTK_MODULES:}appmenu-gtk-module"'
for f in "${HOME}/.xsessionrc" "${HOME}/.profile"; do
  touch "$f"
  grep -q 'appmenu-gtk-module' "$f" || \
    printf '\n# Global menu (xfce4-appmenu-plugin) — export GTK3 app menus\n%s\n' "${MODLINE}" >> "$f"
done

# ------------------------------------------------------------------------------
say "9/10 Installing the XFCE panel layout"
# A running xfce4-panel rewrites its own config, so to install a layout reliably
# we must: stop the panel, stop xfconfd (so it reloads our file from disk on the
# next access), drop the XML in place, then start the panel fresh.
if [ ! -f "${PANEL_XML_SRC}" ]; then
  warn "xfce4-panel.xml not found next to this script — skipping panel layout."
else
  xfce4-panel -q 2>/dev/null || true
  for _ in 1 2 3 4 5 6; do pkill -x xfce4-panel 2>/dev/null || true; sleep 0.4; \
    pgrep -x xfce4-panel >/dev/null || break; done
  pkill -x xfconfd 2>/dev/null || true; sleep 1
  mkdir -p "$(dirname "${PANEL_XML_DST}")"
  cp "${PANEL_XML_SRC}" "${PANEL_XML_DST}"
  nohup xfce4-panel >/dev/null 2>&1 & sleep 2
fi

# ------------------------------------------------------------------------------
say "10/10 Installing and debloating Brave"
# Add Brave's apt repo (idempotent) and install.
if ! command -v brave-browser >/dev/null 2>&1; then
  sudo curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg \
    https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
  sudo curl -fsSLo /etc/apt/sources.list.d/brave-browser-release.sources \
    https://brave-browser-apt-release.s3.brave.com/brave-browser.sources
  sudo apt-get update
  sudo apt-get install -y brave-browser
fi

# System-wide managed policies: disable telemetry (P3A, stats ping, metrics,
# web-discovery), AI (Leo), Rewards, Wallet, VPN, News, Talk, Tor, background
# mode and assorted nags. Brave applies these on every launch and they survive
# updates/profile resets — verify at brave://policy. Flip any value to re-enable
# (e.g. "TorDisabled": false).
sudo mkdir -p /etc/brave/policies/managed
sudo tee /etc/brave/policies/managed/debloat.json >/dev/null <<'JSON'
{
  "BraveAIChatEnabled": false,
  "BraveRewardsDisabled": true,
  "BraveWalletDisabled": true,
  "BraveVPNDisabled": true,
  "BraveNewsDisabled": true,
  "BraveTalkDisabled": true,
  "TorDisabled": true,
  "BraveP3AEnabled": false,
  "BraveStatsPingEnabled": false,
  "BraveWebDiscoveryEnabled": false,
  "MetricsReportingEnabled": false,
  "UrlKeyedAnonymizedDataCollectionEnabled": false,
  "SafeBrowsingExtendedReportingEnabled": false,
  "PasswordLeakDetectionEnabled": false,
  "SearchSuggestEnabled": false,
  "SpellCheckServiceEnabled": false,
  "ShoppingListEnabled": false,
  "BackgroundModeEnabled": false,
  "DefaultBrowserSettingEnabled": false
}
JSON

# Custom Brave launcher: Safari icon + forced dark UI. Overrides the system
# launcher (user dir wins, survives apt updates) so the app menu AND the Plank
# dock both show the Safari icon and launch Brave in dark mode.
if [ -f /usr/share/applications/brave-browser.desktop ]; then
  mkdir -p "${HOME}/.local/share/applications"
  sed -E -e 's#^Icon=.*#Icon=safari#' \
         -e 's#(Exec=/usr/bin/brave-browser-stable)#\1 --force-dark-mode#' \
    /usr/share/applications/brave-browser.desktop \
    > "${HOME}/.local/share/applications/brave-browser.desktop"
  update-desktop-database "${HOME}/.local/share/applications" 2>/dev/null || true
  # Reload Plank so the dock picks up the Safari icon.
  pkill -x plank 2>/dev/null || true; sleep 1; nohup plank >/dev/null 2>&1 &
fi

# Make Brave the default browser.
xdg-settings set default-web-browser brave-browser.desktop 2>/dev/null || true
xdg-mime default brave-browser.desktop x-scheme-handler/http x-scheme-handler/https text/html 2>/dev/null || true

# ------------------------------------------------------------------------------
say "Hardening (firewall + disabling unneeded services)"
# Optional: runs ./harden.sh if it sits next to this script.
if [ -f "${SCRIPT_DIR}/harden.sh" ]; then
  bash "${SCRIPT_DIR}/harden.sh"
else
  warn "harden.sh not found next to this script — skipping hardening."
fi

# ------------------------------------------------------------------------------
cat <<'DONE'

============================================================
 WhiteSur macOS setup complete.

 IMPORTANT: log out and back in so the global menu activates
 for all apps (the GTK module loads at login).

 Tweak later:  right-click the dock → Preferences
               right-click the panel → Panel Preferences
============================================================
DONE
