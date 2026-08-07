# PATH installers

Per-user install scripts shipped with release packages. They put `redub` on PATH
without requiring `dub run redub`.

| Script | Platform | Default location |
|---|---|---|
| `install.ps1` | Windows | `%LOCALAPPDATA%\Programs\redub` + User PATH |
| `install.sh` | Linux / macOS | `~/.local/share/redub` + symlink in `~/.local/bin` |
| `install.nu` | Any (Nushell) | Wraps the platform script |

## Quick start

After extracting a `*-portable.zip` / `*-portable.tar.gz` from a release:

```powershell
# Windows
powershell -ExecutionPolicy Bypass -File .\install.ps1
# or: nu install.nu
```

```bash
# Linux / macOS
bash ./install.sh
# or: nu install.nu
```

Bare release binaries (`redub-v*-windows-*.exe`, etc.) still work with these
scripts if placed in the same directory as the installer.

## Future: scaffold with easy-installer

These scripts match the portable-zip + PATH pattern. For generating installers
across more projects, see Dev-Centr **easy-installer**:

- https://github.com/dev-centr/easy-installer
- https://docs.devcentr.org/easy-installer/latest/index.html

MSI / winget packaging can use https://github.com/dev-centr/msi-generator.
