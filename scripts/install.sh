#!/usr/bin/env bash
#
# AMACheck Odoo addon installer
#
# Usage:
#   sudo bash install.sh                 # install (default)
#   sudo bash install.sh --update        # pull latest code & upgrade the module
#   sudo bash install.sh --uninstall     # remove the module from the database
#   sudo bash install.sh --instance foo  # skip instance picker
#   sudo bash install.sh --branch 19.0   # force a specific Odoo branch (skip auto-detect)
#   sudo bash install.sh --no-install    # (install mode) set up files only, skip module install
#   sudo bash install.sh --help
#
# Supports two deployment styles:
#   1. Docker (containers named *odoo*-app)
#   2. systemd (services named odoo*.service)
#
set -euo pipefail

# ---------- Constants ----------
REPO_URL="https://github.com/amachecks/account_amacheck.git"
REPO_WEB="https://github.com/amachecks/account_amacheck"
SUPPORTED_BRANCHES=("18.0" "19.0")
MODULE="account_amacheck"
SCRIPT_VERSION="1.0.0"

# Set after version detection
BRANCH=""
ZIP_URL=""
ODOO_VERSION=""

# ---------- Colors ----------
if [ -t 1 ]; then
    RED=$'\033[0;31m'
    GREEN=$'\033[0;32m'
    YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'
    BOLD=$'\033[1m'
    NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; NC=""
fi

# ---------- Flags ----------
MODE="install"   # install | update | uninstall
INSTANCE_OVERRIDE=""
BRANCH_OVERRIDE=""
SKIP_MODULE_INSTALL=0
ASSUME_YES=0
REMOVE_FILES=""  # for uninstall: ""=ask, "yes"=delete, "no"=keep

# ---------- Logging ----------
section() { printf "\n${BOLD}${BLUE}==> %s${NC}\n" "$*"; }
info()    { printf "    %s\n" "$*"; }
ok()      { printf "${GREEN}    ✓ %s${NC}\n" "$*"; }
warn()    { printf "${YELLOW}    ! %s${NC}\n" "$*"; }
err()     { printf "${RED}    ✗ %s${NC}\n" "$*" >&2; }
die()     { err "$*"; exit 1; }

confirm() {
    local prompt="$1" reply
    if [ "$ASSUME_YES" = "1" ]; then return 0; fi
    read -r -p "    ${YELLOW}${prompt} [y/N]${NC} " reply
    case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

prompt() {
    local prompt="$1" var
    read -r -p "    ${YELLOW}${prompt}${NC} " var
    echo "$var"
}

# ---------- Help ----------
usage() {
    cat <<EOF
AMACheck Odoo addon installer (v${SCRIPT_VERSION})

USAGE
    sudo bash install.sh [mode] [options]

MODES (pick one — default is install)
    (none)             Install AMACheck
    --update           Pull the latest AMACheck code and upgrade the module
    --uninstall        Remove AMACheck from the database

OPTIONS
    --instance NAME    Skip the picker, use this Odoo instance directly
    --branch VERSION   Force a specific Odoo branch (e.g. 18.0, 19.0).
                       Default: auto-detect from your Odoo install.
    --no-install       (install mode) Copy files & update config but don't run
                       the module install (you'll click Install in Odoo)
    --remove-files     (uninstall mode) Also delete the addon folder from disk
    --keep-files       (uninstall mode) Keep the addon folder on disk
    --yes              Don't ask for confirmation
    --help             Show this help

INSTALL  detects your Odoo (Docker or systemd), detects the Odoo version,
         downloads the matching addon branch, updates addons_path, and
         installs the module into the database.

UPDATE   reuses the existing addon checkout, runs git pull, and tells Odoo
         to upgrade the module.

UNINSTALL stops Odoo, runs the module's uninstall hook in odoo shell, and
         optionally deletes the addon files.

EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --update)         MODE="update"; shift ;;
        --uninstall)      MODE="uninstall"; shift ;;
        --instance)       INSTANCE_OVERRIDE="$2"; shift 2 ;;
        --instance=*)     INSTANCE_OVERRIDE="${1#*=}"; shift ;;
        --branch)         BRANCH_OVERRIDE="$2"; shift 2 ;;
        --branch=*)       BRANCH_OVERRIDE="${1#*=}"; shift ;;
        --no-install)     SKIP_MODULE_INSTALL=1; shift ;;
        --remove-files)   REMOVE_FILES="yes"; shift ;;
        --keep-files)     REMOVE_FILES="no"; shift ;;
        --yes|-y)         ASSUME_YES=1; shift ;;
        --help|-h)        usage; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

