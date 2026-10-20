#!/usr/bin/env bash
#
# AMACheck Odoo addon installer
#
# Usage:
#   sudo bash install.sh                    # install (default)
#   sudo bash install.sh --update           # pull latest code & upgrade the module
#   sudo bash install.sh --uninstall        # remove the module from the database
#   sudo bash install.sh --instance NAME    # skip the instance picker
#   sudo bash install.sh --db NAME          # skip the database picker
#   sudo bash install.sh --addons-dir DIR   # put the addon in this (host) folder
#   sudo bash install.sh --branch 19.0      # force a specific Odoo branch
#   sudo bash install.sh --no-install       # set up files only, skip module install
#   sudo bash install.sh --help
#
# Supported deployments:
#   * Docker or Podman — any running container that has an Odoo binary
#     (official odoo:18/19 images, docker compose, custom images)
#   * systemd — any service whose name contains "odoo" or "openerp"
#     (deb/rpm packages, source installs, virtualenvs)
#   * Anything else — use --addons-dir to place the files, then install
#     from Odoo's Apps menu
#
set -euo pipefail

# ---------- Constants ----------
REPO_URL="https://github.com/amachecks/account_amacheck.git"
REPO_WEB="https://github.com/amachecks/account_amacheck"
SUPPORTED_BRANCHES=("18.0" "19.0")
MODULE="account_amacheck"
SCRIPT_VERSION="1.1.0"
LOG_FILE="/var/log/amacheck-installer.log"
BACKUP_DIR="/var/backups/amacheck"
DEFAULT_CUSTOM_ADDONS="/opt/odoo-custom-addons"

BRANCH=""
ZIP_URL=""
ODOO_VERSION=""
LAST_OUTPUT=""

# ---------- Colors ----------
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    BLUE=$'\033[0;34m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; BLUE=""; BOLD=""; NC=""
fi

# ---------- Flags ----------
MODE="install"          # install | update | uninstall
INSTANCE_OVERRIDE=""
BRANCH_OVERRIDE=""
DB_OVERRIDE=""
ADDONS_DIR_OVERRIDE=""
CONFIG_OVERRIDE=""
SKIP_MODULE_INSTALL=0
ASSUME_YES=0
REMOVE_FILES=""         # uninstall: ""=ask, "yes"=delete, "no"=keep
NO_RESTART=0

# ---------- Logging ----------
section() { printf "\n${BOLD}${BLUE}==> %s${NC}\n" "$*"; }
info()    { printf "    %s\n" "$*"; }
ok()      { printf "${GREEN}    ✓ %s${NC}\n" "$*"; }
warn()    { printf "${YELLOW}    ! %s${NC}\n" "$*"; }
err()     { printf "${RED}    ✗ %s${NC}\n" "$*" >&2; }
die()     { err "$*"; exit 1; }

# Read answers from the terminal even when the script itself arrives on stdin
# (e.g. `curl ... | sudo bash`).
TTY_IN=""
if [ -t 0 ]; then
    TTY_IN="/dev/stdin"
elif (: < /dev/tty) 2>/dev/null; then
    TTY_IN="/dev/tty"
fi

confirm() {
    local q="$1" reply
    [ "$ASSUME_YES" = "1" ] && return 0
    [ -n "$TTY_IN" ] || die "No terminal available to answer \"$q\" — re-run with --yes"
    read -r -p "    ${YELLOW}${q} [y/N]${NC} " reply < "$TTY_IN" || return 1
    case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

prompt() {
    local q="$1" var
    [ -n "$TTY_IN" ] || die "No terminal available to answer \"$q\" — pass the value as an option (see --help)"
    read -r -p "    ${YELLOW}${q}${NC} " var < "$TTY_IN" || true
    printf '%s' "$var"
}

# ---------- Help ----------
usage() {
    cat <<EOF
AMACheck Odoo addon installer (v${SCRIPT_VERSION})

USAGE
    sudo bash install.sh [mode] [options]

MODES (pick one — default is install)
    (none)              Install AMACheck
    --update            Pull the latest AMACheck code and upgrade the module
    --uninstall         Remove AMACheck from the database

OPTIONS
    --instance NAME     Use this container / systemd service (skip the picker)
    --db NAME           Use this database (skip the database picker)
    --config PATH       Odoo config file to use (path as Odoo sees it; for
                        Docker that's the path inside the container)
    --addons-dir DIR    Host folder to put the addon in. Must already be in
                        (or will be added to) Odoo's addons_path. For Docker it
                        must be a folder mounted into the container.
    --branch VERSION    Force a specific Odoo branch (18.0 or 19.0).
                        Default: auto-detect from your Odoo install.
    --no-install        (install mode) Copy files & update config only; you'll
                        click Install in Odoo's Apps menu
    --no-restart        Don't restart Odoo at the end (you'll do it yourself)
    --remove-files      (uninstall mode) Also delete the addon folder from disk
    --keep-files        (uninstall mode) Keep the addon folder on disk
    --yes, -y           Don't ask for confirmation
    --help, -h          Show this help

SUPPORTED SETUPS
    Docker / Podman  Any running container with Odoo inside (official image,
                     compose, or custom). The module is installed with
                     'docker exec' into the running container, so it uses the
                     container's own network, hosts entries and DB settings.
    systemd          Any service named *odoo* or *openerp* (packages, source
                     installs, virtualenvs).
    Other            Use --addons-dir DIR --no-install, restart Odoo however
                     you normally do, then install from Apps.

A full log of every run is written to ${LOG_FILE}.
EOF
}

need_arg() { [ $# -ge 2 ] && [ -n "$2" ] || die "Option $1 needs a value (try --help)"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --update)         MODE="update"; shift ;;
        --uninstall)      MODE="uninstall"; shift ;;
        --instance)       need_arg "$@"; INSTANCE_OVERRIDE="$2"; shift 2 ;;
        --instance=*)     INSTANCE_OVERRIDE="${1#*=}"; shift ;;
        --branch)         need_arg "$@"; BRANCH_OVERRIDE="$2"; shift 2 ;;
        --branch=*)       BRANCH_OVERRIDE="${1#*=}"; shift ;;
        --db)             need_arg "$@"; DB_OVERRIDE="$2"; shift 2 ;;
        --db=*)           DB_OVERRIDE="${1#*=}"; shift ;;
        --addons-dir)     need_arg "$@"; ADDONS_DIR_OVERRIDE="$2"; shift 2 ;;
        --addons-dir=*)   ADDONS_DIR_OVERRIDE="${1#*=}"; shift ;;
        --config)         need_arg "$@"; CONFIG_OVERRIDE="$2"; shift 2 ;;
        --config=*)       CONFIG_OVERRIDE="${1#*=}"; shift ;;
        --no-install)     SKIP_MODULE_INSTALL=1; shift ;;
        --no-restart)     NO_RESTART=1; shift ;;
        --remove-files)   REMOVE_FILES="yes"; shift ;;
        --keep-files)     REMOVE_FILES="no"; shift ;;
        --yes|-y)         ASSUME_YES=1; shift ;;
        --help|-h)        usage; exit 0 ;;
        *) die "Unknown option: $1 (try --help)" ;;
    esac
done

# Normalise "19" → "19.0"
case "$BRANCH_OVERRIDE" in [0-9][0-9]) BRANCH_OVERRIDE="${BRANCH_OVERRIDE}.0" ;; esac

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
║             AMACheck for Odoo — Installer v${SCRIPT_VERSION}           ║
╚════════════════════════════════════════════════════════════╝${NC}

   ${subtitle}
   You'll be asked to confirm before any changes are made.

EOF
}

# ---------- Small helpers ----------

# conf_value <config-content> <key>  → value, or empty if unset/False
conf_value() {
    local v
    v="$(printf '%s\n' "$1" | sed -n -E "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" | head -1 | tr -d '\r' | sed -E 's/[[:space:]]+$//')"
    case "$v" in False|false|None|none) v="" ;; esac
    printf '%s' "$v"
}

