#!/bin/sh
# Build usrsctp for the sdr-lab prefix on macOS ARM64.
#
# No patches are needed against upstream master. Two flags do the work:
# CMAKE_POLICY_VERSION_MINIMUM, because usrsctp still declares
# cmake_minimum_required(VERSION 3.0...3.10) and CMake 4 refuses anything
# below 3.5; and sctp_build_shared_lib, because the default is a static
# archive and libsctp-compat links against a dylib.
#
# SPDX-License-Identifier: LGPL-2.1-or-later

set -eu

LAB="${SRSRAN_PREFIX:-$HOME/sdr-lab}"
SRC="${LAB}/src/usrsctp"
PREFIX="${LAB}/local"
LOGS="${LAB}/logs"

. "${LAB}/env.sh" >/dev/null 2>&1 || true

if [ ! -d "${SRC}" ]; then
	echo "cloning usrsctp"
	git clone https://github.com/sctplab/usrsctp.git "${SRC}"
fi

echo "usrsctp at $(git -C "${SRC}" log -1 --format='%h %ci')"

mkdir -p "${SRC}/build" "${LOGS}"
cd "${SRC}/build"

cmake .. \
	-DCMAKE_INSTALL_PREFIX="${PREFIX}" \
	-DCMAKE_BUILD_TYPE=Release \
	-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
	-Dsctp_build_programs=OFF \
	-Dsctp_debug=OFF \
	-Dsctp_build_shared_lib=ON \
	2>&1 | tee "${LOGS}/usrsctp-configure.log"

make -j"$(sysctl -n hw.ncpu)" 2>&1 | tee "${LOGS}/usrsctp-build.log"
make install 2>&1 | tee "${LOGS}/usrsctp-install.log"

echo
echo "installed:"
ls -1 "${PREFIX}/lib/libusrsctp"* "${PREFIX}/include/usrsctp.h"
pkg-config --exists usrsctp && echo "pkg-config usrsctp $(pkg-config --modversion usrsctp)"
