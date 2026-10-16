#!/usr/bin/env bash
# Bundle OpenSSL's "legacy" provider next to Perch.exe on Windows.
#
# NLA authenticates with NTLM, whose password hash is MD4 and whose key
# exchange uses RC4. OpenSSL 3/4 keeps both in its "legacy" provider, which is
# not loaded by default. FreeRDP (vcpkg, WITH_INTERNAL_MD4=OFF) fetches MD4 from
# OpenSSL, so without the provider NLA aborts with SEC_E_NO_CREDENTIALS even for
# correct credentials. windeployqt does not deploy OpenSSL at all, and the
# provider's compiled search path points into the build host's vcpkg tree,
# which is absent on users' PCs. Ship the provider plus a config that activates
# it; main.cpp sets OPENSSL_MODULES and OPENSSL_CONF to this directory when the
# app runs from a package.
#
# Usage: bundle-openssl-legacy-win.sh <dist-dir>   (run after windeployqt; the
# libcrypto DLL the provider needs is already beside Perch.exe in <dist-dir>).
set -euo pipefail

DIST=${1:?usage: bundle-openssl-legacy-win.sh <dist-dir>}
MODDIR="$DIST/ossl-modules"
VCPKG="${VCPKG_INSTALLATION_ROOT:?VCPKG_INSTALLATION_ROOT not set}"

# vcpkg has shipped the provider under a few layouts across versions; take the
# first that exists.
SRC=""
for p in \
  "$VCPKG/installed/x64-windows/bin/legacy.dll" \
  "$VCPKG/installed/x64-windows/lib/ossl-modules/legacy.dll" \
  "$VCPKG/installed/x64-windows/ossl-modules/legacy.dll"; do
  [ -f "$p" ] && { SRC="$p"; break; }
done
[ -n "$SRC" ] || { echo "legacy provider (legacy.dll) not found under $VCPKG/installed/x64-windows" >&2; exit 1; }

mkdir -p "$MODDIR"
cp "$SRC" "$MODDIR/legacy.dll"

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

echo "Bundled OpenSSL legacy provider from $SRC"