# split_csv <string> → one trimmed item per line
split_csv() {
    printf '%s' "$1" | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s#/+$##' | sed '/^$/d'
}

# Pull "-c FILE" / "--config FILE" / "--config=FILE" out of a token list (stdin, one per line)
conf_from_tokens() {
    local prev="" t
    while IFS= read -r t; do
        case "$prev" in -c|--config) printf '%s' "$t"; return 0 ;; esac
        case "$t" in
            --config=*) printf '%s' "${t#--config=}"; return 0 ;;
            -c?*)       printf '%s' "${t#-c}"; return 0 ;;
        esac
        prev="$t"
    done
    return 0
}

# Score an addons directory: higher = better place for a third-party module.
addons_score() {
    local p; p="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    local s=0
    case "$p" in *enterprise*) s=$((s-50)) ;; esac
    case "$p" in
        */odoo/addons|*/odoo/addons/*|*dist-packages*|*site-packages*|*/odoo/odoo/addons*|*/openerp/addons*) s=$((s-100)) ;;
    esac
    case "$p" in *extra*|*custom*|*third*|*oca*|*/mnt/*|*client*|*module*) s=$((s+10)) ;; esac
    printf '%s' "$s"
}

# Does this directory contain any Odoo module (other than ours, optionally)?
dir_has_modules() {
    local d="$1" skip="${2:-}" m
    for m in "$d"/*/__manifest__.py "$d"/*/__openerp__.py; do
        [ -f "$m" ] || continue
        [ -n "$skip" ] && [ "$(basename "$(dirname "$m")")" = "$skip" ] && continue
        return 0
    done
    return 1
}

# run_logged <description> <stdin-data-or-empty> <command...>
# Runs a command, captures output into LAST_OUTPUT and appends it to LOG_FILE.
run_logged() {
    local desc="$1" stdin_data="$2"; shift 2
    local out rc=0
    out="$(mktemp)"
    printf '\n===== %s  %s\n$ %s\n' "$(date '+%F %T')" "$desc" "$*" >> "$LOG_FILE" 2>/dev/null || true
    if [ -n "$stdin_data" ]; then
        printf '%s\n' "$stdin_data" | "$@" >"$out" 2>&1 || rc=$?
    else
        "$@" </dev/null >"$out" 2>&1 || rc=$?
    fi
    cat "$out" >> "$LOG_FILE" 2>/dev/null || true
    LAST_OUTPUT="$(cat "$out")"
    rm -f "$out"
    return "$rc"
}

# Explain common Odoo failures in plain language.
diagnose_output() {
    local o="$LAST_OUTPUT"
    if printf '%s' "$o" | grep -q 'could not translate host name'; then
        local h; h="$(printf '%s' "$o" | grep -o 'host name "[^"]*"' | head -1)"
        warn "Odoo can't resolve the database server's $h."
        info "  • Check db_host in $I_CONF (and HOST env var for Docker)."
        info "  • host.docker.internal only works on Linux if the container was created"
        info "    with  --add-host=host.docker.internal:host-gateway  (compose: extra_hosts)."
    fi
    if printf '%s' "$o" | grep -qi 'password authentication failed'; then
        warn "PostgreSQL rejected the username/password — check db_user / db_password in $I_CONF."
    fi
    if printf '%s' "$o" | grep -qi 'Connection refused'; then
        warn "PostgreSQL isn't accepting connections at the configured db_host/db_port."
    fi
    if printf '%s' "$o" | grep -qiE 'database "[^"]*" does not exist|FATAL: +database'; then
        warn "Database '$I_DB' doesn't exist on that server — re-run with --db <name>."
    fi
    if printf '%s' "$o" | grep -qiE 'invalid module names|module .*account_amacheck.* not (found|installable)|No module named .?odoo\.addons\.account_amacheck'; then
        warn "Odoo can't see the addon. Make sure $I_ADDONS_ENTRY is in addons_path of $I_CONF."
    fi
    if printf '%s' "$o" | grep -qiE 'not a valid addons directory|no such directory'; then
        warn "addons_path in $I_CONF lists a folder Odoo can't use (missing, or contains no modules)."
    fi
    if printf '%s' "$o" | grep -qiE 'Address already in use'; then
        warn "A port is already in use — another Odoo process may be running."
    fi
    if printf '%s' "$o" | grep -qiE 'could not obtain lock|lock timeout|deadlock'; then
        warn "The database was busy. Try again in a minute, or stop Odoo first and re-run."
    fi
}

fail_odoo() {
    local desc="$1" rc="${2:-1}"
    err "$desc failed (exit $rc). Last lines of Odoo's output:"
    printf '%s\n' "$LAST_OUTPUT" | tail -25 | sed 's/^/      /' >&2
    echo
    diagnose_output
    info "Full log: $LOG_FILE"
    exit 1
}

# ---------- Pre-flight ----------
DOCKER=""

preflight() {
    section "Checking your system"

    [ "$(uname -s)" = "Linux" ] || die "This installer only runs on Linux (run it on the Odoo server itself)."
    ok "Linux detected ($(uname -r))"

    [ "$(id -u)" -eq 0 ] || die "Please run with sudo:  sudo bash install.sh"
    ok "Running as root"

    touch "$LOG_FILE" 2>/dev/null || LOG_FILE="$(mktemp /tmp/amacheck-installer.XXXXXX.log)"
    printf '\n\n########## AMACheck installer v%s — %s — mode=%s\n' "$SCRIPT_VERSION" "$(date '+%F %T')" "$MODE" >> "$LOG_FILE"

    if command -v git >/dev/null 2>&1; then
        ok "git is available"
    else
        warn "git is not installed — will fall back to ZIP download"
        command -v curl  >/dev/null 2>&1 || die "Need git or curl. Install one:  apt install git   (or yum/dnf install git)"
        command -v unzip >/dev/null 2>&1 || die "unzip is needed for the ZIP fallback:  apt install unzip"
    fi

    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        DOCKER="docker"
    elif command -v podman >/dev/null 2>&1; then
        DOCKER="podman"
    fi
    [ -n "$DOCKER" ] && ok "$DOCKER is available"
    return 0
}

# ---------- Instance discovery ----------
# Parallel arrays, one entry per instance found.
declare -a INST_TYPE=() INST_NAME=() INST_CONF=() INST_DB=() INST_BIN=() INST_USER=() INST_WD=() INST_ENV=()
US=$'\x1f'   # separator for multi-token fields

add_instance() {
    INST_TYPE+=("$1"); INST_NAME+=("$2"); INST_CONF+=("$3"); INST_DB+=("$4")
    INST_BIN+=("$5"); INST_USER+=("$6"); INST_WD+=("$7"); INST_ENV+=("$8")
}

container_env() {   # container_env <container> <VAR>
    "$DOCKER" inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | sed -n "s/^$2=//p" | head -1
}

find_container_odoo_bin() {
    "$DOCKER" exec "$1" sh -c '
        for b in odoo odoo-bin openerp-server; do
            p=$(command -v "$b" 2>/dev/null) && { echo "$p"; exit 0; }
        done
        for p in /opt/odoo/odoo-bin /opt/odoo/odoo/odoo-bin /odoo/odoo-bin /usr/src/odoo/odoo-bin \
                 /home/odoo/odoo/odoo-bin /opt/odoo/server/odoo-bin /opt/odoo/src/odoo/odoo-bin; do
            if [ -f "$p" ]; then
                if [ -x "$p" ]; then echo "$p"; else echo "python3 $p"; fi
                exit 0
            fi
        done
        exit 1' 2>/dev/null
}

find_container_conf() {
    local c="$1" from_args env_rc f
    from_args="$("$DOCKER" inspect "$c" --format '{{.Path}}{{"\n"}}{{range .Args}}{{.}}{{"\n"}}{{end}}' 2>/dev/null \
        | tr ' ' '\n' | conf_from_tokens || true)"
    env_rc="$(container_env "$c" ODOO_RC)"
    for f in "$from_args" "$env_rc" /etc/odoo/odoo.conf /etc/odoo.conf /etc/odoo/odoo-server.conf \
             /etc/odoo/openerp-server.conf /opt/odoo/odoo.conf /opt/odoo/config/odoo.conf /opt/odoo/etc/odoo.conf; do
        [ -n "$f" ] || continue
        if "$DOCKER" exec "$c" test -f "$f" 2>/dev/null; then printf '%s' "$f"; return 0; fi
    done
    return 1
}

discover_docker_instances() {
    [ -n "$DOCKER" ] || return 0
    local name image lname limage bin conf content
    while IFS='|' read -r name image; do
        [ -n "$name" ] || continue
        lname="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')"
        limage="$(printf '%s' "$image" | tr '[:upper:]' '[:lower:]')"
        # Skip obvious infrastructure containers quickly
        case "$limage" in *postgres*|*postgis*|*pgbouncer*|*pgadmin*|*redis*|*nginx*|*traefik*|*caddy*|*certbot*|*mariadb*|*mysql*) continue ;; esac
        case "$lname"  in *-db|*_db|*-db-*|*_db_*|*postgres*) continue ;; esac

        bin="$(find_container_odoo_bin "$name" || true)"
        [ -n "$bin" ] || continue

        conf="$(find_container_conf "$name" || true)"
        if [ -z "$conf" ]; then
            warn "Container $name has Odoo but no config file I recognise — use --config PATH"
            [ -n "$CONFIG_OVERRIDE" ] && [ "$INSTANCE_OVERRIDE" = "$name" ] || continue
            conf="$CONFIG_OVERRIDE"
        fi
        content="$("$DOCKER" exec "$name" cat "$conf" 2>/dev/null || true)"
        add_instance docker "$name" "$conf" "$(conf_value "$content" db_name)" "${bin// /$US}" "" "" ""
    done < <("$DOCKER" ps --format '{{.Names}}|{{.Image}}' 2>/dev/null || true)

    # Friendly hint for stopped Odoo containers
    local stopped
    stopped="$("$DOCKER" ps -a --filter status=exited --filter status=created --format '{{.Names}}' 2>/dev/null | grep -i -E 'odoo|erp' || true)"
    if [ -n "$stopped" ]; then
        warn "These Odoo-looking containers are stopped and were skipped: $(echo $stopped)"
        info "  Start the one you want (e.g. '$DOCKER start <name>') and re-run the installer."
    fi
}

discover_systemd_instances() {
    command -v systemctl >/dev/null 2>&1 || return 0
    local units unit
    units="$( { systemctl list-units --type=service --all --no-legend --plain --no-pager 2>/dev/null | awk '{print $1}'
                systemctl list-unit-files --type=service --no-legend --no-pager 2>/dev/null | awk '{print $1}'; } \
              | grep -iE '(odoo|openerp)' | grep -v '@\.service$' | sort -u || true)"
    [ -n "$units" ] || return 0

    while IFS= read -r unit; do
        [ -n "$unit" ] || continue
        [ "$(systemctl show -p LoadState --value "$unit" 2>/dev/null)" = "loaded" ] || continue

        local argv; argv="$(systemctl show -p ExecStart --value "$unit" 2>/dev/null \
            | sed -n 's/.*argv\[\]=\([^;]*\);.*/\1/p' | head -1)"
        local -a toks=(); read -ra toks <<< "$argv"

        # Find the odoo executable in the command line; everything up to it is
        # the "launcher" (e.g. /opt/odoo/venv/bin/python3 /opt/odoo/odoo-bin).
        local idx=-1 i b
        for i in "${!toks[@]}"; do
            b="$(basename "${toks[$i]}")"
            case "$b" in odoo|odoo-bin|odoo-bin.py|odoo.py|openerp-server|odoo-server) idx=$i; break ;; esac
        done
        local -a prefix=()
        if [ "$idx" -ge 0 ]; then
            prefix=("${toks[@]:0:$((idx+1))}")
        else
            local guess; guess="$(command -v odoo || command -v odoo-bin || true)"
            if [ -n "$guess" ]; then
                prefix=("$guess")
                warn "$unit: couldn't read the Odoo command from ExecStart — assuming $guess"
            else
                warn "Skipped $unit — couldn't work out how it starts Odoo (ExecStart: ${argv:-<unknown>})"
                continue
            fi
        fi

        local env_str; env_str="$(systemctl show -p Environment --value "$unit" 2>/dev/null || true)"
        local conf=""
        if [ "$idx" -ge 0 ]; then
            conf="$(printf '%s\n' "${toks[@]:$((idx+1))}" | conf_from_tokens || true)"
        fi
        if [ -z "$conf" ]; then
            conf="$(printf '%s' "$env_str" | tr ' ' '\n' | sed -n 's/^ODOO_RC=//p' | head -1)"
        fi
        if [ -z "$conf" ] || [ ! -f "$conf" ]; then
            local f; conf=""
            for f in /etc/odoo/odoo.conf /etc/odoo.conf /etc/odoo/odoo-server.conf /etc/odoo-server.conf \
                     /etc/odoo/openerp-server.conf /opt/odoo/odoo.conf /opt/odoo/config/odoo.conf; do
                [ -f "$f" ] && { conf="$f"; break; }
            done
        fi
        if [ -z "$conf" ]; then
            warn "Skipped $unit — no config file found (use --instance $unit --config PATH)"
            [ -n "$CONFIG_OVERRIDE" ] && [ "$INSTANCE_OVERRIDE" = "$unit" ] || continue
            conf="$CONFIG_OVERRIDE"
        fi

        local user; user="$(systemctl show -p User --value "$unit" 2>/dev/null || true)"
        [ -n "$user" ] || user="root"
        local wd; wd="$(systemctl show -p WorkingDirectory --value "$unit" 2>/dev/null | sed 's/^!//' || true)"

        local db=""; [ -r "$conf" ] && db="$(conf_value "$(cat "$conf")" db_name)"
        local joined; joined="$(IFS="$US"; printf '%s' "${prefix[*]}")"
        local envj;   envj="$(printf '%s' "$env_str" | tr ' ' "$US")"
        add_instance systemd "$unit" "$conf" "$db" "$joined" "$user" "$wd" "$envj"
    done <<< "$units"
}

