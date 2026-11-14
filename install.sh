#!/usr/bin/env bash
# ODXPilot installer.
#
#   curl -fsSL https://raw.githubusercontent.com/terrakernel/odxpilot-install/main/install.sh | bash
#
# Installs any of the three parts of an ODXPilot stack on this machine, with Docker Compose:
#
#   pilot   ODXPilot: the web UI and chat, the Odoo tools and their policies
#   proxy   ODXProxy: the gateway to your Odoo (needs a licence)
#   brain   ODXBrain + odxdocs: which Odoo model, which SOP; your SOPs
#
# All three on one machine, or each on its own: the parts on other machines are reached by address
# and key, which their own install writes to a hand-over file. Questions come from the terminal,
# also under `curl | bash`; for an unattended run, answer them with ODXI_* variables and --yes
# (see --help). Keys are generated here and never printed.
#
# Read it first if you like: curl -fsSL <url> -o install.sh; less install.sh; bash install.sh

# The ask* helpers set the answer's variable by name (printf -v), which shellcheck can't follow.
# shellcheck disable=SC2153
set -Eeuo pipefail

INSTALLER_VERSION="0.1.0"
BUNDLE_VERSION="0.1.0"
BUNDLE_URL="https://github.com/terrakernel/odxpilot-install/releases/download/v${BUNDLE_VERSION}/odxpilot-bundle-${BUNDLE_VERSION}.tar.gz"

MODEL_URL="https://huggingface.co/terrakernel/odxbrain-bge-m3-gguf/resolve/582d13afe777ea05e979a07890d6b3e6ae8dd975/bge-m3-f16.gguf"
MODEL_SHA256="1257ef7bb76105793f89307b02d6b9c29a444d629f9ff0ad56ee023222fa105d"
PACK_VERSION="2026.09.4"
PACK_URL="https://github.com/terrakernel/odxbrain-corpus/releases/download/${PACK_VERSION}/odxbrain-pack-${PACK_VERSION}-bge-m3.tar.gz"

# ---- output ------------------------------------------------------------------------------------

if [ -t 1 ]; then
    B=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
else
    B=""; DIM=""; RED=""; GRN=""; YLW=""; RST=""
fi
say()  { printf '%s\n' "$*"; }
step() { printf '\n%s==> %s%s\n' "$B" "$*" "$RST"; }
ok()   { printf '  %sok%s  %s\n' "$GRN" "$RST" "$*"; }
note() { printf '  %s%s%s\n' "$DIM" "$*" "$RST"; }
warn() { printf '  %swarning:%s %s\n' "$YLW" "$RST" "$*" >&2; }
die()  { printf '\n%serror:%s %s\n' "$RED" "$RST" "$*" >&2; exit 1; }

# ---- questions ---------------------------------------------------------------------------------
# Each question has a name. ODXI_<NAME> answers it ahead (unattended runs); with --yes, a question
# that has a default takes it. Otherwise the answer comes from the terminal, also under curl | bash.

ASSUME_YES=0
TTY_OK=0

open_tty() {
    if [ -r /dev/tty ] && { exec 3</dev/tty; } 2>/dev/null; then
        TTY_OK=1
    fi
}

preset() { # NAME -> prints ODXI_NAME if set
    local var="ODXI_$1"
    if [ -n "${!var+x}" ]; then
        printf '%s' "${!var}"
        return 0
    fi
    return 1
}

read_line() { # PROMPT SECRET(0/1) -> REPLY
    if [ "$TTY_OK" != 1 ]; then
        die "no terminal to ask on. Run it in a terminal, or answer with ODXI_* variables and --yes (see --help)."
    fi
    printf '%s' "$1" >&2
    if [ "$2" = 1 ]; then
        IFS= read -r -s REPLY <&3 || REPLY=""
        printf '\n' >&2
    else
        IFS= read -r REPLY <&3 || REPLY=""
    fi
}

# ask NAME "question" [default] -> sets the shell variable NAME
ask() {
    local name=$1 question=$2 default=${3-} answer
    if answer=$(preset "$name"); then
        printf -v "$name" '%s' "$answer"
        return
    fi
    if [ "$ASSUME_YES" = 1 ] && [ -n "$default" ]; then
        printf -v "$name" '%s' "$default"
        return
    fi
    while :; do
        if [ -n "$default" ]; then
            read_line "  $question [$default]: " 0
            answer=${REPLY:-$default}
        else
            read_line "  $question: " 0
            answer=$REPLY
        fi
        [ -n "$answer" ] && break
        say "  (an answer is needed)"
    done
    printf -v "$name" '%s' "$answer"
}

# ask_optional NAME "question" [default] -> may stay empty
ask_optional() {
    local name=$1 question=$2 default=${3-} answer
    if answer=$(preset "$name"); then
        printf -v "$name" '%s' "$answer"
        return
    fi
    if [ "$ASSUME_YES" = 1 ]; then
        printf -v "$name" '%s' "$default"
        return
    fi
    if [ -n "$default" ]; then
        read_line "  $question [$default, or - for none]: " 0
        answer=${REPLY:-$default}
        [ "$answer" = - ] && answer=""
    else
        read_line "  $question (Enter to skip): " 0
        answer=$REPLY
    fi
    printf -v "$name" '%s' "$answer"
}

# a secret kept from an earlier install (reconfigure), else asked
ask_secret_kept() { # NAME "question" KEPT
    if [ -n "$3" ] && ! preset "$1" >/dev/null; then
        printf -v "$1" '%s' "$3"
        note "keeping the key already set"
    else
        ask_secret "$1" "$2"
    fi
}

# ask_secret NAME "question" -> never echoed
ask_secret() {
    local name=$1 question=$2 answer
    if answer=$(preset "$name"); then
        printf -v "$name" '%s' "$answer"
        return
    fi
    [ "$ASSUME_YES" = 1 ] && die "$question: no answer (set ODXI_$name)"
    while :; do
        read_line "  $question (hidden): " 1
        [ -n "$REPLY" ] && break
        say "  (an answer is needed)"
    done
    printf -v "$name" '%s' "$REPLY"
}

# ask_yn NAME "question" y|n -> NAME is 1 or 0
ask_yn() {
    local name=$1 question=$2 default=$3 answer hint
    if answer=$(preset "$name"); then
        :
    elif [ "$ASSUME_YES" = 1 ]; then
        answer=$default
    else
        if [ "$default" = y ]; then hint="Y/n"; else hint="y/N"; fi
        read_line "  $question [$hint]: " 0
        answer=${REPLY:-$default}
    fi
    case "$answer" in
        y | Y | yes | Yes | YES | 1 | true) printf -v "$name" '%s' 1 ;;
        *) printf -v "$name" '%s' 0 ;;
    esac
}

