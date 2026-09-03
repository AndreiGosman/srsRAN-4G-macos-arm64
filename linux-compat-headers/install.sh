#!/bin/sh
# Install the Linux uapi compatibility headers into the sdr-lab prefix.
#
# A linux/ directory is safe to put on a shared include path on Darwin in a way
# that a bare endian.h or fmt/format.h is not: no macOS component ships one, so
# these names cannot shadow anything.
#
# SPDX-License-Identifier: LGPL-2.1-or-later
set -eu
PREFIX="${1:-$HOME/sdr-lab/local}"
SRC="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$PREFIX/include/linux"
cp "$SRC"/linux/*.h "$PREFIX/include/linux/"
echo "installed into $PREFIX/include/linux:"
ls -1 "$PREFIX/include/linux"
