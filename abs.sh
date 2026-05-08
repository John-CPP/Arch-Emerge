#!/bin/bash

# -------------------------------------------------
# Paths
# -------------------------------------------------

die() {
    echo "ERROR: $*" >&2
    exit 1
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${ABS_CONFIG_FILE:-${SCRIPT_DIR}/abs.config}"
PACKAGES_CONFIG_FILE="${ABS_PACKAGES_CONFIG_FILE:-${SCRIPT_DIR}/packages.config}"

declare -A REPOSITORIES
declare -A CUSTOM_LOCAL_BUILD_COMMANDS CUSTOM_CHROOT_BUILD_COMMANDS
declare -A PRE_UPDATE_COMMANDS POST_UPDATE_COMMANDS PACKAGES
declare -a SKIP_INSTALL_PACKAGES SYSTEM_UPDATE_IGNORE_PACKAGES MANUAL_UPDATE_PACKAGES

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
else
    die "Config file '$CONFIG_FILE' not found"
fi

PACKAGES_CONFIG_FILE="${ABS_PACKAGES_CONFIG_FILE:-${PACKAGES_CONFIG_FILE:-${SCRIPT_DIR}/packages.config}}"
if [[ -f "$PACKAGES_CONFIG_FILE" ]]; then
    source "$PACKAGES_CONFIG_FILE"
fi

: "${PACKAGES_PATH:?Missing PACKAGES_PATH in $CONFIG_FILE}"
: "${CHROOT_BASE_PATH:?Missing CHROOT_BASE_PATH in $CONFIG_FILE}"
: "${READY_MADE_PACKAGES_PATH:?Missing READY_MADE_PACKAGES_PATH in $CONFIG_FILE}"

MASTER_CHROOT="${MASTER_CHROOT:-${CHROOT_BASE_PATH}/base}"

mkdir -p "$PACKAGES_PATH" "$CHROOT_BASE_PATH" "$READY_MADE_PACKAGES_PATH"

# -------------------------------------------------
# Defaults
# -------------------------------------------------
MODE="" # Leave empty to use DEFAULT_BUILD_ENVIRONMENT
DOWNLOAD_ONLY=0
NEWBUILD=0
CLEAN=0
SUDO=0
INSTALL_KEYS=0
UPDATE_PKGSUMS=0
VERBOSE=0
SILENT=0
COMPILE_ONLY=0
INSTALL_ONLY=0
NO_CHECK=0
REMOVE_CHROOT=0
DO_FULL_CLEANING=0
SYSTEM_UPDATE=0
FORCE_REPO_UPDATE=0
REPO_OVERRIDE=""
NO_CHECK_PACKAGE=0

# Default system update command if not set in config
SYSTEM_UPDATE_COMMAND="${SYSTEM_UPDATE_COMMAND:-sudo pacman -Syu}"
SYSTEM_UPDATE_WITH_REPOSITORY_REFRESH_COMMAND="${SYSTEM_UPDATE_WITH_REPOSITORY_REFRESH_COMMAND:-sudo pacman -Syu}"
SYSTEM_UPDATE_IGNORE_FLAG="${SYSTEM_UPDATE_IGNORE_FLAG:---ignore}"
DEFAULT_REPOSITORY="${DEFAULT_REPOSITORY:-arch}"
DEFAULT_BUILD_ENVIRONMENT="${DEFAULT_BUILD_ENVIRONMENT:-local}"

# -------------------------------------------------
# Verbose helper
# -------------------------------------------------
vlog() {
   if [[ "$VERBOSE" -eq 1 ]]; then
        echo "$@"
        return
   fi
}

blog() {
    if [[ "$SILENT" -eq 0 ]]; then
        echo "$@"
        return
   fi
}

require_commands() {
    local missing=()
    local cmd

    for cmd in "$@"; do
        command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing required command(s): ${missing[*]}"
    fi
}

get_package_config_value() {
    local pkg="$1"
    local key="$2"
    local config="${PACKAGES[$pkg]:-}"
    local token pair_key pair_value

    [[ -z "$config" ]] && return 1

    for token in $config; do
        pair_key="${token%%=*}"
        pair_value="${token#*=}"
        if [[ "$pair_key" == "$key" && "$pair_value" != "$token" ]]; then
            printf '%s\n' "$pair_value"
            return 0
        fi
    done

    return 1
}

resolve_package_base() {
    local pkg_input="$1"
    local pkg_alias=""

    pkg_alias="$(get_package_config_value "$pkg_input" alias 2>/dev/null || true)"
    if [[ -z "$pkg_alias" ]]; then
        pkg_alias="$pkg_input"
    fi

    printf '%s\n' "$pkg_alias"
}

resolve_package_source() {
    local pkg_input="$1"
    local pkg_source=""

    pkg_source="$(get_package_config_value "$pkg_input" source 2>/dev/null || true)"

    printf '%s\n' "$pkg_source"
}

resolve_package_build_environment() {
    local pkg_input="$1"
    local build_env=""

    build_env="$(get_package_config_value "$pkg_input" build_env 2>/dev/null || true)"

    printf '%s\n' "$build_env"
}

package_has_no_check_default() {
    local pkg_input="$1"
    local tests_value=""

    tests_value="$(get_package_config_value "$pkg_input" tests 2>/dev/null || true)"
    case "$tests_value" in
        off|false|0|no)
            return 0
            ;;
    esac

    return 1
}