# choose NAME "question" default option... -> NAME is one of the options
choose() {
    local name=$1 question=$2 default=$3 answer opt
    shift 3
    while :; do
        if ! answer=$(preset "$name"); then
            if [ "$ASSUME_YES" = 1 ]; then
                answer=$default
            else
                read_line "  $question ($(printf '%s/' "$@" | sed 's#/$##')) [$default]: " 0
                answer=${REPLY:-$default}
            fi
        fi
        for opt in "$@"; do
            if [ "$answer" = "$opt" ]; then
                printf -v "$name" '%s' "$answer"
                return
            fi
        done
        if preset "$name" >/dev/null || [ "$ASSUME_YES" = 1 ]; then
            die "$question: '$answer' isn't one of: $*"
        fi
        say "  (one of: $*)"
    done
}

# ---- small helpers -----------------------------------------------------------------------------

have() { command -v "$1" >/dev/null 2>&1; }

new_key() {
    if have openssl; then
        openssl rand -hex 32
    else
        od -An -N32 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

sha256_of() {
    if have sha256sum; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

toml_str() { # a TOML basic string
    local s=${1//\\/\\\\}
    s=${s//\"/\\\"}
    printf '"%s"' "$s"
}

# value of KEY in an env file (KEY=value lines), or nothing
env_get() {
    [ -f "$1" ] || return 0
    sed -n "s/^$2=//p" "$1" | tail -n 1
}

# a key kept from an earlier install of this folder, else a new one
keep_or_new() { # FILE KEY
    local old
    old=$(env_get "$1" "$2")
    if [ -n "$old" ]; then printf '%s' "$old"; else new_key; fi
}

write_private() { # FILE, content on stdin; mode 600
    local tmp="$1.tmp.$$"
    (umask 077 && cat >"$tmp")
    mv -f "$tmp" "$1"
}

this_ip() {
    local ip=""
    if have hostname && hostname -I >/dev/null 2>&1; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    if [ -z "$ip" ] && have ipconfig; then
        ip=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)
    fi
    printf '%s' "${ip:-127.0.0.1}"
}

port_busy() {
    if have lsof; then
        lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
    elif have ss; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
    else
        return 1
    fi
}

is_local_url() { # URL points at this machine (unreachable as such from inside a container)
    case "$1" in
        *://localhost* | *://127.* | *://\[::1\]*) return 0 ;;
        *) return 1 ;;
    esac
}

container_url() { # this machine's own address, as a container sees it
    printf '%s' "$1" | sed -E 's#://(localhost|127\.[0-9.]+|\[::1\])#://host.docker.internal#'
}

# compose, its progress lines into logs/install.log; shown if it fails
quietly() {
    mkdir -p "$DIR/logs"
    if ! compose "$@" >>"$DIR/logs/install.log" 2>&1; then
        tail -n 15 "$DIR/logs/install.log" | sed 's/^/    /' >&2
        return 1
    fi
}

wait_http() { # URL SECONDS WHAT
    local i=0
    while [ "$i" -lt "$2" ]; do
        if curl -fsS -o /dev/null --max-time 3 "$1" 2>/dev/null; then
            return 0
        fi
        sleep 2
        i=$((i + 2))
    done
    return 1
}

# Compose reads .env, but a variable exported in the shell would win over it: drop those.
compose() {
    (cd "$DIR" && env -u COMPOSE_PROFILES -u COMPOSE_PROJECT_NAME -u COMPOSE_FILE \
        -u ODXPILOT_TAG -u ODXPROXY_TAG -u ODXBRAIN_TAG -u ODXDOCS_TAG \
        -u ODXPILOT_BIND -u ODXPILOT_PORT -u PROXY_BIND -u PROXY_PORT -u BRAIN_BIND -u BRAIN_PORT \
        -u DOCS_BIND -u DOCS_PORT -u ODX_UID -u ODX_GID docker compose "$@")
}

# hand-over files: KEY=value lines another machine's install wrote
load_handover() { # FILE -> sets HO_* from its lines
    local line key value
    [ -f "$1" ] || die "no hand-over file at $1"
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in '#'* | '') continue ;; esac
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
            PROXY_URL | PROXY_KEY | BRAIN_URL | BRAIN_KEY | DOCS_URL | DOCS_KEY)
                printf -v "HO_$key" '%s' "$value" ;;
        esac
    done <"$1"
}

# ---- steps -------------------------------------------------------------------------------------

usage() {
    cat <<EOF
ODXPilot installer $INSTALLER_VERSION

  bash install.sh [--dir DIR] [--bundle DIR|URL] [--yes] [--no-start]

  --dir DIR        install folder (default ~/odxpilot, /opt/odxpilot as root)
  --bundle SRC     the compose bundle: a folder or a .tar.gz URL (default: release $BUNDLE_VERSION)
  --yes            take the default for every question that has one
  --no-start       write the files, don't pull or start anything

Unattended: answer questions with ODXI_<NAME>=... in the environment, e.g.
  ODXI_PARTS=pilot ODXI_PROXY_URL=http://10.0.0.5:6600 ODXI_PROXY_KEY=... \\
  ODXI_ODOO_URL=https://odoo.example.edu ODXI_ODOO_DB=prod ODXI_ODOO_KEY=... \\
  ODXI_LLM=openai ODXI_LLM_KEY=... bash install.sh --yes
Names: PARTS (pilot,proxy,brain), DIR, LICENSE, ODOO_URL, ODOO_DB, ODOO_USER_ID, ODOO_KEY,
ODOO_VERSION, ODOO_EDITION, LLM (openai|claude|gemini|endpoint), LLM_KEY, LLM_MODEL, LLM_URL, ROLE,
SOP_EXAMPLES, PROXY_HANDOVER / BRAIN_HANDOVER (a hand-over file), PROXY_URL, PROXY_KEY, BRAIN_URL,
BRAIN_KEY, DOCS_URL, DOCS_KEY, NETWORK (listen for other machines: 1/0), UI_NETWORK, IP.
EOF
}