discover() {
    section "Looking for your Odoo installation"
    discover_docker_instances
    discover_systemd_instances

    if [ ${#INST_NAME[@]} -eq 0 ]; then
        if [ -n "$ADDONS_DIR_OVERRIDE" ]; then
            warn "No Docker container or systemd service running Odoo was found."
            info "Continuing in files-only mode: the addon will be placed in $ADDONS_DIR_OVERRIDE"
            return 1
        fi
        err "No Odoo installation detected."
        info "I look for:"
        info "  • running Docker/Podman containers that have an Odoo binary inside"
        info "  • systemd services whose name contains 'odoo' or 'openerp'"
        info "If Odoo runs some other way (supervisor, screen, a hosting panel), run:"
        info "  sudo bash install.sh --addons-dir /path/to/your/custom/addons"
        info "then restart Odoo and install AMACheck from the Apps menu."
        info "Odoo.sh / Odoo Online can't use this installer — see INSTALL.md."
        exit 1
    fi
    ok "Found ${#INST_NAME[@]} Odoo instance(s)"
    return 0
}

# ---------- Instance selection ----------
I_TYPE=""; I_NAME=""; I_CONF=""; I_DB=""; I_USER=""; I_WD=""
declare -a I_BIN=() I_ENV=() DB_ENV=()

choose_instance() {
    local chosen=-1 i n=${#INST_NAME[@]}

    if [ -n "$INSTANCE_OVERRIDE" ]; then
        for i in "${!INST_NAME[@]}"; do
            [ "${INST_NAME[$i]}" = "$INSTANCE_OVERRIDE" ] || [ "${INST_NAME[$i]}" = "${INSTANCE_OVERRIDE}.service" ] && { chosen=$i; break; }
        done
        [ "$chosen" -ge 0 ] || die "No instance matched --instance '$INSTANCE_OVERRIDE' (found: ${INST_NAME[*]})"
    elif [ "$n" -eq 1 ]; then
        chosen=0
    else
        section "Choose an Odoo instance"
        for i in "${!INST_NAME[@]}"; do
            printf "    ${BOLD}[%d]${NC} %s ${BLUE}(%s)${NC}\n" "$((i+1))" "${INST_NAME[$i]}" "${INST_TYPE[$i]}"
            printf "        config:    %s\n" "${INST_CONF[$i]}"
            printf "        database:  %s\n\n" "${INST_DB[$i]:-<not set in config, you will pick one>}"
        done
        local pick
        while :; do
            pick="$(prompt "Pick instance [1-$n]:")"
            if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "$n" ]; then
                chosen=$((pick-1)); break
            fi
            warn "Please enter a number between 1 and $n"
        done
    fi

    I_TYPE="${INST_TYPE[$chosen]}"; I_NAME="${INST_NAME[$chosen]}"; I_CONF="${INST_CONF[$chosen]}"
    I_DB="${INST_DB[$chosen]}"; I_USER="${INST_USER[$chosen]}"; I_WD="${INST_WD[$chosen]}"
    IFS="$US" read -ra I_BIN <<< "${INST_BIN[$chosen]}"
    I_ENV=()
    [ -n "${INST_ENV[$chosen]}" ] && IFS="$US" read -ra I_ENV <<< "${INST_ENV[$chosen]}"

    if [ -n "$CONFIG_OVERRIDE" ]; then
        I_CONF="$CONFIG_OVERRIDE"
        I_DB="$(conf_value "$(read_conf)" db_name)"
    fi
    [ -n "$(read_conf)" ] || die "Couldn't read Odoo config $I_CONF"

    [ "$I_TYPE" = "docker" ] && build_docker_db_env
    ok "Selected: $I_NAME ($I_TYPE), config $I_CONF"
}

# Read the Odoo config file content (wherever it lives)
read_conf() {
    if [ "$I_TYPE" = "docker" ]; then
        "$DOCKER" exec "$I_NAME" cat "$I_CONF" 2>/dev/null || true
    else
        cat "$I_CONF" 2>/dev/null || true
    fi
}

# Odoo's official Docker image passes DB settings from HOST/PORT/USER/PASSWORD
# env vars on the command line (via its entrypoint). 'docker exec' bypasses the
# entrypoint, so we hand the same values to libpq as PG* env vars. Values set in
# odoo.conf still take precedence, exactly as with the entrypoint.
build_docker_db_env() {
    DB_ENV=()
    local content; content="$(read_conf)"
    local has_ep=0
    "$DOCKER" exec "$I_NAME" test -f /entrypoint.sh 2>/dev/null && has_ep=1

    local v
    v="$(conf_value "$content" db_host)"
    [ -n "$v" ] || v="$(container_env "$I_NAME" HOST)"
    [ -n "$v" ] || v="$(container_env "$I_NAME" DB_PORT_5432_TCP_ADDR)"
    [ -n "$v" ] || { [ "$has_ep" = 1 ] && v="db"; } || true
    [ -n "$v" ] && DB_ENV+=(-e "PGHOST=$v")

    v="$(conf_value "$content" db_port)"
    [ -n "$v" ] || v="$(container_env "$I_NAME" PORT)"
    [ -n "$v" ] && DB_ENV+=(-e "PGPORT=$v")

    v="$(conf_value "$content" db_user)"
    [ -n "$v" ] || v="$(container_env "$I_NAME" USER)"
    [ -n "$v" ] || v="$(container_env "$I_NAME" POSTGRES_USER)"
    [ -n "$v" ] || { [ "$has_ep" = 1 ] && v="odoo"; } || true
    [ -n "$v" ] && DB_ENV+=(-e "PGUSER=$v")

    v="$(conf_value "$content" db_password)"
    [ -n "$v" ] || v="$(container_env "$I_NAME" PASSWORD)"
    [ -n "$v" ] || v="$(container_env "$I_NAME" POSTGRES_PASSWORD)"
    [ -n "$v" ] || { [ "$has_ep" = 1 ] && v="odoo"; } || true
    [ -n "$v" ] && DB_ENV+=(-e "PGPASSWORD=$v")
    return 0
}

# Build the command that runs something as Odoo would (inside the container,
# or as the service user with the service's launcher). Result in RUN_CMD.
declare -a RUN_CMD=()
build_run_cmd() {   # build_run_cmd <interactive 0|1> <program...>
    local interactive="$1"; shift
    RUN_CMD=()
    if [ "$I_TYPE" = "docker" ]; then
        RUN_CMD=("$DOCKER" exec)
        [ "$interactive" = 1 ] && RUN_CMD+=(-i)
        RUN_CMD+=(${DB_ENV[@]+"${DB_ENV[@]}"} "$I_NAME" "$@")
    else
        if [ "$I_USER" != "root" ]; then
            if command -v runuser >/dev/null 2>&1; then RUN_CMD=(runuser -u "$I_USER" --)
            else RUN_CMD=(sudo -H -u "$I_USER" --); fi
        fi
        RUN_CMD+=(env ${I_ENV[@]+"${I_ENV[@]}"})
        if [ -n "$I_WD" ] && [ -d "$I_WD" ]; then
            RUN_CMD+=(sh -c 'cd "$1" && shift && exec "$@"' sh "$I_WD")
        fi
        RUN_CMD+=("$@")
    fi
}

run_odoo() {   # run_odoo <desc> <stdin-or-empty> <odoo args...>
    local desc="$1" stdin_data="$2"; shift 2
    local inter=0; [ -n "$stdin_data" ] && inter=1
    build_run_cmd "$inter" "${I_BIN[@]}" "$@"
    run_logged "$desc" "$stdin_data" "${RUN_CMD[@]}"
}

# ---------- Database selection ----------
list_databases() {
    local sql="SELECT datname FROM pg_database WHERE NOT datistemplate AND datname <> 'postgres' ORDER BY 1"
    local content; content="$(read_conf)"
    local d out=""
    for d in postgres template1; do
        if [ "$I_TYPE" = "docker" ]; then
            "$DOCKER" exec "$I_NAME" sh -c 'command -v psql' >/dev/null 2>&1 || return 0
            out="$("$DOCKER" exec ${DB_ENV[@]+"${DB_ENV[@]}"} "$I_NAME" psql -At -d "$d" -c "$sql" 2>/dev/null || true)"
        else
            command -v psql >/dev/null 2>&1 || return 0
            local -a pg=()
            local v
            v="$(conf_value "$content" db_host)";     [ -n "$v" ] && pg+=("PGHOST=$v")
            v="$(conf_value "$content" db_port)";     [ -n "$v" ] && pg+=("PGPORT=$v")
            v="$(conf_value "$content" db_user)";     [ -n "$v" ] && pg+=("PGUSER=$v")
            v="$(conf_value "$content" db_password)"; [ -n "$v" ] && pg+=("PGPASSWORD=$v")
            build_run_cmd 0 env ${pg[@]+"${pg[@]}"} psql -At -d "$d" -c "$sql"
            out="$(cd / && "${RUN_CMD[@]}" 2>/dev/null || true)"
        fi
        [ -n "$out" ] && { printf '%s\n' "$out"; return 0; }
    done
    return 0
}

choose_database() {
    if [ -n "$DB_OVERRIDE" ]; then
        I_DB="$DB_OVERRIDE"
    else
        local -a dbs=()
        if [ -n "$I_DB" ]; then
            mapfile -t dbs < <(split_csv "$I_DB")
        else
            mapfile -t dbs < <(list_databases)
        fi

        if [ ${#dbs[@]} -eq 1 ]; then
            I_DB="${dbs[0]}"
        elif [ ${#dbs[@]} -gt 1 ]; then
            section "Choose a database"
            local i; for i in "${!dbs[@]}"; do printf "    ${BOLD}[%d]${NC} %s\n" "$((i+1))" "${dbs[$i]}"; done
            echo
            local pick
            while :; do
                pick="$(prompt "Install into which database? [1-${#dbs[@]}]:")"
                if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le ${#dbs[@]} ]; then
                    I_DB="${dbs[$((pick-1))]}"; break
                fi
                warn "Please enter a number between 1 and ${#dbs[@]}"
            done
        else
            warn "No db_name in $I_CONF and I couldn't list the databases."
            I_DB="$(prompt "Database name:")"
        fi
    fi
    [ -n "$I_DB" ] || die "A database name is required (use --db NAME)."
    ok "Database: $I_DB"
}

# ---------- Addons directory ----------
# I_HOST_DIR     — folder on this machine that will contain $MODULE
# I_ADDONS_ENTRY — the same folder as Odoo sees it (what goes in addons_path)
# I_NEEDS_PATH   — 1 if I_ADDONS_ENTRY must be added to addons_path
I_HOST_DIR=""; I_ADDONS_ENTRY=""; I_NEEDS_PATH=0
MOUNTS=""

load_mounts() {
    MOUNTS="$("$DOCKER" inspect "$I_NAME" --format '{{range .Mounts}}{{.Source}}|{{.Destination}}{{println}}{{end}}' 2>/dev/null || true)"
}

map_to_host() {   # container path → host path (longest matching mount)
    local p="${1%/}" src dst best_src="" best_dst="" found=0
    while IFS='|' read -r src dst; do
        [ -n "$dst" ] || continue
        dst="${dst%/}"
        if [ "$p" = "$dst" ] || [[ "$p" == "$dst"/* ]]; then
            if [ "$found" = 0 ] || [ ${#dst} -gt ${#best_dst} ]; then best_src="$src"; best_dst="$dst"; found=1; fi
        fi
    done <<< "$MOUNTS"
    [ "$found" = 1 ] || return 1
    printf '%s' "${best_src%/}${p#$best_dst}"
}

map_to_container() {   # host path → container path
    local p; p="$(readlink -f "$1" 2>/dev/null || printf '%s' "${1%/}")"
    local src dst rsrc best_src="" best_dst="" found=0
    while IFS='|' read -r src dst; do
        [ -n "$src" ] || continue
        rsrc="$(readlink -f "$src" 2>/dev/null || printf '%s' "${src%/}")"
        if [ "$p" = "$rsrc" ] || [[ "$p" == "$rsrc"/* ]]; then
            if [ "$found" = 0 ] || [ ${#rsrc} -gt ${#best_src} ]; then best_src="$rsrc"; best_dst="${dst%/}"; found=1; fi
        fi
    done <<< "$MOUNTS"
    [ "$found" = 1 ] || return 1
    printf '%s' "${best_dst}${p#$best_src}"
}

resolve_addons_dir() {
    section "Choosing where to put the addon"
    local content; content="$(read_conf)"
    local addons; addons="$(conf_value "$content" addons_path)"
    local -a entries=(); mapfile -t entries < <(split_csv "$addons")

    # Candidate lists: odoo-side path, host path, in-config flag
    local -a C_ODOO=() C_HOST=() C_IN=()
    local e h

    if [ "$I_TYPE" = "docker" ]; then
        load_mounts
        for e in ${entries[@]+"${entries[@]}"}; do
            if h="$(map_to_host "$e")" && [ -d "$h" ]; then
                C_ODOO+=("$e"); C_HOST+=("$h"); C_IN+=(1)
            elif "$DOCKER" exec "$I_NAME" test -f "$e/$MODULE/__manifest__.py" 2>/dev/null; then
                warn "AMACheck is baked into the container image at $e/$MODULE — this installer can't change files there."
            fi
        done
        # Mounted folders that look like addons dirs but aren't in addons_path yet
        local src dst
        while IFS='|' read -r src dst; do
            [ -n "$dst" ] || continue
            dst="${dst%/}"
            case "$dst" in *addons*) ;; *) continue ;; esac
            printf '%s\n' ${C_ODOO[@]+"${C_ODOO[@]}"} | grep -qxF "$dst" && continue
            [ -d "$src" ] || continue
            C_ODOO+=("$dst"); C_HOST+=("${src%/}"); C_IN+=(0)
        done <<< "$MOUNTS"
    else
        for e in ${entries[@]+"${entries[@]}"}; do
            [ -d "$e" ] && { C_ODOO+=("$e"); C_HOST+=("$e"); C_IN+=(1); }
        done
    fi

    local chosen=-1 i

    # 1) Explicit --addons-dir
    if [ -n "$ADDONS_DIR_OVERRIDE" ]; then
        local want; want="$(readlink -f "$ADDONS_DIR_OVERRIDE" 2>/dev/null || printf '%s' "$ADDONS_DIR_OVERRIDE")"
        for i in "${!C_HOST[@]}"; do
            [ "$(readlink -f "${C_HOST[$i]}" 2>/dev/null)" = "$want" ] && { chosen=$i; break; }
        done
        if [ "$chosen" -lt 0 ]; then
            [ -d "$want" ] || mkdir -p "$want"
            if [ "$I_TYPE" = "docker" ]; then
                local cp; cp="$(map_to_container "$want")" \
                    || die "$want isn't mounted into container $I_NAME, so Odoo can't see it. Pick a mounted folder or add a volume."
                C_ODOO+=("$cp")
            else
                C_ODOO+=("$want")
            fi
            C_HOST+=("$want"); C_IN+=(0); chosen=$((${#C_HOST[@]}-1))
        fi
    fi

    # 2) Wherever AMACheck already lives (avoid creating a duplicate copy)
    if [ "$chosen" -lt 0 ]; then
        local -a existing=()
        for i in "${!C_HOST[@]}"; do
            [ -f "${C_HOST[$i]}/$MODULE/__manifest__.py" ] && existing+=("$i")
        done
        if [ ${#existing[@]} -gt 0 ]; then
            chosen="${existing[0]}"
            if [ ${#existing[@]} -gt 1 ]; then
                warn "AMACheck exists in more than one addons folder — Odoo only loads the first:"
                for i in "${existing[@]}"; do info "    ${C_HOST[$i]}/$MODULE"; done
                warn "Using the first one. Consider deleting the others."
            fi
            ok "Found existing AMACheck at ${C_HOST[$chosen]}/$MODULE"
        fi
    fi

    [ "$MODE" = "update" ] && [ "$chosen" -lt 0 ] && \
        die "AMACheck isn't installed in any addons folder of $I_NAME. Run the installer without --update first."

    # 3) The best-looking custom addons folder
    if [ "$chosen" -lt 0 ] && [ ${#C_HOST[@]} -gt 0 ]; then
        local best_score=-99999 s
        for i in "${!C_HOST[@]}"; do
            s="$(addons_score "${C_ODOO[$i]}")"
            [ "${C_IN[$i]}" = 1 ] && s=$((s+5))
            if [ "$s" -gt "$best_score" ]; then best_score=$s; chosen=$i; fi
        done
        if [ "$best_score" -lt 0 ]; then
            if [ "$I_TYPE" = "systemd" ]; then
                chosen=-1   # don't drop third-party code into Odoo core; create a folder below
            else
                warn "The only addons folders mounted into $I_NAME are Odoo core/enterprise folders."
                warn "Installing into ${C_HOST[$chosen]} — it works, but a dedicated custom-addons"
                warn "volume (e.g. -v /opt/odoo/extra-addons:/mnt/extra-addons) is cleaner."
            fi
        fi
    fi

    # 4) Nothing suitable
    if [ "$chosen" -lt 0 ]; then
        if [ "$I_TYPE" = "docker" ]; then
            err "Container $I_NAME has no addons folder mounted from this server, so there's"
            err "nowhere to put AMACheck that Odoo can see."
            info "Add a volume for custom addons and recreate the container, for example:"
            info "  docker run ... -v /opt/odoo/extra-addons:/mnt/extra-addons ..."
            info "  (compose: volumes: - ./extra-addons:/mnt/extra-addons)"
            info "Make sure /mnt/extra-addons is in addons_path, then re-run this installer."
            exit 1
        fi
        mkdir -p "$DEFAULT_CUSTOM_ADDONS"
        chown "$I_USER": "$DEFAULT_CUSTOM_ADDONS" 2>/dev/null || true
        C_ODOO+=("$DEFAULT_CUSTOM_ADDONS"); C_HOST+=("$DEFAULT_CUSTOM_ADDONS"); C_IN+=(0)
        chosen=$((${#C_HOST[@]}-1))
        info "Will create a dedicated custom addons folder: $DEFAULT_CUSTOM_ADDONS"
    fi

    I_HOST_DIR="${C_HOST[$chosen]}"
    I_ADDONS_ENTRY="${C_ODOO[$chosen]}"
    I_NEEDS_PATH=$(( 1 - ${C_IN[$chosen]} ))
    ok "Addon folder: $I_HOST_DIR$( [ "$I_TYPE" = docker ] && printf ' (inside container: %s)' "$I_ADDONS_ENTRY")"
}

# ---------- Detect Odoo version & pick branch ----------
parse_major_version() {
    printf '%s\n' "$1" | grep -iE 'odoo|server|^[0-9s]' | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f1
}

is_supported_branch() {
    local b="$1" s
    for s in "${SUPPORTED_BRANCHES[@]}"; do [ "$s" = "$b" ] && return 0; done
    return 1
}

detect_odoo_version() {
    section "Detecting Odoo version"

    if [ -n "$BRANCH_OVERRIDE" ]; then
        is_supported_branch "$BRANCH_OVERRIDE" || die "Unsupported branch '$BRANCH_OVERRIDE'. Supported: ${SUPPORTED_BRANCHES[*]}"
        BRANCH="$BRANCH_OVERRIDE"
        ok "Branch forced via --branch: $BRANCH"
    else
        local out="" major=""
        if [ -n "$I_TYPE" ]; then
            if run_odoo "Odoo version" "" --version; then out="$LAST_OUTPUT"; fi
            major="$(parse_major_version "$out")"

            if [ -z "$major" ] && [ "$I_TYPE" = "docker" ]; then
                local image; image="$("$DOCKER" inspect "$I_NAME" --format '{{.Config.Image}}' 2>/dev/null || true)"
                major="$(printf '%s' "${image##*:}" | grep -oE '^[0-9]+' || true)"
            fi
            if [ -z "$major" ] && [ "$I_TYPE" = "systemd" ]; then
                # Ask Python directly (works for venv/source installs)
                local last="${I_BIN[${#I_BIN[@]}-1]}" py="python3"
                [ ${#I_BIN[@]} -gt 1 ] && py="${I_BIN[0]}"
                build_run_cmd 0 "$py" -c 'import sys,os; sys.path.insert(0, os.path.dirname(os.path.realpath(sys.argv[1]))); import odoo.release as r; print("Odoo", r.version)' "$last"
                out="$("${RUN_CMD[@]}" 2>/dev/null || true)"
                major="$(parse_major_version "$out")"
            fi
        fi

        if [ -z "$major" ]; then
            # Fall back to the branch of an existing checkout
            if [ -d "$I_HOST_DIR/$MODULE/.git" ]; then
                local cur; cur="$(git -c safe.directory='*' -C "$I_HOST_DIR/$MODULE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
                is_supported_branch "$cur" && major="${cur%.*}"
            fi
        fi

        if [ -z "$major" ]; then
            warn "Couldn't auto-detect your Odoo version."
            local pick
            while :; do
                pick="$(prompt "Which Odoo version are you running? [18/19]:")"
                case "$pick" in
                    18|18.0) major=18; break ;;
                    19|19.0) major=19; break ;;
                    *) warn "Enter 18 or 19" ;;
                esac
            done
        fi

        BRANCH="${major}.0"
        is_supported_branch "$BRANCH" || die "Detected Odoo $major — AMACheck supports Odoo ${SUPPORTED_BRANCHES[*]}. Contact support@amachecks.com."
        ok "Odoo $major → AMACheck branch $BRANCH"
    fi
    ODOO_VERSION="${BRANCH%.*}"
    ZIP_URL="${REPO_WEB}/archive/refs/heads/${BRANCH}.zip"
}

# ---------- Plan & confirm ----------
show_plan() {
    section "What this installer will do"
    info "Mode:             ${BOLD}$MODE${NC}"
    if [ -n "$I_TYPE" ]; then
        info "Instance:         ${BOLD}$I_NAME${NC} ($I_TYPE)"
        info "Config:           $I_CONF"
        info "Database:         $I_DB"
    fi
    [ -n "$ODOO_VERSION" ] && info "Odoo version:     $ODOO_VERSION"
    info "Addon folder:     $I_HOST_DIR/$MODULE"
    echo
    info "Steps:"
    local n=1
    case "$MODE" in
        install|update)
            info "  $n. Download $MODULE (branch $BRANCH) from GitHub"; n=$((n+1))
            [ "$I_NEEDS_PATH" = 1 ] && { info "  $n. Add $I_ADDONS_ENTRY to addons_path in $I_CONF (backup kept)"; n=$((n+1)); }
            if [ -z "$I_TYPE" ]; then
                info "  $n. ${YELLOW}You restart Odoo and install AMACheck from the Apps menu${NC}"
            elif [ "$MODE" = "install" ] && [ "$SKIP_MODULE_INSTALL" = "1" ]; then
                info "  $n. Restart Odoo"; n=$((n+1))
                info "  $n. ${YELLOW}You install the module from the Apps menu${NC}"
            else
                local verb="Install"; [ "$MODE" = "update" ] && verb="Upgrade"
                if [ "$I_TYPE" = "docker" ]; then
                    info "  $n. $verb the module inside the running container (docker exec)"; n=$((n+1))
                    [ "$NO_RESTART" = 1 ] || info "  $n. Restart container $I_NAME"
                else
                    info "  $n. Stop $I_NAME, $(printf '%s' "$verb" | tr '[:upper:]' '[:lower:]') the module, start $I_NAME"
                fi
            fi
            ;;
        uninstall)
            warn "  This REMOVES all AMACheck transaction records and settings from '$I_DB'"
            info "  $n. Uninstall the module from the database, restart Odoo"; n=$((n+1))
            case "$REMOVE_FILES" in
                yes) info "  $n. Delete $I_HOST_DIR/$MODULE (a backup is kept in $BACKUP_DIR)" ;;
                no)  info "  $n. Leave $I_HOST_DIR/$MODULE on disk" ;;
                *)   info "  $n. Ask whether to delete $I_HOST_DIR/$MODULE" ;;
            esac
            ;;
    esac
    echo
    confirm "Proceed?" || die "Cancelled — nothing was changed."
}

# ---------- Download code ----------
backup_folder() {   # backup_folder <dir>  → tarball in BACKUP_DIR
    local d="$1" f
    mkdir -p "$BACKUP_DIR"
    f="$BACKUP_DIR/$(basename "$d")-$(date +%Y%m%d-%H%M%S).tar.gz"
    tar -czf "$f" -C "$(dirname "$d")" "$(basename "$d")" 2>/dev/null || die "Couldn't back up $d"
    printf '%s' "$f"
}

git_in() { git -c safe.directory='*' -C "$1" "${@:2}"; }

download_code() {
    section "Downloading AMACheck"
    local target="$I_HOST_DIR/$MODULE"
    mkdir -p "$I_HOST_DIR"

    if [ -d "$target/.git" ] && command -v git >/dev/null 2>&1; then
        info "Existing git checkout found — updating to the latest $BRANCH..."
        git_in "$target" remote set-url origin "$REPO_URL" 2>/dev/null || git_in "$target" remote add origin "$REPO_URL"
        GIT_TERMINAL_PROMPT=0 git_in "$target" fetch --quiet origin "+refs/heads/$BRANCH:refs/remotes/origin/$BRANCH" \
            || die "Couldn't fetch branch $BRANCH from $REPO_URL — check the server's internet access."

        local cur dirty=0
        cur="$(git_in "$target" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
        [ -n "$(git_in "$target" status --porcelain --untracked-files=no 2>/dev/null)" ] && dirty=1
        if [ "$cur" = "$BRANCH" ] && ! git_in "$target" merge-base --is-ancestor HEAD "origin/$BRANCH" 2>/dev/null; then
            dirty=1
        fi
        if [ "$dirty" = 1 ]; then
            local b; b="$(backup_folder "$target")"
            warn "Local changes found in $target — saved a backup to $b"
        fi
        git_in "$target" checkout --quiet -f -B "$BRANCH" "origin/$BRANCH"
        git_in "$target" branch --quiet --set-upstream-to="origin/$BRANCH" "$BRANCH" 2>/dev/null || true
        ok "Updated $target to $(git_in "$target" log -1 --format='%h (%cd)' --date=short)"
    else
        if [ -d "$target" ]; then
            local b; b="$(backup_folder "$target")"
            warn "Replacing existing copy at $target (backup: $b)"
            rm -rf "$target"
        fi
        do_fresh_download "$target"
    fi

    [ -f "$target/__manifest__.py" ] || die "Download finished but $target/__manifest__.py is missing."

    # Match ownership of the addons folder so Odoo (or the container user) can read it
    chown -R --reference="$I_HOST_DIR" "$target" 2>/dev/null || true
    chmod -R u+rwX,go+rX "$target" 2>/dev/null || true

    # SELinux hosts: make the files readable by containers
    if [ "$I_TYPE" = "docker" ] && command -v chcon >/dev/null 2>&1 && command -v getenforce >/dev/null 2>&1 \
       && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]; then
        chcon -R --reference="$I_HOST_DIR" "$target" 2>/dev/null || true
    fi

    # Make sure Odoo can actually see the files
    if [ "$I_TYPE" = "docker" ]; then
        "$DOCKER" exec "$I_NAME" test -r "$I_ADDONS_ENTRY/$MODULE/__manifest__.py" \
            || die "Files were written to $target but container $I_NAME can't read $I_ADDONS_ENTRY/$MODULE. Check the volume mount."
    elif [ -n "$I_TYPE" ] && [ "$I_USER" != "root" ]; then
        build_run_cmd 0 test -r "$target/__manifest__.py"
        (cd / && "${RUN_CMD[@]}") || die "User '$I_USER' can't read $target — check folder permissions."
    fi
}

do_fresh_download() {
    local target="$1"
    if command -v git >/dev/null 2>&1; then
        GIT_TERMINAL_PROMPT=0 git clone --quiet -b "$BRANCH" "$REPO_URL" "$target" \
            || die "Couldn't clone branch '$BRANCH' from $REPO_URL — check the server's internet access."
        ok "Cloned branch $BRANCH to $target"
    else
        local tmpdir; tmpdir="$(mktemp -d)"
        curl -fsSL "$ZIP_URL" -o "$tmpdir/src.zip" \
            || { rm -rf "$tmpdir"; die "Couldn't download $ZIP_URL — check the server's internet access."; }
        unzip -q "$tmpdir/src.zip" -d "$tmpdir/x"
        local inner; inner="$(find "$tmpdir/x" -mindepth 1 -maxdepth 1 -type d | head -1)"
        [ -n "$inner" ] || { rm -rf "$tmpdir"; die "Downloaded ZIP was empty."; }
        mv "$inner" "$target"
        rm -rf "$tmpdir"
        ok "Downloaded branch $BRANCH to $target"
    fi
}

# ---------- addons_path editing ----------
# Where the config can be edited: a host file (systemd, or a Docker bind mount),
# or inside the container as a last resort.
conf_host_path() {
    if [ "$I_TYPE" = "docker" ]; then
        local h; h="$(map_to_host "$I_CONF" 2>/dev/null || true)"
        [ -n "$h" ] && [ -f "$h" ] && printf '%s' "$h"
    else
        printf '%s' "$I_CONF"
    fi
}

write_conf() {   # write_conf <new content>
    local new="$1" host stamp; stamp="$(date +%Y%m%d-%H%M%S)"
    host="$(conf_host_path)"
    if [ -n "$host" ]; then
        cp -p "$host" "$host.bak.$stamp"
        printf '%s\n' "$new" > "$host"     # keeps owner/permissions of the original file
        info "Backup of the old config: $host.bak.$stamp"
    else
        warn "$I_CONF isn't on a mounted volume — editing it inside the container."
        warn "This change is lost if the container is re-created; also add it to your image/compose config."
        "$DOCKER" exec -u 0 "$I_NAME" cp -p "$I_CONF" "$I_CONF.bak.$stamp"
        printf '%s\n' "$new" | "$DOCKER" exec -i -u 0 "$I_NAME" sh -c 'cat > "$1"' sh "$I_CONF"
    fi
}

set_addons_path() {   # set_addons_path <new value>
    local content new
    content="$(read_conf)"
    new="$(printf '%s\n' "$content" | awk -v nv="$1" '
        BEGIN { done = 0 }
        /^[[:space:]]*addons_path[[:space:]]*=/ && !done { print "addons_path = " nv; done = 1; next }
        { print }
        END { if (!done) print "addons_path = " nv }')"
    write_conf "$new"
}

patch_addons_path() {
    [ -n "$I_TYPE" ] || return 0
    local current; current="$(conf_value "$(read_conf)" addons_path)"
    if split_csv "$current" | grep -qxF "${I_ADDONS_ENTRY%/}"; then
        ok "$I_ADDONS_ENTRY is already in addons_path"
        return 0
    fi
    section "Updating addons_path in $I_CONF"
    if [ -n "$current" ]; then set_addons_path "$current,$I_ADDONS_ENTRY"; else set_addons_path "$I_ADDONS_ENTRY"; fi
    ok "Added $I_ADDONS_ENTRY to addons_path"
}

# Odoo refuses to start if an addons_path folder contains no modules. After
# deleting our files, drop the folder from addons_path if it's now empty.
unpatch_addons_path_if_empty() {
    dir_has_modules "$I_HOST_DIR" && return 0
    local current new
    current="$(conf_value "$(read_conf)" addons_path)"
    split_csv "$current" | grep -qxF "${I_ADDONS_ENTRY%/}" || return 0
    new="$(split_csv "$current" | grep -vxF "${I_ADDONS_ENTRY%/}" | paste -sd, -)"
    set_addons_path "$new"
    ok "Removed now-empty $I_ADDONS_ENTRY from addons_path (Odoo won't start with an empty addons folder)"
}

# ---------- Odoo service control ----------
ODOO_STOPPED=0
cleanup() {
    if [ "$ODOO_STOPPED" = 1 ] && [ "$I_TYPE" = "systemd" ]; then
        warn "Starting $I_NAME back up..."
        systemctl start "$I_NAME" || err "Couldn't start $I_NAME — run: systemctl start $I_NAME"
    fi
}
trap cleanup EXIT

stop_odoo() {
    if [ "$I_TYPE" = "systemd" ]; then
        info "Stopping $I_NAME..."
        systemctl stop "$I_NAME"; ODOO_STOPPED=1
    fi
}

start_odoo() {
    if [ "$I_TYPE" = "systemd" ]; then
        systemctl start "$I_NAME"; ODOO_STOPPED=0
        ok "Started $I_NAME"
    elif [ "$I_TYPE" = "docker" ]; then
        if [ "$NO_RESTART" = 1 ]; then
            warn "Skipping restart (--no-restart). Restart $I_NAME yourself to load the new code."
        else
            info "Restarting container $I_NAME..."
            "$DOCKER" restart "$I_NAME" >/dev/null
            ok "Restarted container $I_NAME"
        fi
    fi
}

restart_odoo() {
    section "Restarting Odoo"
    if [ "$I_TYPE" = "systemd" ]; then
        [ "$NO_RESTART" = 1 ] && { warn "Skipping restart (--no-restart)."; return 0; }
        systemctl restart "$I_NAME"; ok "Restarted $I_NAME"
    else
        start_odoo
    fi
}

# ---------- Module operations ----------
module_state() {
    local py='m = env["ir.module.module"].search([("name", "=", "account_amacheck")])
print("AMACHECK_STATE=" + (m.state if m else "absent"))'
    run_odoo "Check module state" "$py" shell -c "$I_CONF" -d "$I_DB" --no-http --log-level=warn || true
    printf '%s\n' "$LAST_OUTPUT" | sed -n 's/.*AMACHECK_STATE=\([a-z_ ]*\).*/\1/p' | tail -1
}

run_module_op() {   # run_module_op <desc> <-i|-u>
    local desc="$1" flag="$2" rc=0
    info "This usually takes 30-90 seconds..."
    stop_odoo
    run_odoo "$desc" "" -c "$I_CONF" -d "$I_DB" "$flag" "$MODULE" --stop-after-init --no-http || rc=$?
    [ "$rc" -eq 0 ] || fail_odoo "$desc" "$rc"
    local op_output="$LAST_OUTPUT"

    local state; state="$(module_state)"
    if [ "$state" != "installed" ]; then
        LAST_OUTPUT="$op_output"   # diagnose the install run, not the state check
        printf '%s\n' "$LAST_OUTPUT" | tail -25 | sed 's/^/      /' >&2
        err "Odoo finished, but AMACheck's state in '$I_DB' is '${state:-unknown}' (expected 'installed')."
        diagnose_output
        info "Full log: $LOG_FILE"
        exit 1
    fi
    start_odoo
}

install_module() {
    section "Installing $MODULE into '$I_DB'"
    run_module_op "Module install" -i
    ok "AMACheck is installed in '$I_DB'"
}

update_module() {
    section "Upgrading $MODULE in '$I_DB'"
    run_module_op "Module upgrade" -u
    ok "AMACheck upgraded in '$I_DB'"
}

uninstall_module() {
    section "Uninstalling $MODULE from '$I_DB'"
    info "This usually takes 15-60 seconds..."
    local py='m = env["ir.module.module"].search([("name", "=", "account_amacheck")])
if not m:
    print("AMACHECK_RESULT=absent")
elif m.state != "installed":
    print("AMACHECK_RESULT=skip:" + m.state)
else:
    m.button_immediate_uninstall()
    env.cr.commit()
    print("AMACHECK_RESULT=uninstalled")'
    local rc=0
    stop_odoo
    run_odoo "Module uninstall" "$py" shell -c "$I_CONF" -d "$I_DB" --no-http || rc=$?
    local result; result="$(printf '%s\n' "$LAST_OUTPUT" | sed -n 's/.*AMACHECK_RESULT=\([a-z:_]*\).*/\1/p' | tail -1)"
    [ -n "$result" ] || fail_odoo "Module uninstall" "$rc"
    case "$result" in
        uninstalled) ok "AMACheck removed from '$I_DB'" ;;
        absent)      info "AMACheck wasn't registered in '$I_DB' — nothing to remove" ;;
        skip:*)      info "AMACheck isn't installed in '$I_DB' (state: ${result#skip:}) — nothing to remove" ;;
    esac
    start_odoo
}

remove_addon_files() {
    local target="$I_HOST_DIR/$MODULE"
    [ -d "$target" ] || { info "No files to remove at $target"; return 0; }

    local should="$REMOVE_FILES"
    if [ -z "$should" ]; then
        if confirm "Also delete the addon files at $target?"; then should="yes"; else should="no"; fi
    fi
    if [ "$should" = "yes" ]; then
        local b; b="$(backup_folder "$target")"
        rm -rf "$target"
        ok "Deleted $target (backup: $b)"
        unpatch_addons_path_if_empty
        restart_odoo
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

${GREEN}${BOLD}AMACheck is ready.${NC}

${BOLD}Next steps:${NC}
  1. Open Odoo in your browser
  2. Go to ${BOLD}Settings → AMACheck${NC}
  3. Enter your AMAChecks ${BOLD}License Code${NC}
  4. Click ${BOLD}Refresh Balance${NC} to load your provider settings
  5. Go to ${BOLD}Accounting → Configuration → Journals${NC}, open your bank journal,
     and fill in the ${BOLD}Signer${NC} name under "AMACheck Settings"

Need a license code? Visit ${BLUE}https://www.amachecks.com${NC}

EOF
            if [ "$SKIP_MODULE_INSTALL" = "1" ] || [ -z "$I_TYPE" ]; then
                cat <<EOF
${YELLOW}The module still needs to be installed in Odoo:${NC}
EOF
                [ -z "$I_TYPE" ] && echo "  • Restart Odoo the way you normally do"
                cat <<EOF
  • Settings → Activate Developer Mode
  • Apps → Update Apps List
  • Search "AMACheck" → Install

EOF
            fi
            ;;
        update)
            printf '\n%s\n\nIf anything looks stale in the browser, do a hard refresh (Ctrl+Shift+R).\n\n' \
                "${GREEN}${BOLD}AMACheck has been updated to the latest $BRANCH release.${NC}"
            ;;
        uninstall)
            printf '\n%s\n\nTo reinstall later, run this script again without --uninstall.\n\n' \
                "${GREEN}${BOLD}AMACheck has been removed from '$I_DB'.${NC}"
            ;;
    esac
    info "Log of this run: $LOG_FILE"
}

# ---------- Main ----------
main() {
    banner
    preflight

    if ! discover; then
        # Files-only mode (no recognised Odoo service)
        [ "$MODE" = "install" ] || [ "$MODE" = "update" ] || die "Uninstall needs a detected Odoo instance."
        I_HOST_DIR="$ADDONS_DIR_OVERRIDE"; I_ADDONS_ENTRY="$ADDONS_DIR_OVERRIDE"; SKIP_MODULE_INSTALL=1
        detect_odoo_version
        show_plan
        download_code
        warn "Make sure $I_HOST_DIR is listed in addons_path in your Odoo config."
        summary
        return 0
    fi

    choose_instance

    case "$MODE" in
        install)
            resolve_addons_dir
            detect_odoo_version
            [ "$SKIP_MODULE_INSTALL" = "1" ] || choose_database
            show_plan
            download_code
            patch_addons_path
            if [ "$SKIP_MODULE_INSTALL" = "1" ]; then restart_odoo; else install_module; fi
            ;;
        update)
            resolve_addons_dir
            if [ -z "$BRANCH_OVERRIDE" ] && [ -d "$I_HOST_DIR/$MODULE/.git" ]; then
                local cur; cur="$(git_in "$I_HOST_DIR/$MODULE" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
                is_supported_branch "$cur" && BRANCH_OVERRIDE="$cur"
            fi
            detect_odoo_version
            choose_database
            show_plan
            download_code
            patch_addons_path
            update_module
            ;;
        uninstall)
            resolve_addons_dir
            choose_database
            show_plan
            uninstall_module
            remove_addon_files
            ;;
    esac

    summary
}

main "$@"
