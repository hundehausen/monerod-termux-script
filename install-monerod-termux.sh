#!/usr/bin/env bash
#
# install-monerod-termux.sh
#
# Installs the latest Monero daemon (monerod) for 32-bit or 64-bit ARM
# Android/Termux, choosing the build that matches the Termux userspace:
#   1. detects ARMv7 vs ARMv8 and follows
#      https://downloads.getmonero.org/cli/androidarm7 (or .../androidarm8)
#      to the current tarball
#   2. downloads it and the PGP-signed SHA256 list from getmonero.org
#   3. verifies the PGP signature on that list with binaryFate's key
#   4. verifies the archive checksum (refuses to install on mismatch)
#   5. extracts only monerod from the .tar.bz2
#   6. installs it as $PREFIX/bin/monerod and removes all temporary files
#
# Usage:  bash install-monerod-termux.sh [--force]
#
# The armv7/armv8 choice follows $TERMUX_ARCH (falling back to uname -m), so a
# 32-bit Termux install on 64-bit hardware gets the armv7 build. Override it
# with MONEROD_ARCH=armv7 or MONEROD_ARCH=armv8.
#
# Re-running when the latest version is already installed does nothing unless
# --force is given. An interrupted download is kept in a cache directory
# (default: ~/.cache/monerod-termux) so the next run resumes it; the cache is
# cleared after a successful install.
#
# hashes.txt is a clearsigned message from binaryFate. The signing key is
# downloaded from the Monero source repository and only trusted if its
# fingerprint matches the expected one below.

set -euo pipefail

# Under set -e a failing command would otherwise end the script without context.
# shellcheck disable=SC2154  # rc is assigned by the trap itself
trap 'rc=$?; printf "\033[1;31merror:\033[0m failure at line %s (exit %s)\n" "$LINENO" "$rc" >&2; exit "$rc"' ERR

HASHES_URL="${HASHES_URL:-https://www.getmonero.org/downloads/hashes.txt}"
PGP_KEY_URL="${PGP_KEY_URL:-https://raw.githubusercontent.com/monero-project/monero/master/utils/gpg_keys/binaryfate.asc}"
PGP_KEY_FPR="81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92" # binaryFate
CACHE_DIR="${CACHE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/monerod-termux}"
MAX_DOWNLOAD_MB="${MAX_DOWNLOAD_MB:-512}"

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

checksum_of() { sha256sum "$1" | awk '{ print $1 }'; }
size_of()     { wc -c < "$1" | tr -d '[:space:]'; }

# Print the expected and actual hashes, then fail.
verify_checksum() {
  local actual
  actual="$(checksum_of "$1")"
  if [[ "$actual" == "${expected,,}" ]]; then
    return 0
  fi
  printf '  expected: %s\n  actual:   %s\n' "$expected" "$actual" >&2
  return 1
}

[[ "$MAX_DOWNLOAD_MB" =~ ^[0-9]+$ ]] \
  || die "MAX_DOWNLOAD_MB must be a whole number of megabytes"

force=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    *) die "unknown argument: $arg (usage: bash $0 [--force])" ;;
  esac
done

# Every transfer is HTTPS-only: --proto covers the initial URL and
# --proto-redir follows redirects, so an http hop cannot creep into the chain.
curl_opts=(--proto '=https' --proto-redir '=https' --tlsv1.2 --connect-timeout 30)
retry_opts=(--retry 3 --retry-delay 2 --retry-all-errors)

# --- environment checks ----------------------------------------------------
[[ -n "${PREFIX:-}" && -d "${PREFIX}/bin" ]] \
  || die "PREFIX is not set - run this inside Termux"
[[ -w "${PREFIX}/bin" ]] \
  || die "${PREFIX}/bin is not writable"

# Pick the release that matches the Termux userspace, not just the CPU: a
# 32-bit Termux install on a 64-bit ARM device reports armv8l/armv7l from
# uname but can only run the armv7 build, so TERMUX_ARCH wins when it is set.
detect_arch() {
  case "$1" in
    aarch64|arm64)                 echo armv8 ;;
    armv7l|armv8l|armv7|arm|armhf) echo armv7 ;;
    *) return 1 ;;
  esac
}

case "${MONEROD_ARCH:-auto}" in
  auto)
    arch="$(detect_arch "${TERMUX_ARCH:-$(uname -m)}")" \
      || die "unsupported architecture '${TERMUX_ARCH:-$(uname -m)}' - this script needs 32-bit ARM (armv7) or 64-bit ARM (armv8)"
    ;;
  armv7|armv8)
    arch="$MONEROD_ARCH"
    ;;
  *)
    die "MONEROD_ARCH must be auto, armv7 or armv8 (got '$MONEROD_ARCH')"
    ;;
