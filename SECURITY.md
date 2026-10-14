# Security

## Reporting a vulnerability

Please report security issues privately through GitHub's
["Report a vulnerability"](https://github.com/PhilemonChiro/perch/security/advisories/new)
form rather than a public issue. You will get an acknowledgement as soon as
the report is seen.

## FreeRDP version floor

Perch links FreeRDP 3 for all RDP transport. FreeRDP's own security fixes are
Perch's security fixes, so the build refuses to compile against a FreeRDP older
than the floor below.

- **Minimum: FreeRDP 3.32.0.** Enforced at compile time in
  `src/RdpSession.cpp` (`#error` on an older `FREERDP_VERSION`), so a vulnerable
  FreeRDP fails the build rather than shipping.
- **Why 3.32.0:** earlier 3.x releases are affected by a server-forced protocol
  downgrade that can disclose the user's password, and releases before 3.26.0
  miss RDPGFX / `gdi_CacheToSurface` remote-code-execution fixes. Perch enables
  the GFX pipeline, so those apply.
- Release builds install FreeRDP from each platform's current package source
  (brew on macOS, vcpkg on Windows, apt on Linux), all of which currently serve
  3.32.x. The floor is the guarantee: whatever the package manager provides, a
  build below 3.32.0 cannot be produced.

Keep FreeRDP current. `brew upgrade freerdp`, a fresh `vcpkg install`, or
`apt-get upgrade` from the security pocket pick up new fixes; raise the floor
here when a future advisory requires it.

## Transport posture

- **TLS/NLA.** Perch verifies server certificates (`VerifyCertificateEx` /
  `VerifyChangedCertificateEx`) and prompts on an unknown or changed
  certificate. It never passes `/cert:ignore` and never disables NLA.
- **UDP multitransport is opt-in per connection.** The lossy UDP/FEC channel is
  off by default (TCP only); enable "Use UDP transport" on a connection when you
  want it. This keeps the default attack surface minimal.
- **Credentials** live in the OS keychain (via QtKeychain), never in plaintext
  config, logs, or the process argument list.

## Dependencies

`.github/dependabot.yml` keeps the GitHub Actions in the workflows patched.
Native libraries (FreeRDP, OpenSSL, Qt) come from the platform package managers
and are not tracked by Dependabot; the FreeRDP floor above is the backstop.
