# Changelog

## 1.0.0 - 2026-10-31

### Fixed

- Validate the full `wechat.dylib` SHA-256 and every registered ARM64 prologue
  before reporting a build as supported.
- Harden input checks in the read-only compatibility inspector.

### Changed

- First public release. The plugin version is 1.0.0.
- Replace the floating-pet runtime with an original, dependency-free Canvas 2D
  implementation.
- Simplify manager copy and add a confirmed "move to Trash" action for
  multi-instance copies.
- Replace existing enhanced copies in place instead of accumulating a new
  timestamped backup on every overwrite; add a menu action to clean legacy
  backups.
- Add GitHub and Telegram links plus a dedicated manager app icon.
- Add source and installer release packaging with SHA-256 checksums.
- Document privacy, third-party boundaries and security reporting.