preflight() {
    step "Checking this machine"
    OS=$(uname -s)
    ARCH=$(uname -m)
    case "$OS" in
        Linux | Darwin) ok "$OS $ARCH" ;;
        *) die "$OS isn't supported: use Linux or macOS (on Windows, WSL 2 with Docker)" ;;
    esac
    # Docker Desktop on macOS may leave its CLI outside PATH
    for d in "$HOME/.docker/bin" /usr/local/bin /Applications/Docker.app/Contents/Resources/bin; do
        if ! have docker && [ -x "$d/docker" ]; then PATH="$d:$PATH"; fi
    done
    have docker || die "Docker isn't installed: https://docs.docker.com/engine/install/ (Docker Desktop on macOS)"
    docker info >/dev/null 2>&1 || die "Docker is installed but not running (or this user can't use it: on Linux, add it to the docker group)"
    local cv
    cv=$(docker compose version --short 2>/dev/null || true)
    [ -n "$cv" ] || die "Docker Compose v2 is missing (the 'docker compose' plugin)"
    case "$cv" in
        1.* | 2.[0-9].* | 2.1[0-9].*) die "Docker Compose $cv is too old: 2.20 or newer is needed" ;;
    esac
    ok "Docker $(docker version --format '{{.Server.Version}}' 2>/dev/null), Compose $cv"
    have curl || die "curl is needed"
    have tar || die "tar is needed"
    if [ "$ARCH" = aarch64 ] || [ "$ARCH" = arm64 ]; then
        if [ "$OS" = Linux ]; then
            note "ODXProxy, ODXBrain and odxdocs are published for amd64: on ARM Linux they need emulation (binfmt / qemu-user-static)"
        else
            note "ODXProxy, ODXBrain and odxdocs are published for amd64: Docker Desktop emulates them"
        fi
    fi
}