# ---------- Banner ----------
banner() {
    local subtitle
    case "$MODE" in
        install)   subtitle="This will install the AMACheck addon into your Odoo." ;;
        update)    subtitle="This will update AMACheck to the latest release." ;;
        uninstall) subtitle="This will remove AMACheck from your Odoo database." ;;
    esac
    cat <<EOF

${BOLD}${BLUE}╔════════════════════════════════════════════════════════════╗
║            AMACheck for Odoo — Installer                  ║
╚════════════════════════════════════════════════════════════╝${NC}

   ${subtitle}
   You'll be asked to confirm before any changes are made.

EOF
}

# ---------- Pre-flight ----------
preflight() {
    section "Checking your system"

    [ "$(uname -s)" = "Linux" ] || die "This installer only runs on Linux."
    ok "Linux detected ($(uname -r))"

    if [ "$(id -u)" -ne 0 ]; then
        die "Please run with sudo:  sudo bash install.sh"
    fi
    ok "Running as root"

    if ! command -v git >/dev/null 2>&1; then
        warn "git is not installed — will fall back to ZIP download via curl"
        command -v curl >/dev/null 2>&1 || die "Neither git nor curl available. Install one: apt install git"
        command -v unzip >/dev/null 2>&1 || die "unzip is needed for ZIP fallback. Install it: apt install unzip"
    else
        ok "git is available"
    fi
}

# ---------- Instance discovery ----------
# Each instance is described by a colon-separated record:
#   TYPE:NAME:CONFIG_PATH:DB_NAME:HOST_ADDONS_DIR:CONTAINER_ADDONS_DIR
# TYPE is "docker" or "systemd". For systemd, CONTAINER_ADDONS_DIR is empty.
declare -a INSTANCES=()

discover_docker_instances() {
    command -v docker >/dev/null 2>&1 || return 0
    docker info >/dev/null 2>&1 || return 0

    local containers
    containers="$(docker ps --format '{{.Names}}' | grep -i odoo | grep -vi '\-db' || true)"
    [ -z "$containers" ] && return 0

    while IFS= read -r container; do
        [ -z "$container" ] && continue

        # Locate the config file inside the container
        local in_container_conf=""
        for candidate in /etc/odoo/odoo.conf /etc/odoo.conf; do
            if docker exec "$container" test -f "$candidate" 2>/dev/null; then
                in_container_conf="$candidate"; break
            fi
        done
        [ -z "$in_container_conf" ] && { warn "Skipped container $container — no odoo.conf found"; continue; }

        local conf_content; conf_content="$(docker exec "$container" cat "$in_container_conf" 2>/dev/null || true)"
        local db_name addons_paths
        db_name="$(echo "$conf_content" | grep -E '^[[:space:]]*db_name[[:space:]]*=' | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d '\r')"
        addons_paths="$(echo "$conf_content" | grep -E '^[[:space:]]*addons_path[[:space:]]*=' | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d '\r')"

        # Figure out which addons path is mapped to a host volume — that's where we install
        local container_target="" host_target=""
        if [ -n "$addons_paths" ]; then
            local mounts_json; mounts_json="$(docker inspect "$container" --format '{{json .Mounts}}' 2>/dev/null || echo '[]')"
            IFS=',' read -ra paths_arr <<< "$addons_paths"
            for p in "${paths_arr[@]}"; do
                p="$(echo "$p" | xargs)"
                # find a mount whose Destination equals or is a prefix of $p
                local host
                host="$(python3 -c "
import json, sys
mounts = json.loads('''$mounts_json''')
target = '$p'
for m in mounts:
    dest = m.get('Destination', '')
    if dest == target or target.startswith(dest.rstrip('/') + '/'):
        src = m.get('Source', '')
        if dest == target:
            print(src)
        else:
            print(src.rstrip('/') + '/' + target[len(dest.rstrip('/'))+1:])
        break
" 2>/dev/null || true)"
                if [ -n "$host" ] && [ -d "$host" ]; then
                    container_target="$p"; host_target="$host"; break
                fi
            done
        fi

        if [ -z "$host_target" ]; then
            warn "Skipped container $container — no writable host volume found in addons_path"
            continue
        fi

        INSTANCES+=("docker:$container:$in_container_conf:$db_name:$host_target:$container_target")
    done <<< "$containers"
}

