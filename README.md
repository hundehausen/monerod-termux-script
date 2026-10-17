# monerod-termux-script

Installs the latest ARM build of the [Monero](https://www.getmonero.org/) daemon (`monerod`) on Android via Termux, verifying the download against the project's signed checksum list before anything is installed. Both the 32-bit ARMv7 and 64-bit ARMv8 builds are supported; the one matching the Termux userspace is chosen automatically.

## Requirements

- ARMv7 or ARMv8 Android device running [Termux](https://termux.dev/)
- `curl`, `tar`, `bzip2`, `sha256sum`, `awk`, `gpg` — installed automatically with `pkg` if missing

It refuses to run outside Termux (no writable `$PREFIX/bin`) or on other architectures.

## Usage

```bash
git clone https://github.com/hundehausen/monerod-termux-script.git
cd monerod-termux-script
bash install-monerod-termux.sh          # install or upgrade to the latest release
bash install-monerod-termux.sh --force  # reinstall even if already current
```

No root, no `sudo`; the binary goes to `$PREFIX/bin/monerod`, which is already on your `PATH` in Termux.

After it finishes:

```bash
monerod --version
monerod --detach                     # start syncing in the background
tail -f ~/.bitmonero/bitmonero.log   # watch sync progress
```

Blockchain data is stored in `~/.bitmonero` by default; the installer does not download it.

To remove it later:

```bash
monerod exit || pkill monerod     # graceful shutdown; pkill is the fallback (install procps)
rm -f "$PREFIX/bin/monerod"
rm -rf ~/.bitmonero               # optional: deletes the blockchain and wallet data
```

## Flags for a phone

```bash
monerod --detach \
  --prune-blockchain --sync-pruned-blocks \
  --enable-dns-blocklist --no-zmq --no-igd
```

- `--prune-blockchain` stores about a third of the chain instead of all of it. Enable it on the **first** sync: on a database that is already full it only prunes logically and the files do not shrink. Switching an existing install means deleting `~/.bitmonero` and resyncing.
- `--sync-pruned-blocks` downloads pruned blocks instead of full ones, which saves bandwidth during the initial sync. It is only useful together with `--prune-blockchain`.
- `--enable-dns-blocklist` drops peers on Monero's dynamic DNS blocklist. It needs a resolver that passes DNSSEC records; where validation fails, `monerod` logs warnings and the list is not applied.
- `--no-zmq` disables the ZMQ RPC server. Nothing on the phone uses it.
- `--no-igd` turns off UPnP port mapping. Mobile networks are usually behind NAT or CGNAT, so there is no port to map and no reason to ask the router.

Other defaults are sized for a desktop. These are worth changing on a phone:

| Flag | Effect |
| --- | --- |
| `--hide-my-port` | Do not advertise your IP as a peer. Incoming connections rarely reach a phone anyway. |
| `--max-txpool-weight 100000000` | Cap the transaction pool at 100 MB instead of the 648 MB default. |
| `--out-peers 8 --in-peers 4` | Fewer connections and radio wake-ups. The default is 12 outgoing and unlimited incoming. |
| `--block-sync-size 25` | Smaller sync batches mean lower peak RAM. The default is dynamic, up to 100 blocks. |
| `--max-log-file-size 10485760 --max-log-files 3` | Keep the log at roughly 30 MB. The defaults allow ~100 MB per file with many rotated copies. |
| `--check-updates disabled` | Let the installer handle upgrades, since that is the path that verifies signatures. The default only notifies. |


Typing all of that on a phone keyboard gets old. Put the flags in `~/.bitmonero/bitmonero.conf` (drop the leading `--`, write `1` for switches), then start with just `monerod --detach`:

```ini
prune-blockchain=1
sync-pruned-blocks=1
enable-dns-blocklist=1
no-zmq=1
no-igd=1
hide-my-port=1
max-txpool-weight=100000000
out-peers=8
in-peers=4
block-sync-size=25
max-log-file-size=10485760
max-log-files=3
check-updates=disabled
```

### Keeping it running

Android suspends background processes aggressively. Before a long sync, hold a wake lock so the CPU is not frozen when the screen turns off:

```bash
termux-wake-lock
monerod --detach
```

Also exempt Termux from battery optimization in Android settings; the wake lock is released if the process is killed. Stop the daemon with `monerod exit` rather than `pkill` so the database closes cleanly, and keep the phone on a charger for the initial sync.

## Which build gets installed

The installer picks the build for the Termux userspace, not just the CPU. A 32-bit Termux install on a 64-bit ARM device reports `armv8l` from `uname -m` but can only run the armv7 binary, so `$TERMUX_ARCH` takes precedence when it is set.

| `$TERMUX_ARCH` (or `uname -m` fallback) | Build |
| --- | --- |
| `aarch64`, `arm64` | `androidarm8` (64-bit) |
| `arm`, `armv7l`, `armv8l`, `armv7`, `armhf` | `androidarm7` (32-bit) |

To force a variant regardless of detection, set `MONEROD_ARCH=armv7` or `MONEROD_ARCH=armv8`.

## Re-running and resuming

Running the script again when the latest release is already installed exits without downloading anything; `--force` reinstalls anyway. The check compares the resolved release with the version reported by the installed `monerod`.

An interrupted download is kept in `${XDG_CACHE_HOME:-~/.cache}/monerod-termux` and resumed on the next run, so a dropped connection does not start the transfer over. If a resumed file turns out to be corrupt, it is discarded and downloaded from scratch. The cache is deleted after a successful install; set `CACHE_DIR` to put it elsewhere.

## What it does

1. Detects whether Termux is running the 32-bit (armv7) or 64-bit (armv8) userspace and resolves the corresponding `https://downloads.getmonero.org/cli/androidarm7` or `.../androidarm8` to the current release tarball
2. Downloads the tarball (resuming an earlier attempt) and the PGP-signed `hashes.txt` from getmonero.org
3. Imports binaryFate's signing key and verifies its fingerprint
4. Verifies the PGP signature over `hashes.txt`
5. Downloads the archive and checks it against the signed SHA256
6. Extracts only `monerod`, verifies it runs and reports the expected version, then installs it with a rollback copy of the previous binary in reserve

## Verification notes

The script fails closed. It will not install if any of these checks fail:

- **Transport.** Every request is HTTPS-only, with TLS 1.2 or newer, and redirects are held to the same rule (`--proto`/`--proto-redir`). The resolved download URL must be HTTPS and its filename must match the detected variant, `monero-android-armv7-v<version>.tar.bz2` or `monero-android-armv8-v<version>.tar.bz2`.
- **Key identity.** The signing key is fetched over HTTPS but only trusted if its fingerprint is exactly:

  ```
  81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92
  ```

  This is binaryFate's key, taken from `monero-project/monero/utils/gpg_keys/`. Trusting the key by fingerprint rather than by download source is what makes the HTTPS fetch of the key itself less critical.
- **Signature.** `hashes.txt` must carry a valid signature from that key. Verification uses GnuPG's machine-readable status output, so it checks the actual signing fingerprint instead of matching log text.
- **Checksum.** The archive's SHA256 must match the entry for that exact filename in the signed `hashes.txt`. On mismatch both hashes are printed and the script exits; a corrupt *resumed* download is deleted and retried once from scratch first.
- **Archive contents.** Only the `monerod` member is extracted. Absolute paths and members containing `..` are rejected before extraction.
- **Executable before install.** The extracted binary is run from a staging path next to its destination and must report the resolved version. Only then is it moved into place, with the previous binary kept as a rollback copy until the installed one has also run successfully.
- **Missing release entry.** If `hashes.txt` has no entry for the archive yet, the release is probably still publishing and the script tells you to retry later rather than skipping verification.

An isolated `GNUPGHOME` is created inside the temporary directory, so your existing keyring is never touched. The temporary extraction directory, any staged install file, and any rollback copy are removed on exit, including on failure or Ctrl-C. An interrupted download is deliberately left in the cache so the next run can resume it.

## Environment variables

All are optional overrides:

| Variable | Default |
| --- | --- |
| `MONEROD_ARCH` | `auto` (detect from `$TERMUX_ARCH` / `uname -m`); `armv7` or `armv8` forces a variant |
| `DOWNLOAD_URL` | the detected variant's URL, `https://downloads.getmonero.org/cli/androidarm7` or `.../androidarm8` |
| `HASHES_URL` | `https://www.getmonero.org/downloads/hashes.txt` |
| `PGP_KEY_URL` | `https://raw.githubusercontent.com/monero-project/monero/master/utils/gpg_keys/binaryfate.asc` |
| `CACHE_DIR` | `${XDG_CACHE_HOME:-~/.cache}/monerod-termux` |
| `MAX_DOWNLOAD_MB` | `512` |

`DOWNLOAD_URL` can point at a specific release tarball to pin a version, or at a mirror; the HTTPS and filename checks still apply, and the filename must match the selected variant (set `MONEROD_ARCH` if you intentionally want the other one). `CACHE_DIR` is where interrupted downloads are resumed from, and `MAX_DOWNLOAD_MB` is a sanity cap on the archive size rather than a disk-space requirement.

## Scope

This installs the daemon only. It does not install `monero-wallet-cli`, `monero-wallet-gui`, or set up a service, and it does not modify your shell configuration. On Android, a full node is best run with `--detach` and kept on a charger.

## License

The script is provided as-is under the MIT License. Monero itself is licensed separately (BSD-3-Clause); see the [Monero repository](https://github.com/monero-project/monero).
