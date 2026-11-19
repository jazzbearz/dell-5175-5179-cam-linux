#!/bin/sh
# Generate libcamera IPU3 tuning files (CCM + lens shading) from Dell's
# Windows camera driver package and install them to /etc/libcamera/ipa/ipu3/.
#
# Requires libcamera built with userspace/libcamera-0.7.0-ipu3-ccm-lsc.patch
# (Ccm and Lsc algorithms); stock libcamera rejects these tuning files.
#
# Usage: install-tuning.sh DELL_V9X4F.EXE [FRONT_MODULE] [REAR_MODULE]
#   Module names default to the Latitude 5179 tested here (4BF523T2 front,
#   4BA862T2 rear). Find yours with: sudo ./find-modules.py
#   Front: stock values (CCM 1.0, gamma 2.2, black level from the file,
#   white locus). Rear: REAR_SATURATION/REAR_GAMMA/REAR_BLACK_LEVEL.
set -eu

EXE=${1:?usage: $0 Intel-2D-Imaging-Driver_V9X4F_*.EXE [front_module] [rear_module]}
FRONT=${2:-4BF523T2}
REAR=${3:-4BA862T2}
SAT=${SATURATION:-1.0}
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ver=$(dpkg-query -W -f '${Version}' libcamera0.7 2>/dev/null || true)
case "$ver" in
	*+ipu3vf[3-9]*) ;;
	*) echo "libcamera $ver lacks the Ccm/Lsc/locus/gamma support; run userspace/build-libcamera.sh first." >&2
	   exit 1 ;;
esac

python3 -I - "$EXE" "$TMP" "$FRONT" "$REAR" <<'EOF'
import os, sys, zipfile
exe, out, front, rear = sys.argv[1:]
z = zipfile.ZipFile(exe)
names = {os.path.basename(n).lower(): n for n in z.namelist()}
for sensor, mod in (('ov5670', front), ('ov8858', rear)):
    key = f'{sensor}_{mod}_sky.cpf'.lower()
    if key not in names:
        sys.exit(f'{key} not found in {exe}')
    open(os.path.join(out, f'{sensor}.cpf'), 'wb').write(z.read(names[key]))
EOF

python3 -I "$HERE/cpf2yaml.py" "$TMP/ov5670.cpf" "$TMP/ov5670.yaml" \
	--bayer GRBG --saturation "$SAT" --sensor "(front, $FRONT)"
# The rear module's stock CCM (diagonal up to 2.3) with gamma 2.2 amplifies
# colour noise and AWB error under libcamera's grey-world AWB; keep the rear on
# conservative settings that tested well (black level 64, gamma 1.1, CCM 0.3).
python3 -I "$HERE/cpf2yaml.py" "$TMP/ov8858.cpf" "$TMP/ov8858.yaml" \
	--bayer BGGR --saturation "${REAR_SATURATION:-0.3}" --gamma "${REAR_GAMMA:-1.1}" \
	--black-level "${REAR_BLACK_LEVEL:-64}" --no-locus --sensor "(rear, $REAR)"

sudo install -d /etc/libcamera/ipa/ipu3
sudo install -m 0644 "$TMP/ov5670.yaml" "$TMP/ov8858.yaml" /etc/libcamera/ipa/ipu3/
systemctl --user restart wireplumber 2>/dev/null || true
echo "Installed /etc/libcamera/ipa/ipu3/ov5670.yaml and ov8858.yaml"
echo "Remove them (sudo rm /etc/libcamera/ipa/ipu3/ov5670.yaml /etc/libcamera/ipa/ipu3/ov8858.yaml)"
echo "BEFORE reverting to a stock libcamera, or the cameras will fail to start."
