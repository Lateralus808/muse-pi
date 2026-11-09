#!/usr/bin/env python3
"""fatboot.py — minimal FAT boot-partition editor.

Fallback for build-muse-pi.sh when mtools is not installed; uses the
pyfatfs library (pip install pyfatfs). Only root-directory operations —
that is all a Raspberry Pi boot partition customization needs.

Usage:
  fatboot.py <partition-image> ls
  fatboot.py <partition-image> cat <name>
  fatboot.py <partition-image> put <local-file> <name>
  fatboot.py <partition-image> rm <name>
"""

import sys

from pyfatfs.PyFatFS import PyFatFS


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    img, cmd = sys.argv[1], sys.argv[2]
    fs = PyFatFS(img, offset=0, read_only=False)
    try:
        if cmd == "ls":
            for name in fs.listdir("/"):
                print(name)
        elif cmd == "cat":
            sys.stdout.buffer.write(fs.readbytes("/" + sys.argv[3]))
        elif cmd == "put":
            with open(sys.argv[3], "rb") as f:
                data = f.read()
            name = "/" + sys.argv[4]
            if fs.exists(name):
                fs.remove(name)
            fs.writebytes(name, data)
        elif cmd == "rm":
            name = "/" + sys.argv[3]
            if fs.exists(name):
                fs.remove(name)
        else:
            print("unknown command: " + cmd)
            return 2
    finally:
        fs.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
