# monerod-termux-script

Installs the latest 64-bit ARM build of the [Monero](https://www.getmonero.org/) daemon (`monerod`) on Android via Termux, verifying the download against the project's signed checksum list before anything is installed.

## Requirements

- 64-bit ARM Android device (`aarch64`) running [Termux](https://termux.dev/)
- About 250 MB of free space for the download and extraction
- `curl`, `tar`, `bzip2`, `sha256sum`, `awk`, `gpg` — installed automatically with `pkg` if missing

It refuses to run outside Termux (no writable `$PREFIX/bin`) or on other architectures.

## Usage

```bash
git clone https://github.com/hundehausen/monerod-termux-script.git
cd monerod-termux-script
bash install-monerod-termux.sh
```

No root, no `sudo`; the binary goes to `$PREFIX/bin/monerod`, which is already on your `PATH` in Termux.

After it finishes:

```bash
monerod --version
monerod --detach                     # start syncing in the background
tail -f ~/.bitmonero/bitmonero.log   # watch sync progress
```

Data is kept in `~/.bitmonero` by default; a full sync takes a while and needs several GB of storage.

To remove it later:

```bash
pkill monerod                     # install procps if pkill is unavailable
rm -f "$PREFIX/bin/monerod"
rm -rf ~/.bitmonero               # optional: deletes the blockchain and wallet data
```

## What it does

1. Resolves `https://downloads.getmonero.org/cli/androidarm8` to the current release tarball
2. Downloads the tarball and the PGP-signed `hashes.txt` from getmonero.org
3. Imports binaryFate's signing key and verifies its fingerprint
4. Verifies the PGP signature over `hashes.txt`
5. Downloads the archive and checks it against the signed SHA256
6. Extracts only `monerod`, installs it, and cleans up temporary files

## Verification notes

The script fails closed. It will not install if any of these checks fail:

- **Transport.** The resolved download URL must be HTTPS, and its filename must look like `monero-android-armv8-v<version>.tar.bz2`.
- **Key identity.** The signing key is fetched over HTTPS but only trusted if its fingerprint is exactly:

  ```
  81AC591FE9C4B65C5806AFC3F0AF4D462A0BDF92
  ```

  This is binaryFate's key, taken from `monero-project/monero/utils/gpg_keys/`. Trusting the key by fingerprint rather than by download source is what makes the HTTPS fetch of the key itself less critical.
- **Signature.** `hashes.txt` must carry a valid signature from that key. Verification uses GnuPG's machine-readable status output, so it checks the actual signing fingerprint instead of matching log text.
- **Checksum.** The archive's SHA256 must match the entry for that exact filename in the signed `hashes.txt`. On mismatch both hashes are printed and the script exits.
- **Archive contents.** Only the `monerod` member is extracted. Absolute paths and members containing `..` are rejected before extraction, and the binary is written atomically (copy to a temp name, then `mv`).
- **Missing release entry.** If `hashes.txt` has no entry for the archive yet, the release is probably still publishing and the script tells you to retry later rather than skipping verification.

An isolated `GNUPGHOME` is created inside the temporary directory, so your existing keyring is never touched. The temporary directory (and any partial install file) is removed on exit, including on failure or Ctrl-C.

## Environment variables

All are optional overrides:

| Variable | Default |
| --- | --- |
| `DOWNLOAD_URL` | `https://downloads.getmonero.org/cli/androidarm8` |
| `HASHES_URL` | `https://www.getmonero.org/downloads/hashes.txt` |
| `PGP_KEY_URL` | `https://raw.githubusercontent.com/monero-project/monero/master/utils/gpg_keys/binaryfate.asc` |

`DOWNLOAD_URL` can point at a specific release tarball to pin a version, or at a mirror; the HTTPS and filename checks still apply.

## Scope

This installs the daemon only. It does not install `monero-wallet-cli`, `monero-wallet-gui`, or set up a service, and it does not modify your shell configuration. On Android, a full node is best run with `--detach` and kept on a charger.

## License

The script is provided as-is under the MIT License. Monero itself is licensed separately (BSD-3-Clause); see the [Monero repository](https://github.com/monero-project/monero).
