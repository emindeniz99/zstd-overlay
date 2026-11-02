# Compression in a Claude Code cloud session, 2026-11-02

Measurements behind `zstd-overlay`'s design. The scripts and raw outputs are in
[`2026-11-02-cloud-session-measurements/`](2026-11-02-cloud-session-measurements/), as run. They point `S=` at that
session's scratch directory, and `aprv-measure.sh` calls the tool by its first name, `cloud-disk.sh`.

## The machine

- A Firecracker microVM on KVM: the kernel command line carries `--firecracker-init`, the disk is `/dev/vda`, and PID 1 is `process_api`. `systemd-detect-virt` answers `docker`, which the other signs contradict.
- Linux 6.18.44, built without module support (`nomodule`, no `/lib/modules`). In the kernel: btrfs, overlayfs, squashfs, erofs, loop. No ZFS, and none can be added. No `/dev/kvm` inside, so no nested VMs.
- One ext4 filesystem for `/`. The session's own share showed 30 GB free; the documented ceiling is "4 vCPUs, 16 GB of RAM, 30 GB of disk", approximate, with no setting to raise it (<https://code.claude.com/docs/en/cloud-environments>, "Resource limits"). For more, the docs point to Remote Control or a self-hosted environment.
- The VM restarted three times while idle that day. Each time every mount was gone and every file stayed, which is the docs' "pauses with its files saved".

## Which filesystem and algorithm

`bench.sh`: a pnpm `node_modules` (ai-date, 50,437 files, 756 MiB on ext4) and a rustup toolchain (623 MiB). MiB on the host disk:

| Format | node_modules | rustup | Writable |
|---|---|---|---|
| ext4 | 756 | 623 | yes |
| btrfs, no compression | 633 | 625 | yes |
| btrfs lzo | 368 | 358 | yes |
| btrfs zlib:1 / 3 / 9 | 274 / 265 / 250 | 247 / 238 / 225 | yes |
| btrfs zstd:-5 / 1 / 3 / 9 / 15 | 337 / 265 / 257 / 245 / 238 | 327 / 236 / 224 / 210 / 198 | yes |
| squashfs lz4 / gzip / zstd / xz | 239 / 165 / 152 / 146 | 296 / 206 / 184 / 167 | no |
| erofs lz4 / lz4hc / deflate / libdeflate / lzma | 307 / 262 / 239 / 229 / 213 | not run | no |
| DwarFS -l5 / -l7 / -l9 (FUSE, 0.15.8) | 117 / 112 / 102 | | no |

- zstd:3 is the writable choice: zstd:9 saves 3 to 6% more and writes up to three times slower; zlib reaches the same ratio more slowly at every level. Fedora's analysis found the same order (40, 41, 43% at zstd:1, 3, 9: <https://fedoraproject.org/wiki/Changes/BtrfsByDefault/CompressionLevelAnalysis>).
- erofs-utils 1.7.1 (Ubuntu 24.04) builds on one thread and has no zstd; libdeflate took 1,157 s for one image. The run hit its time limit before the rustup set.
- DwarFS is the smallest and reads about twice as slowly as squashfs. One maintainer wrote 99% of its 4,269 commits, and Ubuntu does not package it.

Reads (`bench-read.sh`; every format in a freshly written image, cold reads the median of three):

| Format | node project: MiB, cold tar | type check cold / warm | Rust `target/`: MiB, cold tar |
|---|---|---|---|
| ext4 | 905, 6.3 s | 4.1 / 3.2 s | 628, 0.57 s |
| btrfs zstd:3 | 257, 4.9 s | 4.1 / 3.3 s | 138, 0.65 s |
| squashfs zstd | 152, 7.2 s | 3.9 / 3.5 s | 111, 1.43 s |
| DwarFS -l9 | 102, 13.0 s | 4.0 / 3.8 s | 60, 1.02 s |

The TypeScript type check, the real workload, took 3.2 to 4.1 s on every format.

## The verifier's nine languages

`aprv-measure.sh` on `apple-purchase-receipt-verifier` at `0e02a28`, run with the prototype (`cloud-disk.sh`: the same zstd:3 image under overlayfs, but sparse and mounted with `discard`; the final script differs in how it reserves space, not in how it compresses): dotnet 10 and musl from apt, Swift 6.3, Rust 1.99.1 with the wasm toolchain, then every package's install and tests, with the repository and ten home and toolchain folders on the image.

| | Stored | On disk |
|---|---|---|
| everything | 18.3 GB | 10.1 GB |
| without composer's cache | 12.8 GB | 4.6 GB |
| Swift 6.3 / .NET 10 / rustup / repository build output | 3,364 / 597 / 945 / 5,287 MiB | 1,101 / 243 / 332 / 1,759 MiB |
| composer's cache | 5,471 MiB | 5,462 MiB |