discover_systemd_instances() {
    command -v systemctl >/dev/null 2>&1 || return 0

    local units
    units="$(systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null \
        | awk '{print $1}' | grep -E '^odoo[a-z0-9_-]*\.service$' || true)"
    [ -z "$units" ] && return 0

    while IFS= read -r unit; do
        [ -z "$unit" ] && continue

        # Read ExecStart to find the config file
        local execstart conf_path=""
        execstart="$(systemctl cat "$unit" 2>/dev/null | grep -E '^ExecStart=' | head -1 || true)"
        if echo "$execstart" | grep -qE '(-c|--config)[= ][^ ]+'; then
            conf_path="$(echo "$execstart" | sed -E 's/.*(-c|--config)[= ]([^ ]+).*/\2/')"
        fi
        if [ -z "$conf_path" ] || [ ! -f "$conf_path" ]; then
            for candidate in /etc/odoo/odoo.conf /etc/odoo.conf; do
                [ -f "$candidate" ] && { conf_path="$candidate"; break; }
            done
        fi
        [ -z "$conf_path" ] && { warn "Skipped $unit — no odoo.conf found"; continue; }

        local db_name addons_first
        db_name="$(grep -E '^[[:space:]]*db_name[[:space:]]*=' "$conf_path" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d '\r')"
        addons_first="$(grep -E '^[[:space:]]*addons_path[[:space:]]*=' "$conf_path" | head -1 | sed 's/^[^=]*=[[:space:]]*//' | tr -d '\r' | cut -d',' -f1 | xargs)"

        # Pick a writable addons dir — first one in the list that we can write to
        if [ -z "$addons_first" ] || [ ! -d "$addons_first" ]; then
            warn "Skipped $unit — addons_path not found or not a directory"
            continue
        fi

        INSTANCES+=("systemd:$unit:$conf_path:$db_name:$addons_first:")
    done <<< "$units"
}

