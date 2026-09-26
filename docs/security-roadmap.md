# Security roadmap

## Current decisions

- Backfort supports one or more `age` recipients. A production host can encrypt
  without holding a recovery identity.
- Optional Minisign signatures protect a payload stored on an untrusted
  destination when that destination does not have the signing key.
- Symmetric GPG uses AES-256 with iterated SHA-512 S2K.
- Backfort intentionally does **not** support `age -p`. The age CLI has no
  suitable non-interactive passphrase interface; passing a password through
  stdin or a broadly exposed environment variable would weaken the model.
- Backfort does not implement TPM wrapping, custom envelope encryption or a
  home-grown split-secret scheme. Those mechanisms need platform-specific key
  management and do not belong in the current one-shot Bash trust boundary.

## Planned after format stabilization

1. Offline recovery profile that can list, verify and restore from a minimal
   destination-and-identity configuration.
2. Recovery-kit command and printable guide: format version, required tools,
   environment-variable names, configured recipients and manual recovery
   commands—never secret values.
3. Key-rotation workflow with an explicit, auditable policy for existing
   bundles. It must not silently rewrite or delete remote copies.
4. Restore drills in disposable infrastructure, including signature and
   multi-recipient recovery checks.