choose_dir() {
    local default="$HOME/odxpilot"
    [ "$(id -u)" = 0 ] && default=/opt/odxpilot
    if [ -z "${DIR:-}" ]; then
        ask DIR "Install folder" "$default"
    fi
    case "$DIR" in "~"*) DIR="$HOME${DIR#\~}" ;; esac
    case "$DIR" in /*) ;; *) DIR="$PWD/$DIR" ;; esac
    if [ "$OS" = Darwin ]; then
        case "$DIR" in
            "$HOME"/*) ;;
            *) warn "Docker Desktop only shares your home folder by default: outside it, the folders mount empty (Settings > Resources > File Sharing)" ;;
        esac
    fi
    EXISTING=0
    if [ -f "$DIR/.env" ] && [ -f "$DIR/compose.yaml" ]; then
        EXISTING=1
        step "ODXPilot is already installed in $DIR"
        choose ACTION "Upgrade it (keep its settings), reconfigure it (answer again, keep its keys), or quit" upgrade upgrade reconfigure quit
        if [ "$ACTION" = quit ]; then exit 0; fi
    else
        ACTION=install
    fi
}

fetch_bundle() {
    step "Getting the compose bundle"
    local src=${BUNDLE:-$BUNDLE_URL} tmp
    tmp=$(mktemp -d)
    if [ -d "$src" ]; then
        cp -R "$src/." "$tmp/"
        note "from the folder $src"
    else
        curl -fsSL "$src" -o "$tmp/bundle.tar.gz" || die "can't download $src"
        if curl -fsSL "$src.sha256" -o "$tmp/bundle.sha256" 2>/dev/null; then
            [ "$(sha256_of "$tmp/bundle.tar.gz")" = "$(cut -d' ' -f1 <"$tmp/bundle.sha256")" ] \
                || die "the bundle's checksum doesn't match $src.sha256"
            ok "checksum"
        else
            warn "no $src.sha256 to check the bundle against"
        fi
        tar xzf "$tmp/bundle.tar.gz" -C "$tmp"
        rm -f "$tmp/bundle.tar.gz" "$tmp/bundle.sha256"
    fi
    [ -f "$tmp/compose.yaml" ] || die "the bundle has no compose.yaml"
    mkdir -p "$DIR"
    chmod 700 "$DIR"
    # The bundle's own files are replaced; settings, keys and data never are.
    cp -f "$tmp/compose.yaml" "$DIR/compose.yaml"
    [ -f "$tmp/README.md" ] && cp -f "$tmp/README.md" "$DIR/README.md"
    mkdir -p "$DIR/examples"
    [ -d "$tmp/env" ] && cp -R "$tmp/env" "$DIR/examples/"
    [ -d "$tmp/policies" ] && cp -R "$tmp/policies" "$DIR/examples/"
    [ -d "$tmp/sop-examples" ] && cp -R "$tmp/sop-examples" "$DIR/examples/"
    for f in .env.example odxpilot.toml.example odxproxy/config.conf.example; do
        [ -f "$tmp/$f" ] && cp -f "$tmp/$f" "$DIR/examples/"
    done
    if [ ! -d "$DIR/policies" ] && [ -d "$tmp/policies" ]; then
        cp -R "$tmp/policies" "$DIR/policies"
    fi
    rm -rf "$tmp"
    ok "compose.yaml and examples in $DIR"
}

ask_parts() {
    step "Which parts run on this machine?"
    say "  An ODXPilot stack has three parts. They can all run here, or each on its own machine."
    say "    ${B}pilot${RST}  ODXPilot: the web UI and chat, the Odoo tools and their policies"
    say "    ${B}proxy${RST}  ODXProxy: the gateway to your Odoo (needs an ODXProxy licence)"
    say "    ${B}brain${RST}  ODXBrain + odxdocs: finds the Odoo model and your SOP for a request"
    local parts
    if parts=$(preset PARTS); then
        :
    else
        ask_yn RUN_PILOT "Run ODXPilot here?" y
        ask_yn RUN_PROXY "Run ODXProxy here?" y
        ask_yn RUN_BRAIN "Run ODXBrain + odxdocs here?" y
        parts=""
        [ "$RUN_PILOT" = 1 ] && parts="$parts,pilot"
        [ "$RUN_PROXY" = 1 ] && parts="$parts,proxy"
        [ "$RUN_BRAIN" = 1 ] && parts="$parts,brain"
        parts=${parts#,}
    fi
    PILOT=0; PROXY=0; BRAIN=0
    case ",$parts," in *,pilot,*) PILOT=1 ;; esac
    case ",$parts," in *,proxy,*) PROXY=1 ;; esac
    case ",$parts," in *,brain,*) BRAIN=1 ;; esac
    PARTS=$parts
    [ -n "$PARTS" ] || die "nothing to install: choose at least one part"
    ok "this machine runs: $PARTS"
}

network_warning() { # WHAT
    warn "$1 will listen on the network over plain HTTP. Its key protects it, but anyone who can"
    warn "watch the traffic can read it: keep these machines on a private network or VPN, or put"
    warn "HTTPS (a reverse proxy) in front."
}

ask_brain() {
    step "ODXBrain + odxdocs"
    BRAIN_DOCS_KEY=$(keep_or_new "$DIR/env/sop-tools.env" ODXDOCS_BRAIN_KEY)
    DOCS_API_KEY=$(keep_or_new "$DIR/env/odxdocs.env" ODXDOCS_API_KEY)
    BRAIN_PROXY_KEY=$(env_get "$DIR/env/odxbrain.env" ODXBRAIN_API_KEY | cut -s -d: -f2)
    [ -n "$BRAIN_PROXY_KEY" ] || BRAIN_PROXY_KEY=$(new_key)
    BRAIN_BIND=127.0.0.1
    if [ "$PROXY" = 0 ] || [ "$PILOT" = 0 ]; then
        say "  ODXProxy and/or ODXPilot run on other machines, so they must reach ODXBrain and odxdocs."
        ask_yn NETWORK "Let other machines connect to ODXBrain (8080) and odxdocs (8090)?" y
        if [ "$NETWORK" = 1 ]; then
            BRAIN_BIND=0.0.0.0
            network_warning "ODXBrain and odxdocs"
        fi
    fi
    if [ ! -d "$DIR/sop-files" ] || [ -z "$(ls -A "$DIR/sop-files" 2>/dev/null)" ]; then
        say "  ODXPilot changes something in Odoo only when one of your SOPs (procedures) covers it."
        ask_yn SOP_EXAMPLES "Add three example SOPs for contacts (create, change the reference, archive), to try changes right away?" y
    else
        SOP_EXAMPLES=0
    fi
}

ask_proxy() {
    step "ODXProxy"
    PROXY_API_KEY=$(env_get "$DIR/odxproxy/config.conf" PROXY_API_KEY)
    [ -n "$PROXY_API_KEY" ] || PROXY_API_KEY=$(new_key)
    [ -f "$DIR/odxproxy/license.json" ] && LICENSE_DEFAULT="$DIR/odxproxy/license.json"
    if [ ! -f "$DIR/odxproxy/license.json" ] || [ "$ACTION" = reconfigure ]; then
        while :; do
            ask LICENSE "Path to your ODXProxy licence file (license.json)" "${LICENSE_DEFAULT:-}"
            case "$LICENSE" in "~"*) LICENSE="$HOME${LICENSE#\~}" ;; esac
            [ -f "$LICENSE" ] && break
            if preset LICENSE >/dev/null || [ "$ASSUME_YES" = 1 ]; then
                die "no licence file at $LICENSE. ODXProxy needs one: request it at https://odxproxy.io"
            fi
            say "  No file at $LICENSE. ODXProxy needs a licence: request one at https://odxproxy.io"
        done
    fi
    if [ "$BRAIN" = 1 ]; then
        PROXY_BRAIN_URL="http://odxbrain:8080"
        PROXY_BRAIN_KEY=$BRAIN_PROXY_KEY
    else
        say "  ODXBrain runs on another machine. Its install wrote a hand-over file"
        say "  (odxpilot-handover-brain.env) with its address and the key for ODXProxy."
        ask_optional BRAIN_HANDOVER "Path to that hand-over file"
        if [ -n "$BRAIN_HANDOVER" ]; then
            load_handover "$BRAIN_HANDOVER"
            PROXY_BRAIN_URL=${HO_BRAIN_URL:-}
            PROXY_BRAIN_KEY=${HO_BRAIN_KEY:-}
        else
            ask_optional BRAIN_URL "ODXBrain's address, e.g. http://10.0.0.5:8080 (none: no model or SOP lookup)" \
                "$(env_get "$DIR/env/odxproxy.env" ODXBRAIN_URL)"
            PROXY_BRAIN_URL=$BRAIN_URL
            PROXY_BRAIN_KEY=""
            if [ -n "$PROXY_BRAIN_URL" ]; then
                ask_secret_kept BRAIN_KEY "The key ODXProxy sends to ODXBrain" "$(env_get "$DIR/env/odxproxy.env" ODXBRAIN_API_KEY)"
                PROXY_BRAIN_KEY=$BRAIN_KEY
            fi
        fi
        [ -n "$PROXY_BRAIN_URL" ] && PROXY_BRAIN_URL=$(container_url "$PROXY_BRAIN_URL")
    fi
    PROXY_BIND=127.0.0.1
    if [ "$PILOT" = 0 ]; then
        say "  ODXPilot runs on another machine, so it must reach ODXProxy."
        ask_yn NETWORK "Let other machines connect to ODXProxy (6600)?" y
        if [ "$NETWORK" = 1 ]; then
            PROXY_BIND=0.0.0.0
            network_warning "ODXProxy"
        fi
    fi
}

ask_pilot() {
    step "ODXPilot"
    # ODXProxy
    if [ "$PROXY" = 1 ]; then
        P_PROXY_URL="http://odxproxy:6600"
        P_PROXY_KEY=$PROXY_API_KEY
        PROBE_URL="http://127.0.0.1:${PROXY_PORT}"
    else
        say "  ODXProxy runs on another machine. Its install wrote odxpilot-handover-proxy.env."
        ask_optional PROXY_HANDOVER "Path to that hand-over file"
        if [ -n "$PROXY_HANDOVER" ]; then
            load_handover "$PROXY_HANDOVER"
            PROBE_URL=${HO_PROXY_URL:-}
            P_PROXY_KEY=${HO_PROXY_KEY:-}
        else
            ask PROXY_URL "ODXProxy's address, e.g. http://10.0.0.5:6600" "$(env_get "$DIR/.install" PROXY_URL)"
            ask_secret_kept PROXY_KEY "ODXProxy's API key" "$(env_get "$DIR/env/odx-mcp.env" ODXPROXY_API_KEY)"
            PROBE_URL=$PROXY_URL
            P_PROXY_KEY=$PROXY_KEY
        fi
        [ -n "$PROBE_URL" ] && [ -n "$P_PROXY_KEY" ] || die "ODXProxy's address and key are needed"
        PROBE_URL=${PROBE_URL%/}
        P_PROXY_URL=$(container_url "$PROBE_URL")
    fi
    # odxdocs (SOP texts)
    if [ "$BRAIN" = 1 ]; then
        P_DOCS_URL="http://odxdocs:8090"
        P_DOCS_KEY=$DOCS_API_KEY
    else
        say "  odxdocs serves your SOPs; without it ODXPilot answers questions but plans no changes."
        [ -n "${BRAIN_HANDOVER:-}" ] || ask_optional BRAIN_HANDOVER "Path to the ODXBrain machine's hand-over file (odxpilot-handover-brain.env)"
        if [ -n "$BRAIN_HANDOVER" ]; then
            load_handover "$BRAIN_HANDOVER"
            P_DOCS_URL=${HO_DOCS_URL:-}
            P_DOCS_KEY=${HO_DOCS_KEY:-}
        else
            ask_optional DOCS_URL "odxdocs' address, e.g. http://10.0.0.5:8090" "$(env_get "$DIR/.install" DOCS_URL)"
            P_DOCS_URL=$DOCS_URL
            P_DOCS_KEY=""
            if [ -n "$P_DOCS_URL" ]; then
                ask_secret_kept DOCS_KEY "odxdocs' API key" "$(env_get "$DIR/env/odx-mcp.env" ODXDOCS_API_KEY)"
                P_DOCS_KEY=$DOCS_KEY
            fi
        fi
        [ -n "$P_DOCS_URL" ] && P_DOCS_URL=$(container_url "${P_DOCS_URL%/}")
    fi
    # Odoo
    say "  Your Odoo. Use a test database first: approved changes are written to it."
    ask ODOO_URL "Odoo's address, e.g. https://odoo.example.edu" "$(env_get "$DIR/.install" ODOO_URL)"
    ODOO_URL=${ODOO_URL%/}
    is_local_url "$ODOO_URL" && warn "ODXProxy reaches Odoo from inside a container, where localhost is the container itself: use the machine's address"
    ask ODOO_DB "Odoo database name" "$(env_get "$DIR/.install" ODOO_DB)"
    say "  ODXPilot acts as one Odoo user: its API key is under avatar > Preferences > Account Security."
    local uid_default
    uid_default=$(env_get "$DIR/.install" ODOO_USER_ID)
    ask ODOO_USER_ID "That user's id (Settings > Users: the number in the address bar)" "${uid_default:-2}"
    local kept_odoo
    kept_odoo=$(env_get "$DIR/env/odx-mcp.env" ODOO_API_KEY)
    if [ -n "$kept_odoo" ] && [ "$ACTION" != install ] && ! preset ODOO_KEY >/dev/null; then
        ODOO_KEY=$kept_odoo
        note "keeping the Odoo API key already set"
    else
        ask_secret ODOO_KEY "That user's Odoo API key"
    fi
    # LLM
    say "  The model ODXPilot talks to (fixed until restart). Questions and Odoo data the role may"
    say "  read go to it; masked fields stay masked."
    local llm_default
    llm_default=$(env_get "$DIR/.install" LLM)
    choose LLM "Which LLM" "${llm_default:-openai}" openai claude gemini endpoint
    case "$LLM" in
        openai) LLM_MODEL_DEFAULT="gpt-6.1-sol"; LLM_ENV=OPENAI_API_KEY ;;
        claude) LLM_MODEL_DEFAULT="claude-opus-5-5"; LLM_ENV=ANTHROPIC_API_KEY ;;
        gemini) LLM_MODEL_DEFAULT="gemini-3.5-flash"; LLM_ENV=GOOGLE_API_KEY ;;
        endpoint) LLM_MODEL_DEFAULT=""; LLM_ENV=LLM_ENDPOINT_API_KEY ;;
    esac
    LLM_URL=""
    if [ "$LLM" = endpoint ]; then
        say "  Your own OpenAI-compatible server (Chat Completions: llama.cpp, vLLM, Ollama, ...)."
        ask LLM_URL "Its base URL, up to /v1, e.g. http://10.0.0.9:8080/v1"
        LLM_URL=$(container_url "${LLM_URL%/}")
        ask LLM_MODEL "The model name it serves"
        ask_optional LLM_KEY "Its API key, if it needs one"
    else
        ask LLM_MODEL "Model" "$LLM_MODEL_DEFAULT"
        local kept_llm
        kept_llm=$(env_get "$DIR/env/orchestrator.env" "$LLM_ENV")
        if [ -n "$kept_llm" ] && [ "$ACTION" != install ] && ! preset LLM_KEY >/dev/null; then
            LLM_KEY=$kept_llm
            note "keeping the $LLM_ENV already set"
        else
            [ "$LLM" = gemini ] && note "Gemini runs on Vertex AI: a Vertex API key, not an AI Studio key"
            ask_secret LLM_KEY "$LLM_ENV"
        fi
    fi
    # Role
    local role_default=contact_editor
    [ -z "$P_DOCS_URL" ] && role_default=reader
    say "  What ODXPilot may do: 'reader' only reads; 'contact_editor' also creates, edits and"
    say "  archives contacts (each change a plan card you approve). Edit policies/ for more."
    choose ROLE "Role" "$role_default" reader contact_editor
    PROPOSAL_KEY=$(keep_or_new "$DIR/env/odx-mcp.env" ODXPILOT_PROPOSAL_KEY)
    ODXPILOT_BIND=127.0.0.1
    ask_yn UI_NETWORK "Open the web UI to other machines too? (it has no sign-in yet)" n
    if [ "$UI_NETWORK" = 1 ]; then
        ODXPILOT_BIND=0.0.0.0
        warn "Anyone who reaches port $ODXPILOT_PORT can use ODXPilot as role '$ROLE', without signing in."
    fi
}

write_files() {
    step "Writing the settings"
    mkdir -p "$DIR/env" "$DIR/uploads" "$DIR/logs/odxproxy" "$DIR/odxproxy" "$DIR/models" \
        "$DIR/pack" "$DIR/sops" "$DIR/store" "$DIR/sop-files"
    chmod 700 "$DIR/env"
    # The containers run as their own users (uid 65532, 10001): they need these writable or
    # readable. The install folder itself is 700, so nobody else on this machine gets in.
    chmod 777 "$DIR/uploads" "$DIR/logs/odxproxy"
    chmod 755 "$DIR/odxproxy" "$DIR/models" "$DIR/pack" "$DIR/sops" "$DIR/store"

    local profiles=""
    [ "$PILOT" = 1 ] && profiles="$profiles,pilot"
    [ "$PROXY" = 1 ] && profiles="$profiles,proxy"
    [ "$BRAIN" = 1 ] && profiles="$profiles,brain"
    {
        say "# Written by the ODXPilot installer $INSTALLER_VERSION. No keys here: they are in env/."
        say "COMPOSE_PROJECT_NAME=$(basename "$DIR" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_-')"
        say "COMPOSE_PROFILES=${profiles#,}"
        say "ODXPILOT_TAG=${ODXPILOT_TAG:-0.1.0}"
        say "ODXPROXY_TAG=${ODXPROXY_TAG:-0.10.1}"
        say "ODXBRAIN_TAG=${ODXBRAIN_TAG:-0.1.0}"
        say "ODXDOCS_TAG=${ODXDOCS_TAG:-0.1.0}"
        say "ODXPILOT_BIND=${ODXPILOT_BIND:-127.0.0.1}"
        say "ODXPILOT_PORT=$ODXPILOT_PORT"
        say "PROXY_BIND=${PROXY_BIND:-127.0.0.1}"
        say "PROXY_PORT=$PROXY_PORT"
        say "BRAIN_BIND=${BRAIN_BIND:-127.0.0.1}"
        say "BRAIN_PORT=$BRAIN_PORT"
        say "DOCS_BIND=${BRAIN_BIND:-127.0.0.1}"
        say "DOCS_PORT=$DOCS_PORT"
        say "ODX_UID=$(id -u)"
        say "ODX_GID=$(id -g)"
    } >"$DIR/.env"

    if [ "$BRAIN" = 1 ]; then
        printf 'ODXBRAIN_API_KEY=%s:%s\n' "$BRAIN_DOCS_KEY" "$BRAIN_PROXY_KEY" | write_private "$DIR/env/odxbrain.env"
        printf 'ODXDOCS_API_KEY=%s\n' "$DOCS_API_KEY" | write_private "$DIR/env/odxdocs.env"
        printf 'ODXDOCS_BRAIN_KEY=%s\n' "$BRAIN_DOCS_KEY" | write_private "$DIR/env/sop-tools.env"
        if [ "$SOP_EXAMPLES" = 1 ] && [ -d "$DIR/examples/sop-examples" ]; then
            cp -n "$DIR/examples/sop-examples/"*.md "$DIR/sop-files/" 2>/dev/null || true
            ok "three example SOPs in sop-files/ (replace them with your own)"
        fi
    fi
    if [ "$PROXY" = 1 ]; then
        if [ -n "${LICENSE:-}" ] && [ "$LICENSE" != "$DIR/odxproxy/license.json" ]; then
            cp -f "$LICENSE" "$DIR/odxproxy/license.json"
        fi
        chmod 644 "$DIR/odxproxy/license.json"
        {
            say "# ODXProxy, written by the ODXPilot installer"
            say "LISTEN_ADDR=0.0.0.0:6600"
            say "PROXY_API_KEY=$PROXY_API_KEY"
            say "RUST_LOG=info,TheODXProxy=info"
            say "DEFAULT_ODOO_TIMEOUT_SECS=30"
            say "LOG_PATH=/var/log/odxproxy"
            say "HEARTBEAT=false"
            say "LICENSE_KEY=/usr/share/odxproxy/config/license.json"
        } >"$DIR/odxproxy/config.conf.tmp"
        # The container's user must read it; the folder above it is 700.
        chmod 644 "$DIR/odxproxy/config.conf.tmp"
        mv -f "$DIR/odxproxy/config.conf.tmp" "$DIR/odxproxy/config.conf"
        {
            if [ -n "$PROXY_BRAIN_URL" ]; then
                say "ODXBRAIN_URL=$PROXY_BRAIN_URL"
                say "ODXBRAIN_API_KEY=$PROXY_BRAIN_KEY"
            fi
        } | write_private "$DIR/env/odxproxy.env"
    fi
    if [ "$PILOT" = 1 ]; then
        {
            say "ODXPROXY_API_KEY=$P_PROXY_KEY"
            say "ODOO_API_KEY=$ODOO_KEY"
            [ -n "$P_DOCS_KEY" ] && say "ODXDOCS_API_KEY=$P_DOCS_KEY"
            say "ODXPILOT_PROPOSAL_KEY=$PROPOSAL_KEY"
        } | write_private "$DIR/env/odx-mcp.env"
        {
            [ -n "${LLM_KEY:-}" ] && say "$LLM_ENV=$LLM_KEY"
            true
        } | write_private "$DIR/env/orchestrator.env"
    fi
    # Answers worth offering again on a rerun (no keys)
    {
        say "PARTS=$PARTS"
        if [ "$PILOT" = 1 ]; then
            say "ODOO_URL=$ODOO_URL"
            say "ODOO_DB=$ODOO_DB"
            say "ODOO_USER_ID=$ODOO_USER_ID"
            say "LLM=$LLM"
            [ "$PROXY" = 0 ] && say "PROXY_URL=$PROBE_URL"
            [ "$BRAIN" = 0 ] && [ -n "$P_DOCS_URL" ] && say "DOCS_URL=$P_DOCS_URL"
        fi
        true
    } | write_private "$DIR/.install"
    ok "settings in $DIR (keys in env/, readable only by you)"
}

write_handover() {
    local ip
    if [ "$BRAIN" = 1 ] && [ "$BRAIN_BIND" = 0.0.0.0 ]; then
        ip=${IP:-$(this_ip)}
        {
            say "# ODXBrain + odxdocs on $ip: give this file to the ODXProxy and ODXPilot installs."
            say "BRAIN_URL=http://$ip:$BRAIN_PORT"
            say "BRAIN_KEY=$BRAIN_PROXY_KEY"
            say "DOCS_URL=http://$ip:$DOCS_PORT"
            say "DOCS_KEY=$DOCS_API_KEY"
        } | write_private "$DIR/odxpilot-handover-brain.env"
        HANDOVERS="$HANDOVERS $DIR/odxpilot-handover-brain.env"
    fi
    if [ "$PROXY" = 1 ] && [ "$PROXY_BIND" = 0.0.0.0 ]; then
        ip=${IP:-$(this_ip)}
        {
            say "# ODXProxy on $ip: give this file to the ODXPilot install."
            say "PROXY_URL=http://$ip:$PROXY_PORT"
            say "PROXY_KEY=$PROXY_API_KEY"
        } | write_private "$DIR/odxpilot-handover-proxy.env"
        HANDOVERS="$HANDOVERS $DIR/odxpilot-handover-proxy.env"
    fi
}

check_ports() {
    local busy=""
    if [ "$EXISTING" = 1 ]; then
        return # its own containers hold them
    fi
    [ "$PILOT" = 1 ] && port_busy "$ODXPILOT_PORT" && busy="$busy $ODXPILOT_PORT (web UI, ODXPILOT_PORT)"
    [ "$PROXY" = 1 ] && port_busy "$PROXY_PORT" && busy="$busy $PROXY_PORT (ODXProxy, PROXY_PORT)"
    [ "$BRAIN" = 1 ] && port_busy "$BRAIN_PORT" && busy="$busy $BRAIN_PORT (ODXBrain, BRAIN_PORT)"
    [ "$BRAIN" = 1 ] && port_busy "$DOCS_PORT" && busy="$busy $DOCS_PORT (odxdocs, DOCS_PORT)"
    [ -z "$busy" ] || die "already in use on this machine:$busy. Free them, or rerun with other ports, e.g. ODXPILOT_PORT=8701"
}

download_brain_files() {
    step "ODXBrain's model and corpus"
    local model="$DIR/models/bge-m3-f16.gguf"
    if [ -f "$model" ] && [ "$(sha256_of "$model")" = "$MODEL_SHA256" ]; then
        ok "model already there"
    else
        note "downloading the model (1.2 GB, resumes if cut)"
        curl -fL -C - --retry 3 -o "$model.part" "$MODEL_URL" || die "can't download the model from $MODEL_URL"
        [ "$(sha256_of "$model.part")" = "$MODEL_SHA256" ] || { rm -f "$model.part"; die "the model's checksum doesn't match; run again"; }
        mv -f "$model.part" "$model"
        ok "model (checksum matches)"
    fi
    chmod 644 "$model"
    if [ -f "$DIR/pack/manifest.json" ] && grep -q "\"corpus_version\": *\"$PACK_VERSION\"" "$DIR/pack/manifest.json"; then
        ok "corpus pack $PACK_VERSION already there"
    else
        local tmp
        tmp=$(mktemp -d)
        curl -fsSL -o "$tmp/pack.tar.gz" "$PACK_URL" || die "can't download the corpus pack"
        curl -fsSL -o "$tmp/pack.sha256" "$PACK_URL.sha256" || die "can't download the pack's checksum"
        [ "$(sha256_of "$tmp/pack.tar.gz")" = "$(cut -d' ' -f1 <"$tmp/pack.sha256")" ] || die "the corpus pack's checksum doesn't match"
        rm -rf "$DIR/pack" && mkdir -p "$DIR/pack" && tar xzf "$tmp/pack.tar.gz" -C "$DIR/pack"
        chmod 755 "$DIR/pack" && chmod 644 "$DIR/pack/"*
        rm -rf "$tmp"
        ok "corpus pack $PACK_VERSION (checksum matches)"
    fi
}

detect_odoo() {
    step "Asking Odoo for its version, through ODXProxy"
    local answer series label
    ODOO_VERSION=$(preset ODOO_VERSION || true)
    ODOO_EDITION=$(preset ODOO_EDITION || true)
    if [ -n "$ODOO_VERSION" ] && [ -n "$ODOO_EDITION" ]; then
        ok "Odoo $ODOO_VERSION $ODOO_EDITION (as given)"
        return
    fi
    if answer=$(curl -sS --max-time 40 -X POST "$PROBE_URL/api/odoo/version" \
        -H "x-api-key: $P_PROXY_KEY" -H 'Content-Type: application/json' \
        -d "{\"id\":\"odxpilot-install\",\"url\":\"$ODOO_URL\"}" 2>&1); then
        series=$(printf '%s' "$answer" | sed -n 's/.*"server_serie": *"\([^"]*\)".*/\1/p')
        label=$(printf '%s' "$answer" | sed -n 's/.*"server_version": *"\([^"]*\)".*/\1/p')
    fi
    if [ -n "${series:-}" ]; then
        ODOO_VERSION=$series
        case "$label" in *+e*) ODOO_EDITION=enterprise ;; *) ODOO_EDITION=community ;; esac
        ok "Odoo $ODOO_VERSION $ODOO_EDITION at $ODOO_URL"
        return
    fi
    warn "couldn't ask Odoo for its version: $(printf '%s' "${answer:-no answer}" | head -c 300)"
    case "${answer:-}" in
        *uthenticat* | *401*) warn "ODXProxy refused the key: check the ODXProxy key (and its PROXY_API_KEY)" ;;
    esac
    ask ODOO_VERSION "Odoo version, as Settings > About shows (e.g. 17.0, 18.0)"
    choose ODOO_EDITION "Odoo edition" community community enterprise
}

