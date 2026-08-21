#!/usr/bin/env bash
#
# Installs a built Linux bundle so the desktop environment can find it.
#
# Flutter's own `install` step only assembles a relocatable bundle under
# build/; it does not put anything where a desktop menu looks.  This does that
# last part: the bundle goes somewhere stable, and the .desktop file and icons
# go into the XDG directories that GNOME, KDE and the rest read.
#
#   ./linux/packaging/install.sh              # for this user only
#   sudo ./linux/packaging/install.sh --system
#
set -euo pipefail

APP_ID="edu.utah.quake.seedlinkviewer"
BINARY="seedlink_viewer"
BUNDLE="build/linux/x64/release/bundle"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ "${1:-}" == "--system" ]]; then
    [[ $EUID -eq 0 ]] || { echo "--system needs root" >&2; exit 1; }
    PREFIX=/opt/seedlink-viewer
    DATA=/usr/share
else
    PREFIX="$HOME/.local/opt/seedlink-viewer"
    DATA="$HOME/.local/share"
fi

if [[ ! -d "$BUNDLE" ]]; then
    echo "No bundle at $BUNDLE - run: flutter build linux --release" >&2
    exit 1
fi

echo "Installing the bundle into $PREFIX"
rm -rf "$PREFIX"
mkdir -p "$PREFIX"
cp -a "$BUNDLE"/. "$PREFIX/"

echo "Installing icons into $DATA/icons"
for icon in "$HERE"/icons/hicolor/*/apps/"$APP_ID".png; do
    size="$(basename "$(dirname "$(dirname "$icon")")")"
    install -Dm644 "$icon" "$DATA/icons/hicolor/$size/apps/$APP_ID.png"
done

echo "Installing the desktop entry into $DATA/applications"
install -Dm644 "$HERE/$APP_ID.desktop" "$DATA/applications/$APP_ID.desktop"
# The Exec line in the checked-in file is only a default; point it at the copy
# that was actually installed.
sed -i "s|^Exec=.*|Exec=$PREFIX/$BINARY|" "$DATA/applications/$APP_ID.desktop"

# Without these the entry can take a re-login to show up.
command -v update-desktop-database >/dev/null &&
    update-desktop-database "$DATA/applications" || true
command -v gtk-update-icon-cache >/dev/null &&
    gtk-update-icon-cache -f -t "$DATA/icons/hicolor" || true

echo "Done.  SeedLink Viewer should now appear in the application menu."
