# ABS

<div align="center">

### Arch Building System

Lightweight helper for building Arch Linux/CachyOS packages from multiple repositories, managing chroots, and handling system updates.

![Shell](https://img.shields.io/badge/bash-script-121011?style=for-the-badge&logo=gnu-bash)
![Arch Linux](https://img.shields.io/badge/arch-linux-1793D1?style=for-the-badge&logo=arch-linux&logoColor=white)
![License](https://img.shields.io/badge/license-CC--BY--4.0-green?style=for-the-badge)

</div>

---

## Features

- **Multi-Repo Support:** Define custom Git repositories in `abs.config` (e.g., Arch, CachyOS, custom Github repos).
- **System Update Integration (`-U`):** Run full system updates (`yay -Syu` by default) but intercept specific packages to be manually compiled *before* the rest of the system updates.
- **Smart Package Installation:** After a successful build, it displays a numbered menu for selecting which sub-packages to install (supports ranges like `1-3, 5`).
- **Safer Failure Handling:** If build/test steps fail, ABS skips installation instead of prompting with missing package files.
- **Skip Rules:** Specify packages (like `systemd-tests`) in `abs.config` to completely hide them from installation prompts.
- **Aliases:** Support mapping sub-packages to their base repository PKGBUILD name using `PACKAGE_ALIASES`.
- **Custom Build Commands:** Define overriding build commands per package for both local and chroot builds.
- **Build Environment Control:** Specify default build environments (`local` or `chroot`) globally or per-package.
- **Automatic GPG Handling:** Fetches missing PGP keys defined in the PKGBUILD automatically.
- **Hooks:** Run custom pre-build and post-install commands for specific packages.

---

## Configuration (`abs.config` + `packages.config`)

Use:
- `abs.config` for global paths/repositories/update behavior
- `packages.config` for package-specific behavior (source, build env, tests, alias, hooks)

```bash
# abs.config
# Example repositories
declare -A REPOSITORIES
REPOSITORIES["arch"]="https://gitlab.archlinux.org/archlinux/packaging/packages"
REPOSITORIES["cachyos"]="https://github.com/CachyOS/CachyOS-PKGBUILDS.git"

# Build Environments
DEFAULT_BUILD_ENVIRONMENT="local"

# The fallback repository to use if a package doesn't have an explicitly defined source
DEFAULT_REPOSITORY="arch"

# System Update Command
SYSTEM_UPDATE_COMMAND="yay -Sy"
SYSTEM_UPDATE_WITH_REPOSITORY_REFRESH_COMMAND="yay -Syu"
# System Update Ignore flag (varies by package manager)
SYSTEM_UPDATE_IGNORE_FLAG="--ignore"

# Always completely ignore these packages during a system update
SYSTEM_UPDATE_IGNORE_PACKAGES=("linux" "linux-headers")
```

```bash
# packages.config
declare -A PACKAGES
PACKAGES["vim"]="source=arch build_env=local tests=off"
PACKAGES["qemu-full"]="source=arch build_env=local tests=on alias=qemu"
PACKAGES["firefox-pure"]="source=ventureoo build_env=chroot tests=on"

# Optional: packages to manually compile when running -U
MANUAL_UPDATE_PACKAGES=("systemd" "qemu-full")

# Optional custom build commands
declare -A CUSTOM_LOCAL_BUILD_COMMANDS
declare -A CUSTOM_CHROOT_BUILD_COMMANDS

# Local builds can take env vars directly
CUSTOM_LOCAL_BUILD_COMMANDS["qemu-full"]="ENABLE_BOLT=true makepkg --syncdeps --noconfirm --needed -f"

# Chroot builds isolate the environment. To pass an env var, inject it into the PKGBUILD first:
CUSTOM_CHROOT_BUILD_COMMANDS["qemu-full"]="sed -i '1i export ENABLE_BOLT=true' PKGBUILD && makechrootpkg -c -r \"\$MASTER_CHROOT\" -d \"\$PWD\""

# Skip installation of specific sub-packages
SKIP_INSTALL_PACKAGES=("systemd-tests")
```

---

## Flags

| Flag | Description |
| --- | --- |
| `-d` | Download package sources only. Do not build. |
| `-l` | Build locally with `makepkg` (overrides default). |
| `-h` | Build inside a chroot with `makechrootpkg` (overrides default). |
| `-o` | Compile only. Skip the package installation prompt. |
| `-t` | Skip package test suite (`--nocheck`). Useful for packages that fail in `check()`. |
| `-n` | Force a new build even if package artifacts already exist. |
| `-c` | Delete the existing package repository and clone it again. |
| `-e` | Run full cleaning, including removing downloaded repositories and built packages. |
| `-s` | Use `sudo` when deleting repositories or build artifacts. |
| `-r` | Remove the configured chroot. |
| `-k` | Install and populate Arch Linux / CachyOS signing keys. |
| `-u` | Update PKGBUILD checksums before building. |
| `-v` | Enable verbose output. |
| `-i` | Silent mode. Hide normal status output. |
| `-R` | Force git pull / repository refresh for all custom repositories. |
| `--repo=NAME` | Specify which repository to pull the package from. |
| `--install-only` | Only install already built artifacts from `READY_MADE_PACKAGES_PATH` (no build/rebuild). |
| `-U` | Perform full system update with manual compilation of configured packages. |
| `--help` | Show help output. |

---

## Example

```bash
# Build a package in a chroot, update sums, force a new build, using the CachyOS repo
bash abs.sh -h -u -n --repo=cachyos package-name

# Build locally but skip package tests (pass --nocheck to makepkg)
bash abs.sh -lt vim

# Retry install from already built files without rebuilding
bash abs.sh --install-only vim

# Run a system update, manually compiling any packages configured in abs.config first
bash abs.sh -U

# Run a system update and force a pull of all custom repos to check for updates
bash abs.sh -UR
```

---

## License

This project is licensed under **Creative Commons Attribution 4.0 International (CC BY 4.0)**.

That means people can use, modify, and share it, including commercially, as long as they give attribution and keep a link back to this project.