write_odxpilot_toml() {
    local api_note=""
    case "$ODOO_VERSION" in 1[0-8].* | saas~1[0-8].*) api_note=" (needed: Odoo before 19 is reached over ODXProxy v1)" ;; esac
    {
        say "# ODXPilot, written by the installer. Keys are named here and live in env/."
        say "[instance]"
        say "url = $(toml_str "$ODOO_URL")"
        say "db = $(toml_str "$ODOO_DB")"
        say "odoo_version = $(toml_str "$ODOO_VERSION")"
        say "edition = $(toml_str "$ODOO_EDITION")"
        say ""
        say "[odxproxy]"
        say "url = $(toml_str "$P_PROXY_URL")"
        say 'api_key = { env = "ODXPROXY_API_KEY" }'
        say ""
        if [ -n "$P_DOCS_URL" ]; then
            say "[odxdocs]"
            say "url = $(toml_str "$P_DOCS_URL")"
            say 'api_key = { env = "ODXDOCS_API_KEY" }'
            say ""
        fi
        say "# No sign-in yet: whoever uses this ODXPilot acts as this one role."
        say "[dev]"
        say "user = \"$(id -un | tr -cd 'A-Za-z0-9_.@-')\""
        say "role = $(toml_str "$ROLE")"
        say "approver_roles = [$(toml_str "$ROLE")]"
        say "company_id = 1"
        say ""
        say "[dev.connection]"
        say 'api_key = { env = "ODOO_API_KEY" }'
        say "user_id = $ODOO_USER_ID$( [ -n "$api_note" ] && printf '   #%s' "$api_note")"
        say ""
        say "[policies]"
        say 'dir = "policies"'
        say ""
        say "[uploads]"
        say 'dir = "/srv/odxpilot/uploads"'
        say ""
        say "[odx_mcp]"
        say "port = 8765"
        say 'proposal_key = { env = "ODXPILOT_PROPOSAL_KEY" }'
        say ""
        say "[orchestrator]"
        say "port = 8700"
        say ""
        say "[llm]"
        say "provider = $(toml_str "$LLM")"
        case "$LLM" in
            openai) say "openai_model = $(toml_str "$LLM_MODEL")" ;;
            claude) say "claude_model = $(toml_str "$LLM_MODEL")" ;;
            gemini) say "gemini_model = $(toml_str "$LLM_MODEL")" ;;
            endpoint)
                say ""
                say "[llm.endpoint]"
                say "base_url = $(toml_str "$LLM_URL")"
                say "model = $(toml_str "$LLM_MODEL")"
                say 'location = "premises"'
                say "operator = $(toml_str "$(hostname 2>/dev/null || echo this machine)")"
                say 'service = "OpenAI-compatible server"'
                [ -n "${LLM_KEY:-}" ] && say 'api_key = { env = "LLM_ENDPOINT_API_KEY" }'
                case "$LLM_URL" in
                    http://host.docker.internal* | http://localhost* | http://127.*) ;;
                    http://*)
                        say "allow_http = true   # plain HTTP to another machine: its key travels unencrypted"
                        warn "the LLM server is reached over plain HTTP: its key and your data travel unencrypted" ;;
                esac
                ;;
        esac
    } >"$DIR/odxpilot.toml"
    chmod 644 "$DIR/odxpilot.toml"
    ok "odxpilot.toml"
}

