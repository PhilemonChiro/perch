#!/usr/bin/env bash
# Bundle OpenSSL's "legacy" provider into a macOS .app.
#
# NLA authenticates with NTLM, whose password hash is MD4 and whose key
# exchange uses RC4. OpenSSL 3/4 keeps both in its "legacy" provider, which is
# not loaded by default. FreeRDP (built WITH_INTERNAL_MD4=OFF) fetches MD4 from
# OpenSSL, so without the provider NLA aborts with SEC_E_NO_CREDENTIALS even for
# correct credentials. macdeployqt bundles libcrypto but not the provider, and
# the provider's compiled search path points into the build host's Homebrew
# Cellar, which is absent on users' Macs. Ship the provider (matching FreeRDP's
# OpenSSL) plus a config that activates it; main.cpp sets OPENSSL_MODULES and
# OPENSSL_CONF to this directory when the app runs from a bundle.
#
# Usage: bundle-openssl-legacy.sh <path-to.app>   (run after macdeployqt,
# before codesign, so the added dylib gets signed with the rest of the bundle).
set -euo pipefail

APP=${1:?usage: bundle-openssl-legacy.sh <path-to.app>}
FRAMEWORKS="$APP/Contents/Frameworks"
MODDIR="$FRAMEWORKS/ossl-modules"

# Match the OpenSSL that FreeRDP links (openssl@4 today; fall back to @3).
OSSL=$(brew --prefix openssl@4 2>/dev/null || brew --prefix openssl@3)
SRC="$OSSL/lib/ossl-modules/legacy.dylib"
[ -f "$SRC" ] || { echo "legacy provider not found at $SRC" >&2; exit 1; }

mkdir -p "$MODDIR"
cp "$SRC" "$MODDIR/legacy.dylib"
chmod u+w "$MODDIR/legacy.dylib"

# Repoint the provider's libcrypto/libssl references at the bundled copies.
otool -L "$MODDIR/legacy.dylib" | awk 'NR>1 {print $1}' \
  | grep -iE 'libcrypto|libssl' \
  | while read -r dep; do
      install_name_tool -change "$dep" "@loader_path/../$(basename "$dep")" "$MODDIR/legacy.dylib"
    done

# Activate the default and legacy providers for every OpenSSL user in the app.
printf '%s\n' \
  'openssl_conf = openssl_init' \
  '[openssl_init]' \
  'providers = provider_sect' \
  '[provider_sect]' \
  'default = default_sect' \
  'legacy = legacy_sect' \
  '[default_sect]' \
  'activate = 1' \
  '[legacy_sect]' \
  'activate = 1' \
  > "$MODDIR/openssl.cnf"

echo "Bundled OpenSSL legacy provider from $OSSL"
otool -L "$MODDIR/legacy.dylib" | sed -n '2,$p'