pkg_name_from_file() {
    local pkg_file="$1"
    pacman -Qp "$pkg_file" 2>/dev/null | awk '{print $1}'
}

pkg_depends_from_file() {
    local pkg_file="$1"
    bsdtar -xOf "$pkg_file" .PKGINFO 2>/dev/null | awk -F ' = ' '/^depend = /{print $2}'
}

auto_include_local_dependencies() {
    local -n selected_files_ref="$1"
    local -n available_files_ref="$2"

    declare -A file_by_pkg=()
    declare -A selected_pkg=()

    local f pkg_name dep dep_name changed
    for f in "${available_files_ref[@]}"; do
        pkg_name="$(pkg_name_from_file "$f")"
        [[ -n "$pkg_name" ]] && file_by_pkg["$pkg_name"]="$f"
    done

    for f in "${selected_files_ref[@]}"; do
        pkg_name="$(pkg_name_from_file "$f")"
        [[ -n "$pkg_name" ]] && selected_pkg["$pkg_name"]=1
    done

    while true; do
        changed=0
        for f in "${selected_files_ref[@]}"; do
            while read -r dep; do
                [[ -z "$dep" ]] && continue
                dep_name="${dep%%[<>=]*}"
                [[ -z "$dep_name" ]] && continue
                if [[ -n "${file_by_pkg[$dep_name]:-}" && -z "${selected_pkg[$dep_name]:-}" ]]; then
                    selected_files_ref+=("${file_by_pkg[$dep_name]}")
                    selected_pkg["$dep_name"]=1
                    echo "==> Auto-including dependency from built set: $dep_name"
                    changed=1
                fi
            done < <(pkg_depends_from_file "$f")
        done
        [[ "$changed" -eq 0 ]] && break
    done
}

install_package_files() {
    if sudo pacman -U "$@"; then
        return 0
    fi
    echo "==> ERROR: Installation failed."
    return 1
}

run_configured_command() {
    local cmd="$1"

    vlog "==> Running command: $cmd"
    bash -o pipefail -c "$cmd"
}

run_system_update_command() {
    local cmd="$1"
    shift

    vlog "==> Running system update: $cmd $*"
    bash -o pipefail -c "$cmd \"\$@\"" _ "$@"
}

ensure_required_commands() {
    local required=(awk grep sed sort comm tee tr cut dirname basename bash)

    if [[ "$SYSTEM_UPDATE" -eq 1 ]]; then
        required+=(checkupdates vercmp pacman git makepkg gpg find head)
    elif [[ ${#PKG_ARRAY[@]} -gt 0 ]]; then
        required+=(git makepkg gpg find head)

        if [[ "$COMPILE_ONLY" -eq 0 ]]; then
            required+=(pacman bsdtar)
        fi
    fi

    if [[ "$INSTALL_KEYS" -eq 1 ]]; then
        required+=(pacman pacman-key)
    fi

    require_commands "${required[@]}"
}


# -------------------------------------------------
# Usage
# -------------------------------------------------
usage() {
    local exit_code="${1:-1}"

    cat <<EOF
Usage: $0 [options] pkgname...

Options:
  -d    Download only (no build)
  -l    Build locally
  -h    Build in chroot
  -o    Only compiles, doesn't install built packages
  -t    Skip package tests (pass --nocheck)
  -n    Force new build
  -c    Clean repo (delete + reclone)
  -e    Do Full Cleaning (Sometimes things hang because of some cache)
  -s    Use sudo for cleaning repo
  -r    Remove Chroot
  -k    Populate Keys (to fix unknown public key)
  -u    Update pkgsums before building
  -v    Verbose mode (show script comments)
  -i    Silent Mode
  -R    Force git pull / repository refresh for all custom repositories
  --repo=NAME  Use a specific repository from config (default: ${DEFAULT_REPOSITORY})
  --install-only  Only install already built package files (no repo prep/build)
  -U    Perform full system update (${SYSTEM_UPDATE_COMMAND} or ${SYSTEM_UPDATE_WITH_REPOSITORY_REFRESH_COMMAND} if -R used)

Flags can be combined (e.g. -ch, -hnc).
EOF
    exit "$exit_code"
}

# -------------------------------------------------
# Parse flags
# -------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --) shift; break ;;
        --repo=*) REPO_OVERRIDE="${1#*=}" ;;
        --install-only) INSTALL_ONLY=1 ;;
        --help) usage 0 ;;
        -*)
            flags="${1#-}"
            for (( i=0; i<${#flags}; i++ )); do
                f="${flags:$i:1}"
                case "$f" in
                    d) DOWNLOAD_ONLY=1 ;;
                    l) MODE="local" ;;
                    h) MODE="chroot" ;;
                    n) NEWBUILD=1 ;;
                    c) CLEAN=1 ;;
                    s) SUDO=1 ;;
                    k) INSTALL_KEYS=1 ;;
                    u) UPDATE_PKGSUMS=1 ;;
                    v) VERBOSE=1 ;;
                    i) SILENT=1 ;;
                    o) COMPILE_ONLY=1 ;;
                    t) NO_CHECK=1 ;;
                    r) REMOVE_CHROOT=1 ;;
                    e) DO_FULL_CLEANING=1 ;;
                    U) SYSTEM_UPDATE=1 ;;
                    R) FORCE_REPO_UPDATE=1 ;;
                    *) usage ;;
                esac
            done
            ;;
        *) break ;;
    esac
    shift