start_brain() {
    step "Starting ODXBrain + odxdocs"
    if [ ! -f "$DIR/sops/snapshot.json" ]; then
        quietly run --rm build || die "couldn't build the first SOP snapshot (above)"
        ok "first SOP snapshot"
    fi
    quietly up -d $RECREATE odxbrain odxdocs || die "ODXBrain + odxdocs didn't start (above)"
    wait_http "http://127.0.0.1:$BRAIN_PORT/ready" 300 || die "ODXBrain didn't get ready: docker compose -f $DIR/compose.yaml logs odxbrain"
    ok "ODXBrain ready"
    if [ "$EXISTING" = 1 ] || [ "$SOP_EXAMPLES" = 1 ]; then
        if quietly run --rm publish; then
            ok "SOPs published"
        else
            warn "publishing the SOPs failed: docker compose run --rm publish (in $DIR) shows why"
        fi
    fi
}

start_proxy() {
    step "Starting ODXProxy"
    quietly up -d $RECREATE odxproxy || die "ODXProxy didn't start (above)"
    wait_http "http://127.0.0.1:$PROXY_PORT/_/about" 120 || die "ODXProxy didn't start: docker compose -f $DIR/compose.yaml logs odxproxy (licence? internet?)"
    ok "ODXProxy up"
}