Composer could not authenticate to github.com through the session proxy, fell back to cloning every package's git repository, and filled its cache with git packs, which do not compress. Without the image the session would have stood at about 29 GB of 39 used.

The failures that run turned up were not the image's. Two were the repository's: issues [#499](https://github.com/emindeniz99/apple-purchase-receipt-verifier/issues/499) and [#500](https://github.com/emindeniz99/apple-purchase-receipt-verifier/issues/500). The rest came from the measuring script and the machine: a missing musl target, the module path, missing .NET 8 and 9 runtimes, and composer's network.

## Findings that shaped the design

- **A sparse image breaks when the disk fills from outside.** With the disk under it full, a write into the image returned success, then btrfs logged `Transaction aborted (error -5)` and `forced readonly`, and the next write failed with an I/O error. The image now reserves its space with `fallocate` and mounts with `nodiscard`, as Nothing but Nix does for the same reason (<https://github.com/wimpysworld/nothing-but-nix>). Scenario 6 runs the same sequence; the image keeps working.
- **btrfs can be resized without btrfs-progs.** `BTRFS_IOC_RESIZE` (`0x50009403`, a 4,096-byte `btrfs_ioctl_vol_args`) works from perl, which every Ubuntu base has. One large shrink fails with ENOSPC about half the time when every block group above the new end is empty but still allocated; 256 MiB steps succeed (5 of 5 runs).
- **After a delete in a full image,** btrfs offered the space again after 1 to 15 seconds.
- **Reflinks:** `cp --reflink=always` works within one mounted folder and fails between two (overlayfs). pnpm and uv copy instead; the copies are compressed.
- **Deduplication would gain about 1%.** `dupscan.py` found 3.54 GiB of byte-identical copies in 24.29 GiB of files in the image, and btrfs already shared 3.36 GiB of that through reflinks.
- **mise, pnpm and uv write to `~/.local/share` and `~/.cache`** (mise: <https://mise.jdx.dev/directories.html>). With those on the image, mise 2026.10.25 installed node 24.21.0, pnpm 12.4.1, uv 0.13.5 and Python 3.15.2 into it; only the mise binary (169 MiB, `~/.local/bin`) stayed outside, which the default list now covers.
- **Claude Code sees a repository mounted while it runs.** With `up` run on the session's own repository, a shell started before the mount still worked in the old folder (`stat -c %d .` gave the ext4 device), but the next Bash call and the Read tool saw the mount (the overlay's device, and a file written through it). Claude Code resolves its working directory per command; processes started earlier, such as MCP servers and dockerd, keep the old one.
- **Migrating a filled folder works:** a preinstalled `~/.rustup` (624 MiB) moved into the image and freed 445 MiB of disk.

## Prior art

Nothing but Nix builds a btrfs loop volume with `compress=zstd:1` for `/nix` on GitHub Actions runners, preallocated and mounted `nodiscard` (<https://discourse.nixosstag.fcio.net/t/nothing-but-nix-reclaim-130gb-for-nix-in-github-runners/64345>). maximize-build-space joins the runner's disks with LVM and does not compress (<https://github.com/easimon/maximize-build-space/>). No source found combines an overlay with a compressed loop image, or addresses the cloud session's 30 GB.

## Test results

`tests/run.sh` on the session VM (Linux 6.18.44, Docker 29.9.2, `ubuntu:24.04`), 2026-11-02:

- Every one of the 13 scenarios passed in the runs of that day. Scenario 9 first failed because the container could not reach the session's proxy on 127.0.0.1; with `--network host` it passed. Scenario 6 passed 5 of 5 times after the stepwise shrink.
- Scenarios 4, 10 and 11 passed again after `up --hook` was added.
- Scenario 11 ran Claude Code 2.1.316 with an invalid API key: the hook still ran and mounted the repository and the default folders.
- Scenario 12: a `docker commit` after `install` added nothing measurable; one with a 1,023 MiB reserved image added 1,026 MiB.
- Not done in Docker: the verifier end to end with the final script (measured with the prototype, above) and the real cloud environment's setup script and snapshot.

The full run of the version in commit `0253ed0` (bash): 13 of 13 scenarios, 78 of 78 checks passed.

The Python rewrite (`2335422`): the full run passed 76 of 77 checks. The one failure was the test: on the image without python3, "nothing was mounted" counted the container's own overlay root. With the check counting only zstd-overlay's mounts and btrfs, scenario 10 passed 7 of 7. The unit tests (44) pass on Python 3.11 to 3.15.