done

PKG_ARRAY=("$@")

#--------------------------------------
# Cleaners
#--------------------------------------
do_full_cleaning() {
    remove_chroot
    remove_all_cache
    remove_abs_artifacts
    CLEAN=1;
    NEWBUILD=1;
}

remove_chroot() {
    check_sudo_removal "$MASTER_CHROOT"
}

remove_abs_artifacts() {
    vlog "==> Removing all downloaded repositories and built packages..."
    check_sudo_removal "$PACKAGES_PATH"
    check_sudo_removal "$READY_MADE_PACKAGES_PATH"

    # Re-create empty base paths so subsequent commands don't fail
    mkdir -p "$PACKAGES_PATH" "$READY_MADE_PACKAGES_PATH"
}

remove_all_cache() {
    rm -rf ~/.cargo/registry/cache

    if command -v go >/dev/null 2>&1; then
        go clean -modcache
        go clean -cache
    fi

    if command -v npm >/dev/null 2>&1; then
        npm cache clean --force
    fi

    sudo pacman -Scc --noconfirm
}

check_sudo_removal() {
    local cmd=("$@")

    if [[ "$SUDO" -eq 1 ]]; then
            sudo rm -rf "${cmd[@]}"
        else
            rm -rf "${cmd[@]}"
    fi
}


# -------------------------------------------------
# Helpers
# -------------------------------------------------
bump_pkgrel() {
    local current base suffix next_suffix
    if [[ ! -f PKGBUILD ]]; then
        vlog "PKGBUILD not found, skipping pkgrel bump"
        return
    fi

    current=$(grep -E '^pkgrel=' PKGBUILD | cut -d= -f2 || true)
    if [[ -z "$current" ]]; then
        echo "pkgrel=1.2" >> PKGBUILD
        return
    fi

    base="${current%%.*}"
    suffix="${current#*.}"

    if [[ "$current" == "$base" || ! "$suffix" =~ ^[0-9]+$ || "$suffix" -lt 2 ]]; then
        next_suffix=2
    else
        next_suffix=$((suffix + 1))
    fi

    sed -i "s/^pkgrel=.*/pkgrel=${base}.${next_suffix}/" PKGBUILD || vlog "Failed to bump pkgrel, skipping"
}


install_all_keys() {
    vlog "==> Installing Arch Linux and CachyOS keyrings"
    sudo pacman -Sy --noconfirm archlinux-keyring cachyos-keyring || true

    vlog "==> Populating keys for archlinux and cachyos"
    sudo pacman-key --populate archlinux
    sudo pacman-key --populate cachyos || true

    vlog "==> Refreshing keys from keyserver"
    sudo pacman-key --keyserver hkps://keyserver.ubuntu.com --refresh-keys || true

    vlog "==> All keys installed and refreshed"
}

prepare_sums_pkgrel() {
    vlog "==> Package folder: $PWD"
    vlog "==> Preparing pkgsums..."
    prepare_pkgsums
    vlog "==> Bumping pkgrel..."
    bump_pkgrel
    vlog "==> Repo preparation done"

}

prepare_pkgsums() {
    if [[ "$UPDATE_PKGSUMS" -eq 1 ]]; then
        vlog "==> Updating PKGBUILD checksums..."
        updpkgsums || vlog "==> updpkgsums failed, continuing..."
    else
        vlog "==> pkgsums not requested to update"
    fi
}