start_pilot() {
    step "Starting ODXPilot"
    quietly up -d $RECREATE odx-mcp orchestrator 2>/dev/null || true
    local i=0
    while [ "$i" -lt 240 ]; do
        if curl -fsS --max-time 3 "http://127.0.0.1:$ODXPILOT_PORT/health" 2>/dev/null | grep -q '"reachable":true'; then
            ok "ODXPilot up"
            return
        fi
        sleep 3
        i=$((i + 3))
    done
    warn "ODXPilot didn't come up. Its last words:"
    compose logs --tail 15 odx-mcp 2>&1 | grep -v -i "httpx" | sed 's/^/    /' >&2
    die "fix the cause, then: cd $DIR && docker compose up -d"
}

final_checks() {
    step "Checking the whole path"
    if compose exec -T orchestrator odxpilot-orchestrator check 2>&1 | grep -v '^INFO' | sed 's/^/  /'; then :; fi
    say ""
    note "the role '$ROLE' against your Odoo:"
    if compose exec -T odx-mcp odx-mcp check 2>&1 | grep -v -E '^INFO|httpx' | sed 's/^/  /'; then :; fi
}

summary() {
    step "Done"
    say "  Installed in $DIR (parts: $PARTS)."
    if [ "$PILOT" = 1 ]; then
        say ""
        say "  ${B}Open http://127.0.0.1:$ODXPILOT_PORT/${RST} and ask, for example:"
        say "    \"Which customer invoices are still unpaid?\""
        [ "$ROLE" = contact_editor ] && [ -n "$P_DOCS_URL" ] && say "    \"Create a new contact for ACME Research, Germany, info@acme.example\" (then Approve)"
    fi
    if [ -n "${HANDOVERS:-}" ]; then
        say ""
        say "  ${B}For the other machines${RST}: copy these files to them (they hold keys; delete them after):"
        for f in $HANDOVERS; do say "    $f"; done
        say "  and run this installer there, giving it the file when it asks."
    fi
    say ""
    say "  Day to day (in $DIR):"
    say "    docker compose ps | logs -f odx-mcp | down | up -d"
    [ "$BRAIN" = 1 ] && say "    docker compose run --rm publish     after editing sop-files/ (or: run --rm gui, the editor)"
    say "    rerun this installer to upgrade or reconfigure"
    say ""
}

