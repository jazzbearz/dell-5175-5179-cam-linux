#!/bin/sh
# Rebuild Ubuntu's libcamera with the IPU3 patches from this repository:
#  - advertise the full viewfinder/video size range (>720p in PipeWire apps)
#  - Ccm and Lsc IPA algorithms (tuning-driven colour/lens-shading correction)
# Requires 'deb-src' entries in /etc/apt/sources.list.d/ubuntu.sources.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
PATCHES="$HERE/libcamera-0.7.0-ipu3-advertise-full-vf-range.patch $HERE/libcamera-0.7.0-ipu3-ccm-lsc.patch"
WORK=${WORK:-"$HOME/libcamera-ipu3-build"}
SUFFIX=ipu3vf2

ver=$(dpkg-query -W -f '${Version}' libcamera0.7 2>/dev/null || true)
case "$ver" in
	*+$SUFFIX) echo "Patched libcamera ($ver) already installed."; exit 0 ;;
	*+ipu3vf*) ver=${ver%%+ipu3vf*} ;;
	"") echo "libcamera0.7 is not installed." >&2; exit 1 ;;
esac
upstream=${ver%%-*}
[ "$upstream" = "0.7.0" ] || echo "Warning: patch made for 0.7.0, installed is $ver." >&2

sudo apt-get build-dep -y libcamera
sudo apt-get install -y dpkg-dev fakeroot

mkdir -p "$WORK" && cd "$WORK"
apt-get source "libcamera=$ver"
cd libcamera-"$upstream"
for p in $PATCHES; do patch -p1 < "$p"; done

newver="$ver+$SUFFIX"
{
	printf 'libcamera (%s) %s; urgency=medium\n\n' "$newver" "$(dpkg-parsechangelog -S Distribution)"
	printf '  * Local build: ipu3: full viewfinder/video size range; Ccm and Lsc\n'
	printf '    algorithms (dell-5175-5179-cam-linux).\n\n'
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
sudo apt-get install -y --allow-downgrades $pkgs
# Keep apt from replacing it with a stock build that lacks Ccm/Lsc.
# shellcheck disable=SC2086
sudo apt-mark hold $(for p in $pkgs; do basename "$p" | cut -d_ -f1; done)
systemctl --user restart wireplumber || true
echo "Installed libcamera $newver."