discover() {
    section "Looking for your Odoo installation"
    discover_docker_instances
    discover_systemd_instances

    if [ ${#INSTANCES[@]} -eq 0 ]; then
        die "No Odoo installation detected. Make sure Odoo is running (Docker or systemd) before running this installer."
    fi

    ok "Found ${#INSTANCES[@]} Odoo instance(s)"
}

# ---------- Instance selection ----------
choose_instance() {
    local chosen_idx=-1

    if [ -n "$INSTANCE_OVERRIDE" ]; then
        for i in "${!INSTANCES[@]}"; do
            IFS=':' read -r typ name _ _ _ _ <<< "${INSTANCES[$i]}"
            if [ "$name" = "$INSTANCE_OVERRIDE" ]; then chosen_idx=$i; break; fi
        done
        [ "$chosen_idx" -lt 0 ] && die "No instance matched --instance '$INSTANCE_OVERRIDE'"
    elif [ ${#INSTANCES[@]} -eq 1 ]; then
        chosen_idx=0
    else
        section "Choose an Odoo instance"
        for i in "${!INSTANCES[@]}"; do
            IFS=':' read -r typ name conf db host_dir _ <<< "${INSTANCES[$i]}"
            printf "    ${BOLD}[%d]${NC} %s ${BLUE}(%s)${NC}\n" "$((i+1))" "$name" "$typ"
            printf "        config:    %s\n" "$conf"
            printf "        database:  %s\n" "${db:-${YELLOW}<not set in config>${NC}}"
            printf "        addons:    %s\n\n" "$host_dir"
        done

        local pick
        while :; do
            pick="$(prompt "Pick instance [1-${#INSTANCES[@]}]:")"
            if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le ${#INSTANCES[@]} ]; then
                chosen_idx=$((pick-1)); break
            fi
            warn "Please enter a number between 1 and ${#INSTANCES[@]}"
        done
    fi

    IFS=':' read -r I_TYPE I_NAME I_CONF I_DB I_HOST_DIR I_CONTAINER_DIR <<< "${INSTANCES[$chosen_idx]}"

    # If no db_name in config, ask
    if [ -z "$I_DB" ]; then
        warn "No db_name set in $I_CONF — the installer needs to know which database to install into."
        I_DB="$(prompt "Database name:")"
        [ -z "$I_DB" ] && die "Database name is required."
    fi

    ok "Selected: $I_NAME ($I_TYPE) → database '$I_DB'"
}

# ---------- Detect Odoo version & pick branch ----------
# Parses the output of `odoo --version`, which looks like "Odoo Server 18.0" or "Odoo Server 19.0+e".
parse_major_version() {
    echo "$1" | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1
}

is_supported_branch() {
    local b="$1"
    for s in "${SUPPORTED_BRANCHES[@]}"; do [ "$s" = "$b" ] && return 0; done
    return 1
}

detect_odoo_version() {
    section "Detecting Odoo version"

    if [ -n "$BRANCH_OVERRIDE" ]; then
        is_supported_branch "$BRANCH_OVERRIDE" || die "Unsupported branch '$BRANCH_OVERRIDE'. Supported: ${SUPPORTED_BRANCHES[*]}"
        BRANCH="$BRANCH_OVERRIDE"
        ODOO_VERSION="${BRANCH%.*}"
        ok "Branch forced via --branch: $BRANCH"
    elif [ "$MODE" = "update" ] && [ -d "$I_HOST_DIR/$MODULE/.git" ]; then
        # In update mode, prefer the branch the existing checkout is already on
        BRANCH="$(cd "$I_HOST_DIR/$MODULE" && git rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
        if [ -n "$BRANCH" ] && is_supported_branch "$BRANCH"; then
            ODOO_VERSION="${BRANCH%.*}"
            ok "Existing checkout is on branch $BRANCH — staying there"
        else
            warn "Existing checkout has unknown branch '$BRANCH' — falling back to Odoo detection"
            BRANCH=""
        fi
    fi

    if [ -z "$BRANCH" ]; then
        local version_out=""
        if [ "$I_TYPE" = "docker" ]; then
            version_out="$(docker exec "$I_NAME" odoo --version 2>/dev/null || true)"
        else
            local exec_path; exec_path="$(systemctl cat "$I_NAME" 2>/dev/null | grep -E '^ExecStart=' | head -1 | sed -E 's/^ExecStart=([^ ]+).*/\1/')"
            [ -z "$exec_path" ] && exec_path="$(command -v odoo || echo /usr/bin/odoo)"
            if [ -x "$exec_path" ]; then
                version_out="$("$exec_path" --version 2>/dev/null || true)"
            fi
        fi

        local major; major="$(parse_major_version "$version_out")"
        if [ -z "$major" ]; then
            warn "Couldn't auto-detect Odoo version (output was: '$version_out')"
            local pick
            while :; do
                pick="$(prompt "Which Odoo version? [18/19]:")"
                case "$pick" in
                    18|18.0) BRANCH="18.0"; ODOO_VERSION="18"; break ;;
                    19|19.0) BRANCH="19.0"; ODOO_VERSION="19"; break ;;
                    *) warn "Enter 18 or 19" ;;
                esac
            done
        else
            ODOO_VERSION="$major"
            BRANCH="${major}.0"
            if ! is_supported_branch "$BRANCH"; then
                die "Detected Odoo $major — but AMACheck only supports versions: ${SUPPORTED_BRANCHES[*]/.0/}"
            fi
            ok "Detected Odoo $major → will install branch $BRANCH"
        fi
    fi

    ZIP_URL="${REPO_WEB}/archive/refs/heads/${BRANCH}.zip"
}

# ---------- Plan & confirm ----------
show_plan() {
    section "What this installer will do"
    info "Mode:             ${BOLD}$MODE${NC}"
    info "Instance:         ${BOLD}$I_NAME${NC} ($I_TYPE)"
    info "Odoo version:     $ODOO_VERSION"
    info "Database:         $I_DB"
    info "Addons directory: $I_HOST_DIR"
    case "$MODE" in
        install)
            info "Module source:    $REPO_URL (branch ${BOLD}$BRANCH${NC})"
            echo
            info "Steps:"
            info "  1. Download $MODULE to $I_HOST_DIR/$MODULE"
            info "  2. Ensure addons_path in $I_CONF includes that directory"
            if [ "$SKIP_MODULE_INSTALL" = "1" ]; then
                info "  3. Restart Odoo"
                info "  4. ${YELLOW}You'll install the module manually via Apps menu${NC}"
            else
                info "  3. Stop Odoo, install the module, start Odoo"
            fi
            ;;
        update)
            info "Module source:    $REPO_URL (branch ${BOLD}$BRANCH${NC})"
            echo
            info "Steps:"
            info "  1. Pull latest code into $I_HOST_DIR/$MODULE"
            info "  2. Stop Odoo, upgrade the module (-u), start Odoo"
            ;;
        uninstall)
            echo
            info "Steps:"
            warn "  This will REMOVE all AMACheck transaction records and configuration"
            info "  1. Stop Odoo, run the module's uninstall hook, start Odoo"
            if [ "$REMOVE_FILES" = "yes" ]; then
                info "  2. Delete $I_HOST_DIR/$MODULE from disk"
            elif [ "$REMOVE_FILES" = "no" ]; then
                info "  2. Leave $I_HOST_DIR/$MODULE on disk"
            else
                info "  2. Ask whether to delete $I_HOST_DIR/$MODULE from disk"
            fi
            ;;
    esac
    echo
    confirm "Proceed?" || die "Cancelled."
}

# ---------- Download code ----------
download_code() {
    section "Downloading AMACheck"
    local target="$I_HOST_DIR/$MODULE"

    if [ -d "$target/.git" ]; then
        info "Existing git checkout found — switching to branch $BRANCH and updating..."
        (cd "$target" && git fetch --quiet origin "$BRANCH" && git checkout --quiet "$BRANCH" && git pull --quiet --ff-only origin "$BRANCH")
        ok "Updated $target to branch $BRANCH"
    elif [ -d "$target" ]; then
        # Non-git folder exists — back it up
        local backup="$target.backup.$(date +%s)"
        warn "Existing non-git folder at $target — moving to $backup"
        mv "$target" "$backup"
        do_fresh_download "$target"
    else
        do_fresh_download "$target"
    fi

    # Make sure the Odoo user (or container) can read it
    if [ "$I_TYPE" = "systemd" ]; then
        local odoo_user
        odoo_user="$(stat -c '%U' "$I_HOST_DIR" 2>/dev/null || echo odoo)"
        chown -R "$odoo_user":"$odoo_user" "$target" 2>/dev/null || true
    fi
}

do_fresh_download() {
    local target="$1"
    if command -v git >/dev/null 2>&1; then
        git clone --quiet -b "$BRANCH" "$REPO_URL" "$target" \
            || die "Couldn't clone branch '$BRANCH' from $REPO_URL — does that branch exist?"
        ok "Cloned branch $BRANCH to $target"
    else
        local tmpdir; tmpdir="$(mktemp -d)"
        curl -fsSL "$ZIP_URL" -o "$tmpdir/src.zip" \
            || { rm -rf "$tmpdir"; die "Couldn't download $ZIP_URL — does branch '$BRANCH' exist?"; }
        unzip -q "$tmpdir/src.zip" -d "$tmpdir"
        mv "$tmpdir/${MODULE}-${BRANCH}" "$target"
        rm -rf "$tmpdir"
        ok "Downloaded branch $BRANCH and extracted to $target"
    fi
}

# ---------- Patch addons_path ----------
patch_addons_path() {
    section "Updating addons_path in $I_CONF"

    # For Docker, the path that goes in the config is the in-container path
    local needed_path
    if [ "$I_TYPE" = "docker" ]; then
        needed_path="$I_CONTAINER_DIR"
        # Read current config from inside container
        if docker exec "$I_NAME" grep -E "^[[:space:]]*addons_path" "$I_CONF" 2>/dev/null | grep -qF "$needed_path"; then
            ok "$needed_path already in addons_path"
            return 0
        fi
        # We need to edit the config file. Look up the host-side path of the conf.
        local host_conf
        host_conf="$(docker inspect "$I_NAME" --format '{{json .Mounts}}' \
            | python3 -c "
import json, sys
mounts = json.load(sys.stdin)
conf = '$I_CONF'
for m in mounts:
    dest = m.get('Destination', '')
    if dest == conf or conf.startswith(dest.rstrip('/') + '/'):
        src = m.get('Source', '')
        if dest == conf:
            print(src)
        else:
            print(src.rstrip('/') + '/' + conf[len(dest.rstrip('/'))+1:])
        break
" 2>/dev/null || true)"
        if [ -z "$host_conf" ] || [ ! -f "$host_conf" ]; then
            warn "Couldn't locate $I_CONF on the host — editing inside the container instead"
            docker exec "$I_NAME" cp "$I_CONF" "$I_CONF.bak.$(date +%s)"
            docker exec "$I_NAME" sed -i -E "s|^([[:space:]]*addons_path[[:space:]]*=.*)$|\1,$needed_path|" "$I_CONF"
        else
            cp "$host_conf" "$host_conf.bak.$(date +%s)"
            if grep -qE '^[[:space:]]*addons_path[[:space:]]*=' "$host_conf"; then
                sed -i -E "s|^([[:space:]]*addons_path[[:space:]]*=.*)$|\1,$needed_path|" "$host_conf"
            else
                echo "addons_path = $needed_path" >> "$host_conf"
            fi
        fi
        ok "Added $needed_path to addons_path (backed up original)"
    else
        # systemd: I_HOST_DIR is the path to add
        needed_path="$I_HOST_DIR"
        if grep -E "^[[:space:]]*addons_path" "$I_CONF" | grep -qF "$needed_path"; then
            ok "$needed_path already in addons_path"
            return 0
        fi
        cp "$I_CONF" "$I_CONF.bak.$(date +%s)"
        if grep -qE '^[[:space:]]*addons_path[[:space:]]*=' "$I_CONF"; then
            sed -i -E "s|^([[:space:]]*addons_path[[:space:]]*=.*)$|\1,$needed_path|" "$I_CONF"
        else
            echo "addons_path = $needed_path" >> "$I_CONF"
        fi
        ok "Added $needed_path to addons_path (backed up original)"
    fi
}

# ---------- Restart / install ----------
restart_odoo() {
    section "Restarting Odoo"
    if [ "$I_TYPE" = "docker" ]; then
        docker restart "$I_NAME" >/dev/null
        ok "Restarted container $I_NAME"
    else
        systemctl restart "$I_NAME"
        ok "Restarted service $I_NAME"
    fi
}

# run_odoo_oneshot <description> <stdin-or-empty> <odoo-args...>
# Stops Odoo, runs `odoo <args>` against the same volumes/network/user, restarts.
# If <stdin> is non-empty, it is piped to odoo's stdin (for `odoo shell` scripts).
run_odoo_oneshot() {
    local desc="$1"; local stdin_data="$2"; shift 2

    if [ "$I_TYPE" = "docker" ]; then
        docker stop "$I_NAME" >/dev/null
        local image; image="$(docker inspect "$I_NAME" --format '{{.Config.Image}}')"
        local network; network="$(docker inspect "$I_NAME" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' | head -1)"
        local net_args=""
        [ -n "$network" ] && net_args="--network=$network"

        local rc=0
        if [ -n "$stdin_data" ]; then
            echo "$stdin_data" | docker run --rm -i --volumes-from "$I_NAME" $net_args "$image" "$@" 2>&1 | tail -25
            rc=${PIPESTATUS[1]}
        else
            docker run --rm --volumes-from "$I_NAME" $net_args "$image" "$@" 2>&1 | tail -25
            rc=${PIPESTATUS[0]}
        fi

        if [ "$rc" -ne 0 ]; then
            docker start "$I_NAME" >/dev/null
            die "$desc failed (exit $rc). Logs above. Odoo has been started back up."
        fi
        docker start "$I_NAME" >/dev/null
    else
        local exec_path; exec_path="$(systemctl cat "$I_NAME" | grep -E '^ExecStart=' | head -1 | sed -E 's/^ExecStart=([^ ]+).*/\1/')"
        local svc_user;  svc_user="$(systemctl cat "$I_NAME" | grep -E '^User=' | head -1 | cut -d= -f2)"
        [ -z "$svc_user" ] && svc_user="odoo"
        [ -z "$exec_path" ] && exec_path="$(command -v odoo || echo /usr/bin/odoo)"

        systemctl stop "$I_NAME"
        local rc=0
        if [ -n "$stdin_data" ]; then
            echo "$stdin_data" | sudo -u "$svc_user" "$exec_path" "$@" || rc=$?
        else
            sudo -u "$svc_user" "$exec_path" "$@" || rc=$?
        fi
        if [ "$rc" -ne 0 ]; then
            systemctl start "$I_NAME"
            die "$desc failed (exit $rc). Logs above. Odoo has been started back up."
        fi
        systemctl start "$I_NAME"
    fi
}

install_module() {
    [ "$SKIP_MODULE_INSTALL" = "1" ] && return 0
    section "Installing the $MODULE module into '$I_DB'"
    info "This may take 30-60 seconds..."
    run_odoo_oneshot "Module install" "" -c "$I_CONF" -d "$I_DB" -i "$MODULE" --stop-after-init --no-http
    ok "Module installed; Odoo restarted"
}

update_module() {
    section "Upgrading the $MODULE module in '$I_DB'"
    info "This may take 30-60 seconds..."
    run_odoo_oneshot "Module upgrade" "" -c "$I_CONF" -d "$I_DB" -u "$MODULE" --stop-after-init --no-http
    ok "Module upgraded; Odoo restarted"
}

uninstall_module() {
    section "Uninstalling the $MODULE module from '$I_DB'"
    info "This may take 15-30 seconds..."

    # Python run inside `odoo shell`. The shell exits when stdin closes.
    local py_script
    py_script="$(cat <<'PYEOF'
m = env["ir.module.module"].search([("name", "=", "account_amacheck")])
if not m:
    print("ABSENT: module not in registry")
elif m.state != "installed":
    print("SKIP: module state is " + m.state)
else:
    m.button_immediate_uninstall()
    env.cr.commit()
    print("UNINSTALLED")
PYEOF
)"
    run_odoo_oneshot "Module uninstall" "$py_script" shell -c "$I_CONF" -d "$I_DB" --no-http
    ok "Module uninstalled; Odoo restarted"
}

