#!/bin/sh
# Build srsRAN 4G for macOS on Apple Silicon, from nothing to installed binaries.
#
# Everything lands under one prefix, by default ~/sdr-lab, and nothing is
# written to /opt/homebrew except the Homebrew dependencies themselves.
#
#   ./scripts/install.sh                 # default prefix
#   SRSRAN_PREFIX=/opt/lab ./install.sh  # somewhere else
#
# SPDX-License-Identifier: AGPL-3.0-or-later

set -eu

PREFIX="${SRSRAN_PREFIX:-$HOME/sdr-lab}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$PREFIX/src"
LOGS="$PREFIX/logs"
JOBS="$(sysctl -n hw.ncpu)"

say() { printf '\n== %s\n' "$*"; }

case "$(uname -sm)" in
  "Darwin arm64") ;;
  *) echo "This port targets macOS on Apple Silicon. Found: $(uname -sm)"; exit 1 ;;
esac

mkdir -p "$SRC" "$LOGS" "$PREFIX/local" "$PREFIX/var"

# --- 1. Homebrew dependencies ------------------------------------------------
say "Homebrew dependencies"
command -v brew >/dev/null || { echo "Homebrew is required."; exit 1; }
# mbedtls@3 specifically: mbedtls 4 removed mbedtls/aes.h and mbedtls/md5.h and
# made mbedtls_md_hmac a private identifier.
brew install cmake pkg-config boost fftw zeromq uhd libconfig mbedtls@3 tmux || true
MB="$(brew --prefix mbedtls@3)"

# --- 2. usrsctp --------------------------------------------------------------
say "usrsctp"
SRSRAN_PREFIX="$PREFIX" "$REPO/scripts/install_usrsctp.sh"

# --- 3. libsctp-compat -------------------------------------------------------
say "libsctp-compat"
if [ ! -d "$SRC/libsctp-compat" ]; then
  git clone https://github.com/AndreiGosman/libsctp-compat-macos-arm64.git \
      "$SRC/libsctp-compat"
fi
mkdir -p "$SRC/libsctp-compat/build"
cd "$SRC/libsctp-compat/build"
cmake .. -DCMAKE_INSTALL_PREFIX="$PREFIX/local" -DCMAKE_BUILD_TYPE=Release >/dev/null
make -j"$JOBS"
# All four must pass. The two-process test is the one that matters; the others
# cannot reach the transport faults it covers.
ctest --output-on-failure
make install >/dev/null

# --- 4. linux/* uapi headers -------------------------------------------------
say "linux/* headers"
SRSRAN_PREFIX="$PREFIX" "$REPO/linux-compat-headers/install.sh" "$PREFIX/local"

# --- 5. srsRAN source and patches -------------------------------------------
say "srsRAN 4G source"
if [ ! -d "$SRC/srsRAN_4G" ]; then
  git clone https://github.com/srsran/srsRAN_4G.git "$SRC/srsRAN_4G"
fi
cd "$SRC/srsRAN_4G"

if [ ! -f .macos-arm64-patched ]; then
  say "applying $(ls "$REPO"/patches/*.patch | wc -l | tr -d ' ') patches"
  for p in "$REPO"/patches/*.patch; do
    printf '  %s\n' "$(basename "$p")"
    patch -p1 --forward < "$p" || { echo "failed on $(basename "$p")"; exit 1; }
  done
  touch .macos-arm64-patched
else
  echo "  already patched, skipping"
fi

# --- 6. configure and build --------------------------------------------------
say "configure and build"
mkdir -p build && cd build
# Every flag here is load-bearing; see docs/session-summary.md section 10.
cmake .. \
  -DCMAKE_INSTALL_PREFIX="$PREFIX/local" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_PREFIX_PATH="$MB" \
  -DSRSRAN_CXX_STANDARD=c++17 \
  -DCMAKE_INSTALL_RPATH="$PREFIX/local/lib" \
  -DCMAKE_INSTALL_RPATH_USE_LINK_PATH=ON \
  -DCMAKE_C_FLAGS="-I$PREFIX/local/include" \
  -DCMAKE_CXX_FLAGS="-I$PREFIX/local/include" \
  -DENABLE_WERROR=OFF -DENABLE_HARDSIM=OFF \
  -DENABLE_UHD=ON -DENABLE_ZEROMQ=ON \
  -DENABLE_SRSUE=ON -DENABLE_SRSENB=ON -DENABLE_SRSEPC=ON \
  -DENABLE_GUI=OFF -DENABLE_5GNR=OFF \
  -DENABLE_ALL_TEST=OFF -DBUILD_TESTS=OFF \
  2>&1 | tee "$LOGS/srsran-configure.log" | tail -3
make -j"$JOBS" 2>&1 | tee "$LOGS/srsran-build.log" | tail -3
make install >/dev/null

# --- 7. verify ---------------------------------------------------------------
# With a clean environment, because that is what sudo gives them: SIP strips
# every DYLD_* variable. Check all three, not one.
say "verifying the installed binaries in a clean environment"
rc=0
for b in srsue srsenb srsepc; do
  if env -i HOME="$HOME" "$PREFIX/local/bin/$b" --help >/dev/null 2>&1; then
    echo "  $b ok"
  else
    echo "  $b FAILED to start"; rc=1
  fi
done
[ "$rc" -eq 0 ] || exit 1

say "done"
cat <<TXT

Binaries are in $PREFIX/local/bin.

Next, copy the configuration templates and fill in a key pair:

  mkdir -p $PREFIX/etc/srsran
  cp $REPO/etc/srsran/*.template $PREFIX/etc/srsran/
  cp $REPO/etc/srsran/{rr,sib,rb}.conf $PREFIX/etc/srsran/
  # rename the .template files, then:
  #   K=\$(openssl rand -hex 16); OPc=\$(openssl rand -hex 16)
  # and put the same two values in ue.conf and user_db.csv

Then run the loopback:

  sudo $REPO/scripts/run-faza1.sh
  ping -c 5 172.16.0.1
TXT
