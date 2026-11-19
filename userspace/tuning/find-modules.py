#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""
Print the camera module names the BIOS reports for each IPU3 sensor link.

Windows picks the tuning file <SENSOR>_<module>_SKY.cpf by this name. The
names live in GNVS fields LxM0..LxMF, whose layout is read from the DSDT.

Needs root (reads /sys/firmware/acpi/tables/DSDT and /dev/mem) and iasl.
Usage: sudo find-modules.py
"""

import os
import re
import subprocess
import sys
import tempfile


def main():
    with tempfile.TemporaryDirectory() as tmp:
        dat = os.path.join(tmp, 'dsdt.dat')
        with open('/sys/firmware/acpi/tables/DSDT', 'rb') as f:
            open(dat, 'wb').write(f.read())
        subprocess.run(['iasl', '-d', dat], cwd=tmp, check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        dsl = open(os.path.join(tmp, 'dsdt.dsl'), errors='replace').read().splitlines()

    region = None
    for line in dsl:
        m = re.search(r'OperationRegion \(GNVS, SystemMemory, (0x[0-9A-Fa-f]+), (0x[0-9A-Fa-f]+)\)', line)
        if m:
            region = (int(m.group(1), 16), int(m.group(2), 16))
            break
    if not region:
        sys.exit('GNVS region not found in DSDT')

    fields = {}
    i = 0
    while i < len(dsl):
        if 'Field (GNVS,' in dsl[i]:
            bit = 0
            i += 2
            while '}' not in dsl[i]:
                s = dsl[i].strip()
                m = re.match(r'Offset \((0x[0-9A-Fa-f]+|\d+)\)', s)
                if m:
                    bit = int(m.group(1), 0) * 8
                else:
                    m = re.match(r'(\w{0,4}),\s*(\d+)', s)
                    if m:
                        if m.group(1):
                            fields[m.group(1)] = (bit, int(m.group(2)))
                        bit += int(m.group(2))
                i += 1
        i += 1

    base, size = region
    page = base & ~0xfff
    with open('/dev/mem', 'rb') as mem:
        mem.seek(page)
        gnvs = mem.read(base - page + size)[base - page:]

    def val(name):
        b, n = fields[name]
        return int.from_bytes(gnvs[b // 8:b // 8 + (n + 7) // 8], 'little')

    for link in range(4):
        p = f'L{link}'
        if f'{p}M0' not in fields or not val(f'{p}EN'):
            continue
        name = bytes(val(f'{p}M{k:X}') for k in range(16)).split(b'\0')[0].decode(errors='replace')
        print(f'LNK{link}: module {name}  lanes {val(p + "NL")}  mclk {val(p + "CK")} Hz')


if __name__ == '__main__':
    main()
