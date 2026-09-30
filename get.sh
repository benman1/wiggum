#!/usr/bin/env bash
# One-line installer:
#   curl -fsSL https://raw.githubusercontent.com/benman1/wiggum/main/get.sh | bash
#
# Downloads the repo as a tarball into a temporary directory and runs install.sh from it.
# Nothing stays behind except what install.sh installs. install.sh asks for sudo only if the
# install prefix is not writable.
#
# Overrides (mostly for tests): WIGGUM_REPO (owner/name), WIGGUM_REF (branch or tag),
# WIGGUM_TARBALL_URL (any URL curl can read, including file://), WIGGUM_PREFIX (passed on to
# install.sh).
set -euo pipefail

repo="${WIGGUM_REPO:-benman1/wiggum}"
ref="${WIGGUM_REF:-main}"
url="${WIGGUM_TARBALL_URL:-https://github.com/$repo/archive/$ref.tar.gz}"

for tool in curl tar bash; do
    command -v "$tool" >/dev/null 2>&1 || { echo "wiggum: '$tool' is required" >&2; exit 1; }
done

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Downloading wiggum ($ref)..."
curl -fsSL "$url" | tar -xz -C "$tmp" --strip-components=1

if [[ ! -f "$tmp/install.sh" ]]; then
    echo "wiggum: the download has no install.sh; check WIGGUM_REPO and WIGGUM_REF" >&2
    exit 1
fi

# Give install.sh the terminal, so a sudo prompt can read a password when this script was piped in.
if { : </dev/tty; } 2>/dev/null; then
    bash "$tmp/install.sh" </dev/tty
else
    bash "$tmp/install.sh"
fi
