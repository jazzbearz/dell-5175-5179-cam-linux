#!/bin/sh
# Rebuild Ubuntu's libcamera with the IPU3 viewfinder/video size-range patch,
# so PipeWire apps can use resolutions above 1280x720.
# Requires 'deb-src' entries in /etc/apt/sources.list.d/ubuntu.sources.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PATCH="$HERE/libcamera-0.7.0-ipu3-advertise-full-vf-range.patch"
WORK=${WORK:-"$HOME/libcamera-ipu3-build"}

ver=$(dpkg-query -W -f '${Version}' libcamera0.7 2>/dev/null || true)
case "$ver" in
	*+ipu3vf*) echo "Patched libcamera ($ver) already installed."; exit 0 ;;
	"") echo "libcamera0.7 is not installed." >&2; exit 1 ;;
esac
upstream=${ver%%-*}
[ "$upstream" = "0.7.0" ] || echo "Warning: patch made for 0.7.0, installed is $ver." >&2

sudo apt-get build-dep -y libcamera
sudo apt-get install -y dpkg-dev fakeroot

mkdir -p "$WORK" && cd "$WORK"
apt-get source "libcamera=$ver"
cd libcamera-"$upstream"
patch -p1 < "$PATCH"

newver="$ver+ipu3vf1"
{
	printf 'libcamera (%s) %s; urgency=medium\n\n' "$newver" "$(dpkg-parsechangelog -S Distribution)"
	printf '  * Local build: ipu3: advertise full output size range for Viewfinder\n'
	printf '    and VideoRecording roles (default stays 1280x720).\n\n'
	printf ' -- local build <root@localhost>  %s\n\n' "$(date -R)"
	cat debian/changelog
} > debian/changelog.new && mv debian/changelog.new debian/changelog

DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -b -us -uc

cd "$WORK"
pkgs=""
for p in libcamera0.7 libcamera-ipa libcamera-tools libcamera-v4l2 gstreamer1.0-libcamera; do
	dpkg-query -W "$p" >/dev/null 2>&1 && pkgs="$pkgs ./${p}_${newver}_amd64.deb"
done
# shellcheck disable=SC2086
sudo apt-get install -y $pkgs
systemctl --user restart wireplumber || true
echo "Installed libcamera $newver."