esac
DOWNLOAD_URL="${DOWNLOAD_URL:-https://downloads.getmonero.org/cli/android${arch}}"

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

dest="$PREFIX/bin/monerod"

# --- temporary workspace (always removed) ----------------------------------
work_parent="${TMPDIR:-${PREFIX}/tmp}"
mkdir -p -- "$work_parent"
tmpdir="$(mktemp -d "$work_parent/monerod.XXXXXX")"
install_tmp=""
backup=""
cleanup() {
  [[ -n "$tmpdir" ]] && rm -rf -- "$tmpdir"
  [[ -n "$install_tmp" ]] && rm -f -- "$install_tmp"
  [[ -n "$backup" ]] && rm -f -- "$backup"
  return 0
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- resolve redirect ------------------------------------------------------
say "resolving the latest Android $arch build"
if final_url="$(curl -fsSIL "${curl_opts[@]}" "${retry_opts[@]}" -o /dev/null \
    -w '%{url_effective}' "$DOWNLOAD_URL" 2>/dev/null)"; then
  :
else
  # Some HTTP proxies reject HEAD; fall back to a one-byte ranged GET.
  final_url="$(curl -fsSL "${curl_opts[@]}" "${retry_opts[@]}" -r 0-0 -o /dev/null \
    -w '%{url_effective}' "$DOWNLOAD_URL")" \
    || die "could not resolve $DOWNLOAD_URL"
fi
[[ "$final_url" == https://* ]] \
  || die "refusing non-HTTPS download URL: $final_url"

archive="${final_url##*/}"
[[ "$archive" == "monero-android-$arch-v"*.tar.bz2 ]] \
  || die "unexpected archive name: $archive (expected a monero-android-$arch build)"
version="${archive#monero-android-"$arch"-v}"
version="${version%.tar.bz2}"
say "latest version: $version"

# --- stop early if this version is already installed -----------------------
installed_version=""
if [[ -x "$dest" ]]; then
  if installed_out=$("$dest" --version 2>/dev/null); then
    if [[ "$installed_out" =~ v([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
      installed_version="${BASH_REMATCH[1]}"
    fi
  fi
fi

if [[ "$installed_version" == "$version" ]]; then
  if (( force )); then
    say "monerod $version is already installed - reinstalling because of --force"
  else
    say "monerod $version is already installed at $dest"
    say "nothing to do (use --force to reinstall)"
    exit 0
  fi
fi

# --- signature verification ------------------------------------------------
say "fetching checksums and signing key"
curl -fsSL "${curl_opts[@]}" "${retry_opts[@]}" -o "$tmpdir/hashes.txt" "$HASHES_URL" \
  || die "could not download $HASHES_URL"
curl -fsSL "${curl_opts[@]}" "${retry_opts[@]}" -o "$tmpdir/binaryfate.asc" "$PGP_KEY_URL" \
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

# --- download (resumable) --------------------------------------------------
download_archive() { # $1 = 1 to resume, $2 = output file
  local resume="$1" out="$2"
  local opts=(-fL "${curl_opts[@]}" --retry 5 --retry-delay 3 --retry-all-errors
    --speed-limit 1024 --speed-time 60 --progress-bar
    --max-filesize "$((MAX_DOWNLOAD_MB * 1024 * 1024))")
  if (( resume )); then
    opts+=(-C -)
  fi
  curl "${opts[@]}" -o "$out" "$final_url"
}

download_or_die() { # $1 = 1 to resume the partial file
  local resume="$1" rc=0
  download_archive "$resume" "$partial" || rc=$?
  if (( rc == 33 )) && (( resume )); then
    # 33 = the server ignored the Range request; a fresh download still works.
    say "the server does not support resuming - starting over"
    rm -f -- "$partial"
    rc=0
    download_archive 0 "$partial" || rc=$?
  fi
  if (( rc == 63 )); then
    die "the archive is larger than MAX_DOWNLOAD_MB ($MAX_DOWNLOAD_MB MB) - raise it if that is unexpected"
  fi
  if (( rc != 0 )); then
    if [[ -f "$partial" ]]; then
      die "download failed; $partial is kept so a rerun can resume it"
    fi
    die "download failed"
  fi
}

mkdir -p -- "$CACHE_DIR"
archive_path="$CACHE_DIR/$archive"
partial="$archive_path.part"

if [[ -f "$archive_path" ]]; then
  if [[ "$(checksum_of "$archive_path")" == "${expected,,}" ]]; then
    say "using the verified download from $archive_path"
  else
    warn "discarding the cached archive - checksum does not match"
    rm -f -- "$archive_path"
  fi
fi

if [[ ! -f "$archive_path" ]]; then
  # Learn the real size when the server advertises it, so a partial file that
  # is already complete is not "resumed" into a range error. If the size is
  # unknown, the checksum still decides.
  remote_size=""
  if head="$(curl -fsSI "${curl_opts[@]}" "${retry_opts[@]}" "$final_url" 2>/dev/null)"; then
    remote_size="$(printf '%s\n' "$head" | awk '
      tolower($1) == "content-length:" { v = $2 }
      END { sub(/\r$/, "", v); if (v ~ /^[0-9]+$/) print v }')"
  fi

  resumed=0
  if [[ -f "$partial" ]]; then
    resumed=1
    if [[ -n "$remote_size" ]] && (( $(size_of "$partial") > remote_size )); then
      warn "the partial download is larger than the file on the server - starting over"
      rm -f -- "$partial"
      resumed=0
    fi
  fi

  if [[ -f "$partial" && -n "$remote_size" && "$(size_of "$partial")" == "$remote_size" ]]; then
    say "found a complete download in $partial"
  else
    if (( resumed )); then
      say "resuming download at $(size_of "$partial") of ${remote_size:-?} bytes"
    else
      say "downloading $archive"
    fi
    download_or_die "$resumed"
  fi

  if ! verify_checksum "$partial"; then
    if (( resumed )); then
      # Usually a proxy error page appended to an old partial download.
      say "the resumed download is corrupt - starting over"
      rm -f -- "$partial"
      download_or_die 0
      verify_checksum "$partial" || die "checksum mismatch - refusing to install"
    else
      die "checksum mismatch - refusing to install"
    fi
  fi
  say "checksum OK"
  mv -f -- "$partial" "$archive_path"
fi

# --- extract only monerod --------------------------------------------------
say "extracting monerod"
# Write the file list to disk first. Piping `tar -t` into `awk ... exit` can
# make tar die of SIGPIPE; with `set -o pipefail` that silently kills the
# script (this is the usual cause of "crashes after extracting monerod").
tar -tjf "$archive_path" > "$tmpdir/listing.txt" \
  || die "could not read $archive_path"

member=$(awk '$0 == "monerod" || $0 ~ /\/monerod$/ { print; exit }' "$tmpdir/listing.txt")
[[ -n "$member" ]] || die "monerod was not found inside $archive_path"
[[ "$member" != /* && "$member" != *..* ]] \
  || die "refusing suspicious archive member: $member"

tar -xjf "$archive_path" -C "$tmpdir" -- "$member" \
  || die "could not extract $member"
src="$tmpdir/$member"
[[ -f "$src" ]] || die "extraction produced no monerod binary"

# --- install ---------------------------------------------------------------
say "installing to $dest"
staged="${dest}.new.$$"
install_tmp="$staged"
cp -- "$src" "$staged"
chmod 0755 "$staged"

# Never replace a working daemon with a binary that cannot run. monerod
# --version reports e.g. "Monero 'Fluorine Fermi' (v0.18.5.4-release)", so the
# resolved version doubles as a check that this is the artifact we expected.
staged_out=""
if ! staged_out=$("$staged" --version 2>&1) || [[ "$staged_out" != *"v$version"* ]]; then
  die "the downloaded monerod did not run or did not report v$version - nothing was changed"
fi

backup=""
if [[ -e "$dest" ]]; then
  backup="${dest}.old.$$"
  cp -p -- "$dest" "$backup" || die "could not back up the existing monerod"
fi

mv -f -- "$staged" "$dest" || die "could not move the new monerod into place"
install_tmp=""

# Re-check what is actually installed and roll back if it misbehaves.
if ! version_out=$("$dest" --version 2>&1); then
  if [[ -n "$backup" ]]; then
    if mv -f -- "$backup" "$dest"; then
      backup=""
      die "the installed monerod failed to run - the previous binary was restored"
    fi
    kept="$backup"
    backup="" # keep the only remaining copy; cleanup must not delete it
    die "the installed monerod failed to run - the previous binary is kept at $kept"
  fi
  rm -f -- "$dest"
  die "the installed monerod failed to run - it was removed (there was no previous binary)"
fi
[[ -n "$backup" ]] && rm -f -- "$backup"
backup=""

rm -f -- "$archive_path" "$partial"
rmdir -- "$CACHE_DIR" 2>/dev/null || true

say "installed: ${version_out%%$'\n'*}"
say "done - temporary and cached download files removed"
