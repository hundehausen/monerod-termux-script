#!/usr/bin/env bash
#
# install-monerod-termux.sh
#
# Installs the latest Monero daemon (monerod) for 64-bit ARM Android/Termux:
#   1. follows https://downloads.getmonero.org/cli/androidarm8 to the current tarball
#   2. downloads it and the PGP-signed SHA256 list from getmonero.org
#   3. verifies the PGP signature on that list with binaryFate's key
#   4. verifies the archive checksum (refuses to install on mismatch)
#   5. extracts only monerod from the .tar.bz2
#   6. installs it as $PREFIX/bin/monerod and removes all temporary files
#
# Usage:  bash install-monerod-termux.sh
#
# hashes.txt is a clearsigned message from binaryFate. The signing key is
# downloaded from the Monero source repository and only trusted if its
# fingerprint matches the expected one below.

set -euo pipefail

# Under set -e a failing command would otherwise end the script without context.
# shellcheck disable=SC2154  # rc is assigned by the trap itself
trap 'rc=$?; printf "\033[1;31merror:\033[0m failure at line %s (exit %s)\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

DOWNLOAD_URL="${DOWNLOAD_URL:-https://downloads.getmonero.org/cli/androidarm8}"
HASHES_URL="${HASHES_URL:-https://www.getmonero.org/downloads/hashes.txt}"
PGP_KEY_URL="${PGP_KEY_URL:-https://raw.githubusercontent.com/monero-project/monero/master/utils/gpg_keys/binaryfate.asc}"
PGP_KEY_FPR="81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92" # binaryFate
MIN_FREE_KB=$((250 * 1024)) # download + extracted binary + slack

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

# --- environment checks ----------------------------------------------------
[[ -n "${PREFIX:-}" && -d "${PREFIX}/bin" ]] \
  || die "PREFIX is not set - run this inside Termux"
[[ -w "${PREFIX}/bin" ]] \
  || die "${PREFIX}/bin is not writable"

case "$(uname -m)" in
  aarch64|arm64) ;;
  *) die "this build needs 64-bit ARM (aarch64), but this device reports '$(uname -m)'" ;;
esac

missing=()
for cmd in curl tar bzip2 sha256sum awk gpg; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if (( ${#missing[@]} )); then
  command -v pkg >/dev/null 2>&1 \
    || die "missing ${missing[*]} and 'pkg' is not available; install them manually"
  pkgs=()
  for cmd in "${missing[@]}"; do
    case "$cmd" in
      sha256sum) pkgs+=(coreutils) ;;
      awk)       pkgs+=(gawk) ;;
      gpg)       pkgs+=(gnupg) ;;
      *)         pkgs+=("$cmd") ;;
    esac
  done
  say "installing missing tools: ${pkgs[*]}"
  pkg install -y "${pkgs[@]}" || die "could not install ${pkgs[*]}"
fi