# ----------------- Key Helpers -----------------
import_keys_from_pkgbuild() {
    local chroot_root="$1"
    local pkg_dir="$2"
    vlog "==> Importing PKGBUILD-specific keys into chroot $chroot_root"

    local keys=()
    mapfile -t keys < <(
        bash -c 'source "$1" >/dev/null 2>&1 || exit 0; printf "%s\n" "${validpgpkeys[@]:-}"' _ "$pkg_dir/PKGBUILD"
    )

    [[ ${#keys[@]} -eq 0 ]] && return 0

    vlog "==> Importing keys: ${keys[*]}"
    for key in "${keys[@]}"; do
        gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key"
    done

    vlog "==> PKGBUILD keys imported"
}


fix_unknown_keys() {
    local seen_keys=""
    local build_cmd="$1"

    while true; do
        # Run the command, tee output to log
        run_configured_command "$build_cmd" 2>&1 | tee /tmp/abs_script.log
        local exit_code=${PIPESTATUS[0]}

        if [[ "$exit_code" -eq 0 ]]; then
            vlog "==> Command succeeded"
            break
        fi

        # Extract missing keys
        local missing_keys
        missing_keys=$(grep -oP 'unknown public key \K[0-9A-F]+' /tmp/abs_script.log || true)

        # Filter out keys we've already imported
        missing_keys=$(comm -23 <(echo "$missing_keys" | sort) <(echo "$seen_keys" | tr ' ' '\n' | sort))

        if [[ -z "$missing_keys" ]]; then
            vlog "==> Build failed, no new missing keys detected. Giving up."
            return "$exit_code"
        fi

        vlog "==> Missing keys detected: $missing_keys"
        for key in $missing_keys; do
            vlog "==> Importing missing key $key..."
            gpg --keyserver hkps://keyserver.ubuntu.com --recv-keys "$key"
        done

        # Add newly imported keys to seen_keys
        seen_keys="$seen_keys $missing_keys"

        vlog "==> Retrying command after importing missing keys..."
    done
}


# ----------------- Repo Helpers -----------------
prepare_git_repo() {
    require_commands git find head

    local repo_name="$1"
    local repo_url="${REPOSITORIES[$repo_name]:-}"
    local pkg_input="$2"

    # Resolve the actual package base name to clone, if an alias exists
    local pkg
    pkg="$(resolve_package_base "$pkg_input")"

    local REPO_DIR="${PACKAGES_PATH}/${repo_name}"
    local PKG_DIR

    if [[ -z "$repo_url" ]]; then
        blog "Error: Repository '$repo_name' not found in config."
        exit 1
    fi

    if [[ "$repo_name" == "arch" ]]; then
        # Arch uses a different structure (one git repo per package)
        PKG_DIR="${PACKAGES_PATH}/arch/${pkg}"
        if [[ "$CLEAN" -eq 1 && -d "$PKG_DIR" ]]; then
            vlog "==> Cleaning arch repo for $pkg"
            check_sudo_removal "$PKG_DIR"
        fi

        if [[ -d "$PKG_DIR" ]]; then
            vlog "==> Arch repo exists for $pkg. Skipping update since arch packages are updated via checkupdates"
            cd "$PKG_DIR"
            # We don't pull here anymore as requested, just cd
        else
            vlog "==> Cloning arch repo for $pkg"
            mkdir -p "${PACKAGES_PATH}/arch"
            git clone "${repo_url}/${pkg}.git" "$PKG_DIR"
            cd "$PKG_DIR"
        fi

        return
    fi

    # Other repos (CachyOS, ventureoo) use a monolithic repo containing many packages
    mkdir -p "$REPO_DIR"

    if [[ "$CLEAN" -eq 1 && -d "$REPO_DIR" ]]; then
        vlog "==> Cleaning repo $repo_name"
        check_sudo_removal "$REPO_DIR"
    fi

    if [[ -d "$REPO_DIR/.git" ]]; then
        if [[ "$FORCE_REPO_UPDATE" -eq 1 ]]; then
            vlog "==> Updating repo $repo_name (R flag used)"
            cd "$REPO_DIR"
            git pull --ff-only || die "Failed to update repository: $REPO_DIR"
        else
            vlog "==> Repo $repo_name exists. Skipping update (No R flag used)"
            cd "$REPO_DIR"
        fi
    else
        vlog "==> Cloning repo $repo_name"
        git clone "$repo_url" "$REPO_DIR"
    fi

    # Locate package folder by PKGBUILD
    # Modified search: first find all PKGBUILDs, then grab their directories,
    # then grep for an exact directory match ending in /$pkg
    PKG_DIR=$(find "$REPO_DIR" -type f -name "PKGBUILD" -exec dirname {} \; | grep -E "/${pkg}$" | head -n1)

    if [[ -z "$PKG_DIR" ]]; then
        # Try finding anywhere if exact match fails
        PKG_DIR=$(find "$REPO_DIR" -type f -name "PKGBUILD" -exec dirname {} \; | grep -i "$pkg" | head -n1)
    fi

    if [[ -z "$PKG_DIR" ]]; then
        blog "Package $pkg not found in repo $repo_name"
        exit 1
    fi

    cd "$PKG_DIR"
}


prepare_repo() {
    local pkg="$1"

    # Custom logic to determine repo based on package configuration.
    # First check command-line --repo argument. If not DEFAULT_REPOSITORY, use it.
    local custom_repo="${2:-}"
    local repo_to_use="$DEFAULT_REPOSITORY"

    if [[ -n "$custom_repo" ]]; then
        repo_to_use="$custom_repo"
    elif [[ -n "$(resolve_package_source "$pkg")" ]]; then
        repo_to_use="$(resolve_package_source "$pkg")"
    fi

    prepare_git_repo "$repo_to_use" "$pkg"
}

# ----------------- Chroot Helpers -----------------
ensure_master_chroot() {
    require_commands mkarchroot

    if [[ ! -d "${MASTER_CHROOT}/root" ]]; then
        vlog "==> Creating master chroot"
        mkdir -p "$MASTER_CHROOT"
        mkarchroot "${MASTER_CHROOT}/root" base base-devel
    fi
}

update_chroot() {
    require_commands arch-nspawn

    vlog "==> Updating chroot"
    arch-nspawn "${MASTER_CHROOT}/root" pacman -Syu --noconfirm
}


# ----------------- Build Helpers -----------------
build_local() {
    require_commands makepkg gpg

    local pkg_input="$1"
    local pkg
    pkg="$(resolve_package_base "$pkg_input")"
    vlog "==> Building $pkg locally"
    export PKGDEST="$READY_MADE_PACKAGES_PATH"

    local expected_files=()
    mapfile -t expected_files < <(makepkg --packagelist 2>/dev/null || true)

    local all_expected_exist=1
    if [[ ${#expected_files[@]} -eq 0 ]]; then
        all_expected_exist=0
    else
        local expected_file
        for expected_file in "${expected_files[@]}"; do
            [[ -f "$expected_file" ]] || {
                all_expected_exist=0
                break
            }
        done
    fi

    if [[ "$all_expected_exist" -eq 1 && "$NEWBUILD" -eq 0 ]]; then
        vlog "==> Package already built, skipping"
    else
        local build_cmd="${CUSTOM_LOCAL_BUILD_COMMANDS[$pkg_input]:-}"
        if [[ -z "$build_cmd" ]]; then
            build_cmd="makepkg --syncdeps --noconfirm --needed -f"
            if [[ "$NO_CHECK" -eq 1 || "$NO_CHECK_PACKAGE" -eq 1 ]]; then
                build_cmd+=" --nocheck"
            fi
        fi

        if ! fix_unknown_keys "$build_cmd"; then
            echo "==> ERROR: Build failed for $pkg (local mode)."
            return 1
        fi
    fi

    return 0
}

build_chroot() {
    require_commands makepkg gpg mkarchroot arch-nspawn makechrootpkg

    local pkg_input="$1"
    local pkg
    pkg="$(resolve_package_base "$pkg_input")"
    vlog "==> Building $pkg in chroot"
    export PKGDEST="$READY_MADE_PACKAGES_PATH"

    ensure_master_chroot
    update_chroot

    local expected_files=()
    mapfile -t expected_files < <(makepkg --packagelist 2>/dev/null || true)

    local all_expected_exist=1
    if [[ ${#expected_files[@]} -eq 0 ]]; then
        all_expected_exist=0
    else
        local expected_file
        for expected_file in "${expected_files[@]}"; do
            [[ -f "$expected_file" ]] || {
                all_expected_exist=0
                break
            }
        done
    fi

    if [[ "$all_expected_exist" -eq 1 && "$NEWBUILD" -eq 0 ]]; then
        vlog "==> Package already built, skipping"
        return 0
    fi

    if [[ "$NEWBUILD" -eq 1 ]]; then
        local stale_files=()
        mapfile -t stale_files < <(makepkg --packagelist 2>/dev/null || true)
        [[ ${#stale_files[@]} -gt 0 ]] && check_sudo_removal "${stale_files[@]}"
    fi

    # Import known keys before build
    import_keys_from_pkgbuild "${MASTER_CHROOT}/root" "$PWD"

    local build_cmd="${CUSTOM_CHROOT_BUILD_COMMANDS[$pkg_input]:-}"
    if [[ -z "$build_cmd" ]]; then
        build_cmd="makechrootpkg -c -r \"$MASTER_CHROOT\" -d \"$PWD\""
        if [[ "$NO_CHECK" -eq 1 || "$NO_CHECK_PACKAGE" -eq 1 ]]; then
            build_cmd+=" -- --nocheck"
        fi
    fi

    if ! fix_unknown_keys "$build_cmd"; then
        echo "==> ERROR: Build failed for $pkg (chroot mode)."
        return 1
    fi

    return 0
}

should_skip_install() {
    local pkg_file="$1"
    local pkg_name

    # Use pacman to get the actual package name. It's the most reliable method.
    pkg_name=$(pacman -Qp "$pkg_file" 2>/dev/null | awk '{print $1}')

    if [[ -z "$pkg_name" ]]; then
        return 1 # Don't skip if we can't identify it
    fi

    for skip_pkg in "${SKIP_INSTALL_PACKAGES[@]}"; do
        if [[ "$pkg_name" == "$skip_pkg" ]]; then
            return 0 # Should skip
        fi
    done

    return 1 # Should not skip
}

install_built_packages() {
    require_commands pacman bsdtar

    local pkg_input="$1"

    # Use the resolved package name to look for output files
    local pkg
    pkg="$(resolve_package_base "$pkg_input")"

    local files=()
    mapfile -t files < <(makepkg --packagelist 2>/dev/null || true)

    if [[ ${#files[@]} -eq 0 ]]; then
        shopt -s nullglob
        files=("${READY_MADE_PACKAGES_PATH}/${pkg}-"*.pkg.tar.zst)
        shopt -u nullglob
    fi

    [[ ${#files[@]} -eq 0 ]] && return 0

    # Keep only package files that actually exist.
    # makepkg --packagelist may list expected outputs even when build failed.
    local existing_files=()
    local f
    for f in "${files[@]}"; do
        [[ -f "$f" ]] && existing_files+=("$f")
    done
    files=("${existing_files[@]}")

    [[ ${#files[@]} -eq 0 ]] && return 0

    # Filter out skipped packages first
    local valid_files=()
    for f in "${files[@]}"; do
        if should_skip_install "$f"; then
            vlog "==> Skipping installation of ignored package: $(basename "$f")"
        else
            valid_files+=("$f")
        fi
    done

    # Skip prompt if there's only 1 valid file
    if [[ ${#valid_files[@]} -eq 1 ]]; then
        echo "==> Only 1 package available: $(basename "${valid_files[0]}")"
        while true; do
            read -rp "Install it? [Y/n] " yn
            case "$yn" in
                [Yy]*|"")
                    local -a files_to_install=("${valid_files[0]}")
                    auto_include_local_dependencies files_to_install valid_files
                    if install_package_files "${files_to_install[@]}"; then
                        return 0
                    fi
                    echo "Retry selection."
                    ;;
                [Nn]*)
                    echo "Skipping installation."
                    return 0
                    ;;
                *) echo "Answer Y or N" ;;
            esac
        done
    elif [[ ${#valid_files[@]} -eq 0 ]]; then
        return 0
    fi

    echo "==> Packages available for installation:"
    local i=1
    for f in "${valid_files[@]}"; do
        echo "  $i) $(basename "$f")"
        ((i++))
    done

    while true; do
        read -rp "Enter numbers of packages to install (e.g. 1,2,3 or 1-3, 4) [leave empty to install all, 'n' to skip]: " choice

        if [[ -z "$choice" ]]; then
            # Install all
            local -a files_to_install=("${valid_files[@]}")
            auto_include_local_dependencies files_to_install valid_files
            if install_package_files "${files_to_install[@]}"; then
                break
            fi
            echo "Please choose again, include required dependencies, or press 'n' to skip."
        elif [[ "$choice" =~ ^[Nn]$ ]]; then
            echo "Skipping installation."
            break
        elif [[ "$choice" =~ ^[-0-9,[:space:]]+$ ]]; then
            # Parse ranges and comma separated values
            local -a selected_indices=()

            # Remove spaces
            choice="${choice// /}"

            IFS=',' read -ra parts <<< "$choice"
            local invalid_part=0
            for part in "${parts[@]}"; do
                if [[ -z "$part" ]]; then
                    continue
                elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                    local start="${BASH_REMATCH[1]}"
                    local end="${BASH_REMATCH[2]}"
                    if (( start > end )); then
                        echo "Invalid range: $part"
                        invalid_part=1
                        break
                    fi
                    for (( j=start; j<=end; j++ )); do
                        selected_indices+=("$j")
                    done
                elif [[ "$part" =~ ^[0-9]+$ ]]; then
                    selected_indices+=("$part")
                else
                    echo "Invalid selection: $part"
                    invalid_part=1
                    break
                fi
            done

            if [[ "$invalid_part" -eq 1 ]]; then
                continue
            fi

            # Collect selected files
            local -a files_to_install=()
            for idx in "${selected_indices[@]}"; do
                # Convert 1-based index to 0-based
                local array_idx=$((idx - 1))
                if [[ $array_idx -ge 0 && $array_idx -lt ${#valid_files[@]} ]]; then
                    files_to_install+=("${valid_files[$array_idx]}")
                else
                    echo "Warning: Number $idx is out of range."
                fi
            done

            if [[ ${#files_to_install[@]} -gt 0 ]]; then
                auto_include_local_dependencies files_to_install valid_files
                if install_package_files "${files_to_install[@]}"; then
                    break
                fi
                echo "Please choose again, include required dependencies, or press 'n' to skip."
            else
                echo "No valid packages selected."
            fi
        else
            echo "Invalid input format. Please use numbers, commas, and hyphens (e.g. 1,2,3 or 1-3)."
        fi
    done

    return 0
}

process_package() {
    local pkg_input="$1"
    local custom_repo="${2:-}"

    local pkg
    pkg="$(resolve_package_base "$pkg_input")"

    (
        if [[ "$INSTALL_ONLY" -eq 1 ]]; then
            vlog "==> Install-only mode for $pkg"
            install_built_packages "$pkg_input" || exit 1
            exit 0
        fi

        prepare_repo "$pkg_input" "$custom_repo"

        NO_CHECK_PACKAGE=0
        if package_has_no_check_default "$pkg_input"; then
            NO_CHECK_PACKAGE=1
            vlog "==> tests=off configured for $pkg_input, using --nocheck"
        fi

        # Execute pre-build commands if any
        if [[ -n "${PRE_UPDATE_COMMANDS[$pkg_input]:-}" ]]; then
            vlog "==> Running pre-update commands for $pkg_input"
            run_configured_command "${PRE_UPDATE_COMMANDS[$pkg_input]}"
        fi

        prepare_sums_pkgrel

        if [[ "$DOWNLOAD_ONLY" -eq 1 ]]; then
            vlog "==> Download-only mode, skipping build for $pkg"
        else
            # Determine build mode
            local current_mode="$MODE"
            if [[ -z "$current_mode" ]]; then
                current_mode="$(resolve_package_build_environment "$pkg_input")"
                if [[ -z "$current_mode" ]]; then
                    current_mode="$DEFAULT_BUILD_ENVIRONMENT"
                fi
            fi

            vlog "==> MODE=$current_mode, building package $pkg..."

            local build_ok=0
            if [[ "$current_mode" == "local" ]]; then
                if ! build_local "$pkg_input"; then
                    build_ok=1
                fi
            elif [[ "$current_mode" == "chroot" ]]; then
                if ! build_chroot "$pkg_input"; then
                    build_ok=1
                fi
            else
                echo "ERROR: Invalid build mode: $current_mode"
                exit 1
            fi

            if [[ "$build_ok" -ne 0 ]]; then
                echo "==> Build failed for $pkg. Skipping installation."
                exit 1
            fi

            if [[ "$COMPILE_ONLY" -eq 0 ]]; then
                if ! install_built_packages "$pkg_input"; then
                    echo "==> Installation failed for $pkg."
                    exit 1
                fi

                # Execute post-build commands if any
                if [[ -n "${POST_UPDATE_COMMANDS[$pkg_input]:-}" ]]; then
                    vlog "==> Running post-update commands for $pkg_input"
                    run_configured_command "${POST_UPDATE_COMMANDS[$pkg_input]}"
                fi
            fi
        fi
    )
}

# -------------------------------------------------
# Main
# -------------------------------------------------

ensure_required_commands

if [[ "$SYSTEM_UPDATE" -eq 1 && "$INSTALL_ONLY" -eq 1 ]]; then
    die "--install-only cannot be used with -U"
fi

if [[ "$INSTALL_KEYS" -eq 1 ]]; then
    install_all_keys
    blog "==> Keys installed."
fi

if [[ "$REMOVE_CHROOT" -eq 1 ]]; then
    remove_chroot
    blog "==> Chroot Removed. "
fi

if [[ "$DO_FULL_CLEANING" -eq 1 ]]; then
    do_full_cleaning
    blog "==> Full cleaning done."
fi

# If only maintenance flags (-k, -r, -e) were given and no packages or system
# update were requested, exit successfully now.
if [[ ${#PKG_ARRAY[@]} -eq 0 && "$SYSTEM_UPDATE" -eq 0 && "$MODE" != "chroot" ]] \
    && [[ "$INSTALL_KEYS" -eq 1 || "$REMOVE_CHROOT" -eq 1 || "$DO_FULL_CLEANING" -eq 1 ]]; then
    exit 0
fi

# System Update logic
if [[ "$SYSTEM_UPDATE" -eq 1 ]]; then
    blog "==> Checking for system updates..."

    # Determine command to use based on R flag
    cmd_to_use="$SYSTEM_UPDATE_COMMAND"
    if [[ "$FORCE_REPO_UPDATE" -eq 1 ]]; then
        cmd_to_use="$SYSTEM_UPDATE_WITH_REPOSITORY_REFRESH_COMMAND"
    fi

    # Get list of packages that need updating (from arch repos)
    # CheckUpdates returns non-zero if no updates, so we ignore failures
    updates_available=$(checkupdates 2>/dev/null || true)

    declare -a pkgs_to_compile=()

    if [[ -n "$updates_available" ]]; then
        while read -r update_line; do
            pkg_name=$(echo "$update_line" | awk '{print $1}')

            # Check if this package is in our manual update list
            for manual_pkg in "${MANUAL_UPDATE_PACKAGES[@]}"; do
                if [[ "$pkg_name" == "$manual_pkg" ]]; then
                    # Avoid duplicates
                    already_added=0
                    for p in "${pkgs_to_compile[@]}"; do
                        if [[ "$p" == "$pkg_name" ]]; then
                            already_added=1
                            break
                        fi
                    done
                    if [[ "$already_added" -eq 0 ]]; then
                        pkgs_to_compile+=("$pkg_name")
                    fi
                    break
                fi
            done
        done <<< "$updates_available"
    fi

    # If -R is passed, check custom repositories for updates
    if [[ "$FORCE_REPO_UPDATE" -eq 1 ]]; then
        for manual_pkg in "${MANUAL_UPDATE_PACKAGES[@]}"; do
            already_added=0
            for p in "${pkgs_to_compile[@]}"; do
                if [[ "$p" == "$manual_pkg" ]]; then
                    already_added=1
                    break
                fi
            done
            [[ "$already_added" -eq 1 ]] && continue

            manual_pkg_source="$(resolve_package_source "$manual_pkg")"
            repo_to_use="${REPO_OVERRIDE:-${manual_pkg_source:-$DEFAULT_REPOSITORY}}"

            if [[ "$repo_to_use" != "arch" ]]; then
                blog "==> Checking custom repository ($repo_to_use) for $manual_pkg updates..."

                needs_update=0
                if (
                    prepare_repo "$manual_pkg" "$repo_to_use"
                    if [[ -f PKGBUILD ]]; then
                        source PKGBUILD >/dev/null 2>&1 || true
                        full_ver=""
                        [[ -n "${epoch:-}" ]] && full_ver="${epoch}:"

                        # Fallback for missing pkgver/pkgrel which shouldn't happen but keeps shellcheck quiet
                        safe_pkgver="${pkgver:-1.0}"
                        safe_pkgrel="${pkgrel:-1}"
                        full_ver="${full_ver}${safe_pkgver}-${safe_pkgrel}"

                        pkg_base="$(resolve_package_base "$manual_pkg")"

                        inst_ver=$(pacman -Q "$pkg_base" 2>/dev/null | awk '{print $2}' || true)

                        if [[ -z "$inst_ver" ]] || [[ $(vercmp "$full_ver" "$inst_ver") -gt 0 ]]; then
                            exit 100
                        fi
                    fi
                    exit 0
                ); then
                    needs_update=0
                else
                    if [[ $? -eq 100 ]]; then
                        needs_update=1
                    fi
                fi

                if [[ "$needs_update" -eq 1 ]]; then
                    pkgs_to_compile+=("$manual_pkg")
                fi
            fi
        done
    fi

    if [[ ${#pkgs_to_compile[@]} -gt 0 ]]; then
        blog "==> The following packages will be manually compiled:"
        for p in "${pkgs_to_compile[@]}"; do
            blog "  -> $p"
        done

        # Then compile and install manual packages first
        blog "==> Compiling manual packages..."
        for p in "${pkgs_to_compile[@]}"; do
            process_package "$p" "$REPO_OVERRIDE"
        done

        # Finally, update all other packages standard way
        blog "==> Updating standard system packages..."

        # 1. We add the configured ignore flag for all manually compiled packages
        ignore_args=()
        for p in "${pkgs_to_compile[@]}"; do
            ignore_args+=("${SYSTEM_UPDATE_IGNORE_FLAG}" "$p")
        done

        # 2. We add the configured ignore flag for all explicitly ignored packages from config
        for p in "${SYSTEM_UPDATE_IGNORE_PACKAGES[@]}"; do
            ignore_args+=("${SYSTEM_UPDATE_IGNORE_FLAG}" "$p")
        done

        run_system_update_command "$cmd_to_use" "${ignore_args[@]}"

    else
        blog "==> No manual compile packages need updating. Running standard update..."
        # Apply configured ignore packages even if no manual compilations were done
        ignore_args=()
        for p in "${SYSTEM_UPDATE_IGNORE_PACKAGES[@]}"; do
            ignore_args+=("${SYSTEM_UPDATE_IGNORE_FLAG}" "$p")
        done

        run_system_update_command "$cmd_to_use" "${ignore_args[@]}"
    fi
    exit 0
fi

if [[ ${#PKG_ARRAY[@]} -eq 0 && "$MODE" != "chroot" ]]; then
    blog "No packages to build."
    exit 1
fi

if [[ ${#PKG_ARRAY[@]} -eq 0 ]]; then
    if [[ "$MODE" == "chroot" ]]; then
        blog "==> No packages specified, preparing/updating chroot"
        ensure_master_chroot
        update_chroot
        vlog "==> Chroot ready"
        exit 0
    else
        usage
    fi
fi

overall_status=0
for pkg in "${PKG_ARRAY[@]}"; do
    if ! process_package "$pkg" "$REPO_OVERRIDE"; then
        overall_status=1
    fi
done

if [[ "$overall_status" -eq 0 ]]; then
    blog "==> All requested packages processed successfully"
else
    blog "==> Some packages failed to process."
    exit 1
fi
