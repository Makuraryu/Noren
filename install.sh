#!/bin/sh

set -eu

repo="${NOREN_REPO:-Makuraryu/Noren}"
version="${NOREN_VERSION:-latest}"
install_dir="${NOREN_INSTALL_DIR:-}"
stage_file=""

fail() {
    printf 'noren installer: %s\n' "$*" >&2
    exit 1
}

cleanup() {
    if [ -n "$stage_file" ]; then
        rm -f "$stage_file"
    fi
    rm -rf "$download_dir"
}

download() {
    source_url=$1
    destination=$2

    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location \
            --retry 3 --output "$destination" "$source_url"
    elif command -v wget >/dev/null 2>&1; then
        wget --quiet --tries=3 --output-document="$destination" "$source_url"
    else
        fail "curl or wget is required"
    fi
}

[ "$(uname -s)" = "Linux" ] ||
    fail "only Linux is supported by this installer"

case "$(uname -m)" in
    x86_64 | amd64)
        architecture="x86_64"
        ;;
    aarch64 | arm64)
        architecture="aarch64"
        ;;
    *)
        fail "unsupported CPU architecture: $(uname -m)"
        ;;
esac

case "$version" in
    latest)
        release_url="https://github.com/$repo/releases/latest/download"
        ;;
    v*)
        release_url="https://github.com/$repo/releases/download/$version"
        ;;
    *)
        version="v$version"
        release_url="https://github.com/$repo/releases/download/$version"
        ;;
esac

asset="noren-linux-$architecture"
download_dir=$(mktemp -d "${TMPDIR:-/tmp}/noren-install.XXXXXX") ||
    fail "could not create a temporary directory"
trap cleanup EXIT HUP INT TERM

printf 'Downloading Noren %s for Linux %s...\n' "$version" "$architecture"
download "$release_url/$asset" "$download_dir/$asset"
download "$release_url/checksums.txt" "$download_dir/checksums.txt"

expected_checksum=$(
    awk -v asset="$asset" \
        '$2 == asset || $2 == "*" asset { print $1; exit }' \
        "$download_dir/checksums.txt"
)
[ -n "$expected_checksum" ] ||
    fail "the release checksum for $asset is missing"

if command -v sha256sum >/dev/null 2>&1; then
    actual_checksum=$(sha256sum "$download_dir/$asset" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
    actual_checksum=$(shasum -a 256 "$download_dir/$asset" | awk '{ print $1 }')
else
    fail "sha256sum or shasum is required to verify the download"
fi

[ "$actual_checksum" = "$expected_checksum" ] ||
    fail "checksum verification failed for $asset"

if [ -z "$install_dir" ]; then
    if [ -d /usr/local/bin ] && [ -w /usr/local/bin ]; then
        install_dir="/usr/local/bin"
    elif [ "$(id -u)" -eq 0 ]; then
        install_dir="/usr/local/bin"
    else
        : "${HOME:?HOME is required for a per-user installation}"
        install_dir="$HOME/.local/bin"
    fi
fi

mkdir -p "$install_dir" 2>/dev/null ||
    fail "cannot create $install_dir; rerun with sudo or set NOREN_INSTALL_DIR"
[ -w "$install_dir" ] ||
    fail "$install_dir is not writable; rerun with sudo or set NOREN_INSTALL_DIR"

stage_file=$(mktemp "$install_dir/.noren.XXXXXX") ||
    fail "could not stage Noren in $install_dir"
cp "$download_dir/$asset" "$stage_file"
chmod 755 "$stage_file"
mv -f "$stage_file" "$install_dir/noren"
stage_file=""

"$install_dir/noren" version
printf 'Installed Noren to %s\n' "$install_dir/noren"

case ":${PATH:-}:" in
    *":$install_dir:"*) ;;
    *)
        printf 'Add %s to PATH before running noren.\n' "$install_dir"
        ;;
esac