# --- temporary workspace (always removed) ----------------------------------
work_parent="${TMPDIR:-${PREFIX}/tmp}"
mkdir -p -- "$work_parent"
tmpdir="$(mktemp -d "$work_parent/monerod.XXXXXX")"
install_tmp=""
cleanup() {
  [[ -n "$tmpdir" ]] && rm -rf -- "$tmpdir"
  [[ -n "$install_tmp" ]] && rm -f -- "$install_tmp"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

avail_kb=$(df -Pk "$tmpdir" | awk 'NR==2 { print $4 }')
(( avail_kb >= MIN_FREE_KB )) \
  || die "not enough free space: need about $((MIN_FREE_KB / 1024)) MB, have $((avail_kb / 1024)) MB"

# --- resolve redirect ------------------------------------------------------
say "resolving the latest Android armv8 build"
final_url="$(curl -fsSIL --retry 3 --connect-timeout 30 -o /dev/null \
  -w '%{url_effective}' "$DOWNLOAD_URL" 2>/dev/null)" || {
  # Some HTTP proxies reject HEAD; fall back to a one-byte ranged GET.
  final_url="$(curl -fsSL --retry 3 --connect-timeout 30 -r 0-0 -o /dev/null \
    -w '%{url_effective}' "$DOWNLOAD_URL")" \
    || die "could not resolve $DOWNLOAD_URL"
}
[[ "$final_url" == https://* ]] \
  || die "refusing non-HTTPS download URL: $final_url"

archive="${final_url##*/}"
[[ "$archive" == monero-android-armv8-v*.tar.bz2 ]] \
  || die "unexpected archive name: $archive"
version="${archive#monero-android-armv8-v}"
version="${version%.tar.bz2}"
say "latest version: $version"

# --- signature verification ------------------------------------------------
say "fetching checksums and signing key"
curl -fsSL --retry 3 --connect-timeout 30 -o "$tmpdir/hashes.txt" "$HASHES_URL" \
  || die "could not download $HASHES_URL"
curl -fsSL --retry 3 --connect-timeout 30 -o "$tmpdir/binaryfate.asc" "$PGP_KEY_URL" \
  || die "could not download the signing key"

say "verifying PGP signature on hashes.txt"
mkdir -m 700 "$tmpdir/gnupg"
export GNUPGHOME="$tmpdir/gnupg"

gpg --batch --quiet --import "$tmpdir/binaryfate.asc" \
  || die "could not import the signing key"

# The HTTPS download is not enough by itself: only trust the key if its
# fingerprint is the one expected for binaryFate.
if ! gpg --batch --with-colons --fingerprint 2>/dev/null \
    | awk -F: -v fpr="$PGP_KEY_FPR" \
        '$1 == "fpr" && toupper($10) == fpr { found = 1 } END { exit !found }'; then
  die "signing key does not match the expected fingerprint $PGP_KEY_FPR"
fi

# --status-fd makes the result machine-readable. VALIDSIG lists the signing
# key fingerprint and, for subkeys, the primary key fingerprint last.
if ! gpg --batch --status-fd 1 --verify "$tmpdir/hashes.txt" 2>"$tmpdir/gpg.err" \
    | awk -v fpr="$PGP_KEY_FPR" \
        '/^\[GNUPG:\] VALIDSIG / {
           if (toupper($3) == fpr || toupper($NF) == fpr) ok = 1
         }
         END { exit !ok }'; then
  sed 's/^/  /' "$tmpdir/gpg.err" >&2
  die "PGP signature verification failed - refusing to install"
fi
say "PGP signature OK"

# --- checksum lookup -------------------------------------------------------
expected=$(awk -v f="$archive" '$2 == f { print $1; exit }' "$tmpdir/hashes.txt")
[[ -n "$expected" ]] \
  || die "hashes.txt has no entry for $archive (the release may still be publishing); try again later"
[[ "$expected" =~ ^[0-9a-fA-F]{64}$ ]] \
  || die "malformed checksum entry for $archive"

# --- download --------------------------------------------------------------
say "downloading $archive"
curl -fL --retry 3 --retry-delay 2 --connect-timeout 30 --progress-bar \
  -o "$tmpdir/$archive" "$final_url" || die "download failed"

# --- checksum verification -------------------------------------------------
say "verifying SHA256"
actual=$(sha256sum "$tmpdir/$archive" | awk '{ print $1 }')
if [[ "${actual,,}" != "${expected,,}" ]]; then
  printf '  expected: %s\n  actual:   %s\n' "$expected" "$actual" >&2
  die "checksum mismatch - refusing to install"
fi
say "checksum OK"

# --- extract only monerod --------------------------------------------------
say "extracting monerod"
# Write the file list to disk first. Piping `tar -t` into `awk ... exit` can
# make tar die of SIGPIPE; with `set -o pipefail` that silently kills the
# script (this is the usual cause of "crashes after extracting monerod").
tar -tjf "$tmpdir/$archive" > "$tmpdir/listing.txt" \
  || die "could not read $archive"

member=$(awk '$0 == "monerod" || $0 ~ /\/monerod$/ { print; exit }' "$tmpdir/listing.txt")
[[ -n "$member" ]] || die "monerod was not found inside $archive"
[[ "$member" != /* && "$member" != *..* ]] \
  || die "refusing suspicious archive member: $member"

tar -xjf "$tmpdir/$archive" -C "$tmpdir" -- "$member" \
  || die "could not extract $member"
src="$tmpdir/$member"
[[ -f "$src" ]] || die "extraction produced no monerod binary"

# --- install ---------------------------------------------------------------
dest="$PREFIX/bin/monerod"
say "installing to $dest"
install_tmp="$PREFIX/bin/.monerod.new.$$"
cp -- "$src" "$install_tmp"
chmod 0755 "$install_tmp"
mv -f -- "$install_tmp" "$dest"
install_tmp=""

hash -r
if version_out=$("$dest" --version 2>&1); then
  say "installed: ${version_out%%$'\n'*}"
else
  warn "monerod is installed at $dest but could not be executed here"
fi

say "done - temporary download and extraction files removed"
