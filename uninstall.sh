#!/bin/sh
# Remove the Dell Latitude 5175/5179 camera fix and restore the stock modules.
set -eu

PKG=latitude5179-camera

for v in $(dkms status "$PKG" 2>/dev/null | sed -n "s|^$PKG/\([^,]*\),.*|\1|p" | sort -u); do
	sudo dkms remove "$PKG/$v" --all
	sudo rm -rf "/usr/src/$PKG-$v"
done
sudo rm -f /etc/modprobe.d/latitude5179-camera.conf
sudo update-initramfs -u

echo "Removed. Reboot to load the stock modules."