remove_addon_files() {
    local target="$I_HOST_DIR/$MODULE"
    [ ! -d "$target" ] && { info "No files to remove at $target"; return 0; }

    local should_remove="$REMOVE_FILES"
    if [ -z "$should_remove" ]; then
        if confirm "Also delete the addon files at $target?"; then
            should_remove="yes"
        else
            should_remove="no"
        fi
    fi

    if [ "$should_remove" = "yes" ]; then
        rm -rf "$target"
        ok "Deleted $target"
    else
        info "Left $target in place"
    fi
}

# ---------- Summary ----------
summary() {
    section "Done!"
    case "$MODE" in
        install)
            cat <<EOF

${GREEN}${BOLD}AMACheck is installed.${NC}

${BOLD}Next steps:${NC}
  1. Open Odoo in your browser
  2. Go to ${BOLD}Settings → AMACheck${NC}
  3. Enter your AMAChecks ${BOLD}License Code${NC}
  4. Click ${BOLD}Refresh Balance${NC} to load your provider settings
  5. Go to ${BOLD}Accounting → Configuration → Journals${NC}, open your bank journal,
     and fill in the ${BOLD}Signer${NC} name under "AMACheck Settings"

Need a license code? Visit ${BLUE}https://www.amachecks.com${NC}

EOF
            if [ "$SKIP_MODULE_INSTALL" = "1" ]; then
                cat <<EOF