main() {
    local arg
    while [ $# -gt 0 ]; do
        arg=$1
        case "$arg" in
            --dir) DIR=${2:?--dir needs a folder}; shift ;;
            --bundle) BUNDLE=${2:?--bundle needs a folder or URL}; shift ;;
            --yes | -y) ASSUME_YES=1 ;;
            --no-start) NO_START=1 ;;
            -h | --help) usage; exit 0 ;;
            --version) say "$INSTALLER_VERSION"; exit 0 ;;
            *) usage >&2; die "unknown option $arg" ;;
        esac
        shift
    done
    if [ -z "${DIR:-}" ]; then DIR=$(preset DIR || true); fi
    NO_START=${NO_START:-0}
    ODXPILOT_PORT=${ODXPILOT_PORT:-8700}
    PROXY_PORT=${PROXY_PORT:-6600}
    BRAIN_PORT=${BRAIN_PORT:-8080}
    DOCS_PORT=${DOCS_PORT:-8090}
    HANDOVERS=""
    IP=$(preset IP || true)
    LICENSE=""
    PROXY_BRAIN_URL=""; PROXY_BRAIN_KEY=""; P_DOCS_URL=""; P_DOCS_KEY=""
    BRAIN_BIND=127.0.0.1; PROXY_BIND=127.0.0.1; SOP_EXAMPLES=0; ROLE=reader; RECREATE=""
    BRAIN_HANDOVER=$(preset BRAIN_HANDOVER || true); LICENSE_DEFAULT=""

    say "${B}ODXPilot installer $INSTALLER_VERSION${RST}"
    open_tty
    preflight
    choose_dir

    if [ "$ACTION" = upgrade ]; then
        fetch_bundle
        step "Upgrading"
        quietly pull || die "couldn't pull the new images (above)"
        quietly up -d || die "couldn't start the upgraded stack (above)"
        ok "upgraded; settings and keys unchanged"
        exit 0
    fi

    RECREATE=""
    if [ "$ACTION" = reconfigure ]; then
        # settings are mounted files: the containers must be made again to read them
        RECREATE="--force-recreate"
        ODXI_PARTS=${ODXI_PARTS:-$(env_get "$DIR/.install" PARTS)}
        export ODXI_PARTS
    fi
    fetch_bundle
    ask_parts
    check_ports
    [ "$BRAIN" = 1 ] && ask_brain
    [ "$PROXY" = 1 ] && ask_proxy
    [ "$PILOT" = 1 ] && ask_pilot
    write_files
    write_handover

    if [ "$NO_START" = 1 ]; then
        [ "$PILOT" = 1 ] && { ODOO_VERSION=$(preset ODOO_VERSION || echo "18.0"); ODOO_EDITION=$(preset ODOO_EDITION || echo community); write_odxpilot_toml; }
        step "Files written; nothing started (--no-start)"
        exit 0
    fi

    step "Pulling the images"
    local pulled
    pulled=$(compose pull --ignore-pull-failures 2>&1) || true
    printf '%s\n' "$pulled" >>"$DIR/logs/install.log"
    if printf '%s' "$pulled" | grep -q " Error "; then
        printf '%s\n' "$pulled" | grep " Error " | sed 's/^ */    /' >&2
        warn "some images couldn't be pulled; going on with the ones this machine already has"
    else
        ok "images"
    fi

    if [ "$BRAIN" = 1 ]; then
        download_brain_files
        start_brain
    fi
    [ "$PROXY" = 1 ] && start_proxy
    if [ "$PILOT" = 1 ]; then
        detect_odoo
        write_odxpilot_toml
        start_pilot
        final_checks
    fi
    summary
}

main "$@"
