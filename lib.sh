# Shared helpers for pi-install.sh and vps-install.sh.
# Sourced, not executed.

set -euo pipefail

note() { printf '\n=== %s ===\n' "$*" >&2; }
log()  { printf '  %s\n' "$*" >&2; }
warn() { printf '  WARN: %s\n' "$*" >&2; }
die()  { printf '  FATAL: %s\n' "$*" >&2; exit 1; }

require_root() {
    [ "$(id -u)" -eq 0 ] || exec sudo -E "$0" "$@"
}

# render_template SRC DST [MODE]
# Substitutes ${VAR} from the environment via envsubst, writes to DST,
# preserves DST if it already differs from rendered output ONLY when
# DST has no template markers (i.e. it was hand-edited).
render_template() {
    local src=$1 dst=$2 mode=${3:-0644}
    local tmp; tmp=$(mktemp)
    envsubst < "$src" > "$tmp"
    if [ -e "$dst" ] && ! grep -q '\${' "$dst" 2>/dev/null && ! cmp -s "$tmp" "$dst"; then
        log "  $dst differs (likely hand-edited) — leaving as-is"
        rm -f "$tmp"; return 0
    fi
    install -m "$mode" "$tmp" "$dst"
    rm -f "$tmp"
    log "  rendered: $dst"
}

# install_file SRC DST [MODE] — like `install`, but only when content differs.
install_file() {
    local src=$1 dst=$2 mode=${3:-0644}
    if [ -e "$dst" ] && cmp -s "$src" "$dst"; then
        log "  unchanged: $dst"; return 0
    fi
    install -m "$mode" "$src" "$dst"
    log "  installed: $dst"
}

# install_ss_rust ARCH BIN_NAME — install sslocal or ssserver from upstream release tarball.
# ARCH is e.g. aarch64-unknown-linux-gnu; BIN_NAME is sslocal or ssserver.
install_ss_rust() {
    local arch=$1 bin=$2 ver=${SS_RUST_VERSION:?must set SS_RUST_VERSION}
    local target="/usr/local/bin/$bin"
    if [ -x "$target" ] && "$target" --version 2>&1 | grep -q "${ver#v}"; then
        log "  $bin already at $ver"; return 0
    fi
    local url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${ver}/shadowsocks-${ver}.${arch}.tar.xz"
    local cache="/tmp/ss-rust-${ver}-${arch}.tar.xz"
    if [ -s "$cache" ]; then
        log "  cached: $cache"
    else
        log "  fetching $url"
        curl -fL --retry 3 --retry-delay 2 -o "$cache" "$url" \
            || die "failed to download $url"
    fi
    tar -xJf "$cache" -C /tmp
    install -m 0755 "/tmp/$bin" "$target"
    log "  installed $target ($ver)"
}

require_ipv4() {
    local name=$1 value=$2
    if ! awk -v ip="$value" 'BEGIN {
        n = split(ip, o, ".")
        if (n != 4) exit 1
        for (i = 1; i <= 4; i++) {
            if (o[i] !~ /^[0-9]+$/ || o[i] < 0 || o[i] > 255) exit 1
        }
    }'; then
        die "$name must be an IPv4 address for the Pi full-tunnel bypass routes; got '$value'"
    fi
}