${YELLOW}You used --no-install, so you still need to install the module manually:${NC}
  • Settings → Activate Developer Mode
  • Apps → Update Apps List
  • Search "AMACheck" → Install

EOF
            fi
            ;;
        update)
            cat <<EOF

${GREEN}${BOLD}AMACheck has been updated to the latest $BRANCH release.${NC}

If you notice anything missing in the UI, do a hard refresh (Ctrl+Shift+R).

EOF
            ;;
        uninstall)
            cat <<EOF

${GREEN}${BOLD}AMACheck has been removed from '$I_DB'.${NC}

To reinstall later, run this script again without ${BOLD}--uninstall${NC}.

EOF
            ;;
    esac
}

# ---------- Main ----------
main() {
    banner
    preflight
    discover
    choose_instance

    case "$MODE" in
        install)
            detect_odoo_version
            show_plan
            download_code
            patch_addons_path
            if [ "$SKIP_MODULE_INSTALL" = "1" ]; then
                restart_odoo
            else
                install_module
            fi
            ;;
        update)
            if [ ! -d "$I_HOST_DIR/$MODULE/.git" ]; then
                die "No git checkout found at $I_HOST_DIR/$MODULE. Use the installer without --update to do a fresh install."
            fi
            detect_odoo_version
            show_plan
            download_code
            update_module
            ;;
        uninstall)
            detect_odoo_version
            show_plan
            uninstall_module
            remove_addon_files
            ;;
    esac

    summary
}

main "$@"
