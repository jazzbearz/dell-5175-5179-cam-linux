#!/bin/sh
# Install the Dell Latitude 5175/5179 camera fix (DKMS) on Ubuntu/Debian.
# Run as a normal user; it calls sudo where needed.
set -eu

PKG=latitude5179-camera
VER=1.4
HERE=$(cd "$(dirname "$0")" && pwd)

product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
case "$product" in
	"Latitude 5179") ;;
	"Latitude 5175")
		echo "Warning: Latitude 5175 is untested; the DMI matches only cover 5179." >&2
		echo "See README.md ('Latitude 5175') before continuing." >&2
		;;
	*)
		echo "This machine is '$product', not a Latitude 5175/5179. Aborting." >&2
		exit 1
		;;
esac

echo "== Installing build tools and camera userspace =="
sudo apt-get install -y dkms make "linux-headers-$(uname -r)" \
	libcamera-ipa libspa-0.2-libcamera gstreamer1.0-libcamera libcamera-tools

echo "== Removing older versions of $PKG =="
for v in $(dkms status "$PKG" 2>/dev/null | sed -n "s|^$PKG/\([^,]*\),.*|\1|p" | sort -u); do
	[ "$v" = "$VER" ] && continue
	sudo dkms remove "$PKG/$v" --all || true
done

echo "== Building and installing $PKG/$VER =="
sudo rm -rf "/usr/src/$PKG-$VER"
sudo cp -r "$HERE/dkms/$PKG-$VER" /usr/src/
sudo dkms install "$PKG/$VER"

echo "== Privacy LED option and initramfs =="
sudo install -m 0644 "$HERE/modprobe.d/latitude5179-camera.conf" /etc/modprobe.d/
sudo update-initramfs -u

echo "== Adding $(id -un) to the video group (takes effect after re-login) =="
sudo usermod -aG video "$(id -un)"

echo
echo "Done. Reboot, then check with:  cam --list"
