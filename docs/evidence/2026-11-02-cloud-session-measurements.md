# Compression in a Claude Code cloud session, 2026-11-02

Commit ids in this note name commits of the monorepo this project was written in (emindeniz99/playground, private) before its graduation; the extraction rewrote the ids, so they do not resolve here. The commits are the same ones, in the same order, in this repository's history.

Measurements behind `zstd-overlay`'s design. The scripts and raw outputs are in
[`2026-11-02-cloud-session-measurements/`](2026-11-02-cloud-session-measurements/), as run, except that `S=`, which
pointed at that session's scratch directory, now reads the folder from `ZO_SCRATCH`. `aprv-measure.sh` calls the tool by its
first name, `cloud-disk.sh`.

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

## In a real environment, 2026-11-03

A new cloud environment got the setup script built from commit `dd94e60` (the version that mounted the repository itself, before the folder holding it). Its first session reported:

- the hook ran at session start: a 26 GB image (`compress-force=zstd:3`) at `/mnt/zstd-overlay`, overlays on the repository, `~/.cache`, `~/.local/share`, `~/.local/bin`, `~/.npm`, `~/.rustup`, `~/.cargo`, `~/.gradle` and `~/.bun`;
- a 200 MB file of repeated text written into the repository grew the image from 75 to 82 MB;
- 25.9 GB reserved for the image, 4.0 GB free outside it;
- `doctor` skipped the repository because `CLAUDE_PROJECT_DIR` is set for hooks and not in a shell, and the hook named its own shell as a process started before the mount. Both are fixed: `doctor` lists every mounted folder from the kernel, and `up` skips its own ancestors.

So the environment cache snapshot kept `~/.claude/settings.json` and Claude Code ran its hook, although the platform docs list only server-managed and repository hooks for cloud sessions. Not observed yet: the hook on `resume`.

Docker runs for the later commits: the folder-holding-the-repository default (`f489928`) passed 13 of 13 scenarios; the `doctor` and own-shell fixes passed scenarios 1, 4 and 11 again, with checks added for both.

## Resume field report, 2026-11-03

The same environment's session, after a VM resume, reported the hook refused `/home/user/playground` (`.git/config` written 05:14:21, before the hook) and `/root/.npm` (`_cacache` and `_logs` written 05:14:22). The session that wrote this note found the same in its own VM: boot at 04:56:22, every repository's `.git/config` rewritten at 04:56:26, `~/.npm/_logs` getting a debug log at each start of the `npm exec` MCP server, and Claude Code writing `~/.cache/claude-cli-nodejs/*/mcp-logs-*/<time>.jsonl` at 04:56:28. Its installed script was the paste from `dd94e60`: the environment embeds the setup script and never fetches the tool.

Scenario 14 reproduces that resume. Before the fix it refused the repository folder and `~/.npm` (3 of 5 folders mounted) and hid the session's last commit. After it, all 5 mount, the commit and both sides of `.git/config` are there, the npm cache file takes the newer version, and a file the session wrote and the normal disk changed again still refuses the repository folder. Scenario 15 moves a `.git` an earlier version left in the image back to the normal disk without loss.

## Reflinks from the lower layer, 2026-11-03

In the session with `/home/user` and `~/.cache` mounted, `uv run --isolated --python 3.12 pytest` failed: `Failed to clone .../uv/archive-v0/.../RECORD to .../uv/builds-v0/... Invalid cross-device link (os error 18)`. `cp --reflink=always` from a file that was in `~/.cache` before the mount failed the same way; from a file written after the mount it worked. overlayfs reports one device for both layers and refuses to clone from the lower one. The default home folders held 2 GB on the normal disk in that VM (`~/.cache` 705M, `~/.local/share` 586M, `~/.npm` 242M, `~/.local/bin` 232M, `~/.cargo` 134M, `~/.bun` 103M), so their first mount now moves that into the image; scenario 16 covers it.

With the session's image reserving all but 4 GiB, the Docker tests ran out of space (the test container's image fell to its 512 MiB floor and mise reported ENOSPC). `ZSTD_OVERLAY_RESERVE_MB=16384 zstd-overlay up` shrank the live image from 25 to 13 GB in under a second with every folder mounted.

The full run of `49d0831` (scenarios 1 to 16): 16 of 16 scenarios, 111 of 111 checks passed.

## The hook on resume, 2026-11-03 05:45

This session, with `9fdf465928aa` installed, resumed (boot 05:45:32). The SessionStart hook reported: `moved /home/user/playground/.git out of the image`, `compressed: /home/user`, and `migrated` for `~/.cache` (0.7 GiB), `~/.local/share` (0.5), `~/.local/bin` (0.2), `~/.npm` (0.2), `~/.cargo` (0.1), `~/.gradle`, `~/.dotnet` and `~/.bun`, with no folder refused. Afterwards `git status` was clean at `ace774b`, `git fsck` passed, `.git` was a bind mount, and `doctor` showed every folder `ok` with 1.8 GiB stored.

The environment's other session was still on `dd94e60`: a running session never gets a changed setup script. That version had mounted the repository on its own, so the new default (`/home/user`) would leave its earlier layer unseen; `up` now folds such layers into the normal disk first (scenario 17).

The full run of `9eb3465` (scenarios 1 to 18): 18 of 18 scenarios, 128 of 128 checks passed; 59 unit tests on Python 3.11 to 3.15.

## Both sessions on 94085a131cbe, 2026-11-03

- **The old session** (still on `dd94e60`, refusing the repository and `~/.npm` on every resume, with about 200 and 15,000 files listed) installed `94085a131cbe` by hand. `up` exited 0 with nothing refused: it folded the earlier layer of `/home/user/playground`, mounted `/home/user`, merged 12,769 changed files into `~/.npm` and migrated it (0.2 GiB). The tree stayed clean at its HEAD, `git fsck` passed, `.git` became a bind mount from the normal disk, `~/.npm` held 13,385 files before and after, and a 200 MB test file grew the image by about 108 MB. Its `up` named a `tail -40` from the agent's own pipe as a process started earlier: a sibling in the same pipeline, cosmetic.
- **This session** resumed at 06:37 with `94085a131cbe` installed. The hook mounted all 13 folders, refused nothing and migrated nothing again; the repository was clean at `1467765` and `git fsck` passed.

The full run of `c9776ba` (cache folders kept empty on the normal disk): 18 of 18 scenarios, 130 of 130 checks passed; 63 unit tests on Python 3.11 to 3.15.

## dd120d5f875d on resume, and the upgrade leftover, 2026-11-03

- This session resumed on `dd120d5f875d`: the hook moved 16 files into the image from below `~/.cache` (Claude Code's MCP logs) and 3 from below `~/.local/share`, mounted all 13 folders and refused nothing.
- The other session reported its 07:15 resume on `94085a131cbe` clean (no `NOT MOUNTED`), then installed `dd120d5f875d` by hand and simulated a resume of `~/.npm`: 12,857 files (0.2 GiB) moved in, none left below, 13,429 visible as before, `npm cache verify` passed (563 content, 606 index entries), `git fsck` clean, normal disk free 3.8 -> 4.3 GB.
- Its edge case: those 12,852 files below `~/.npm` were copies `94085a131cbe`'s merge had left behind, not writes made while unmounted, and `absorb` let them replace the image's versions. Harmless for npm's content-addressed cache, but an index entry appended while mounted could have been rolled back. `absorb` now drops a file whose ctime predates the last mount when the image has its own version; scenario 19 reproduces the upgrade.

The full run of `e7cd709` (the pre-mount leftover fix): 19 of 19 scenarios, 134 of 134 checks passed; 64 unit tests on Python 3.11 to 3.15.

The full run of `fef48f6` (startup files kept on the normal disk): 20 of 20 scenarios, 146 of 146 checks passed; 67 unit tests on Python 3.11 to 3.15.

## 2026-11-03, after the code review

The review's fixes (`70a5063`, `02491ba`): 20 of 20 scenarios; 81 unit tests on Python 3.11 to 3.15, each of the 14 new ones failing on the previous version. The installed version `9758b9951176` then handled two real resumes in this session (boots 09:26 and 15:00) with every folder mounted and nothing refused.

**The loop device cached the image twice.** With `/sys/block/loop0/loop/dio` at 0, reading a 1 GiB file from the image grew `Cached` in `/proc/meminfo` by 2,055 MiB (after `echo 3 > drop_caches`): the backing file's pages and btrfs's. With `losetup --direct-io=on` on the live device it grew by 1,025 MiB, and the cold read took 0.55 s instead of 0.73 s. The tool now sets direct I/O (`LOOP_SET_DIRECT_IO`) when it mounts the image.

**The normal disk has no journal.** The kernel log shows `EXT4-fs (vda): mounted filesystem ... r/w without journal`. So an abrupt stop loses the same window outside the image as inside it (both flush every 30 s), and only the image is guaranteed consistent afterwards.

**The setup script reached the paste field's limit.** The plain script was 64,286 bytes at `ca8178c` (the tool 63,950: 53,713 of code, 10,227 of blob). Compressed whole with xz -9e it is 19,228 bytes, 25,640 in base64, and `dabd35d` shipped it that way, 27,211 bytes with a Python decoder and a SHA-256 check. The owner preferred a paste that can be read, so the blob shrank instead: the empty filesystem's tar held 4.3 MiB because mkfs had left zero-filled blocks allocated, while only 47 blocks (188 KiB) are not zero. With the zero blocks punched into holes and xz -9e in place of gzip, the blob is 1,908 bytes, 2,578 in base64 (from 10,173), and the plain script 57.6 KB. The filesystem bytes are the same: the new blob was extracted through the loader's own `tarfile` path and compared with the old one over all 100 GiB.

The run of these changes: 21 of 21 scenarios, 85 unit tests on Python 3.11 to 3.15.

## 2026-11-03, field report from the second session (resumes 16:06 and 16:52)

- The startup-file write-back (`fef48f6`) on a real resume: a probe written under `.claude/` while mounted sat in the image's upper layer; the 16:06 hook wrote it back ("wrote 1 startup files back to the normal disk") with the re-read note, and afterwards the file was on the normal disk with the same content, with no copy in the image and nothing refused.
- The probe deleted inside the mount (a whiteout in the image): the 16:52 hook deleted it from the normal disk, which is right, but reported it with the same "wrote 1 startup files back" line. Fixed: deletes are reported on their own line, with a unit test on the wording.
- `9e828fbb7f4d` (the tool of `fff3d52`, taken with `git show`) installed by hand at 16:08 and ran the 16:52 resume: exit 0, `doctor` 9 of 9 ok, nothing refused, `git fsck` clean, `loop0` with direct I/O on. Its `version` says `working copy`, as a `git show` copy must; the README now says so.
- Not exercised: the mount retry from a backup root (`517c434`); the image has never failed to mount.
- Unchanged by design: an MCP server started before the mount (xcodebuildmcp) triggers the "started earlier" note on every resume.

## 2026-11-03, what the hook tells Claude (branch `claude/zstd-overlay-hook-context`)

Requested by the second session's field report: a fresh session learned the tool from its source, and an edited `.claude/rules/` file was written back without a note to read it. The header and the split note: 91 unit tests on Python 3.11 to 3.15; 20 of 21 scenarios on the first run, the failure being scenario 20's own check, which counted the host's `/src` overlay as a home folder (the harness excludes `/src` elsewhere for the same reason); with the count left out, scenario 20 passed. The header, run here: four lines, "0.9 GiB used on disk, 25.0 GiB free inside it", "Outside the image only 4.0 GiB is free". The setup script is now 62,743 bytes of the field's 65,536.

## 2026-11-04, second code review (38fd08f..89b5554)

Nine findings, each fixed with a test that fails on `89b5554`: with `--merge`, the startup-file write-back ran before the aside copy, so the image's CLAUDE.md won and the normal disk's edit was lost; a failure after a folder's overlay was mounted was reported as NOT MOUNTED while the folder stayed mounted and no stamp was left for the next start (the mount is now rolled back, the aside kept and named, the previous stamp untouched); a stop before any folder was counted as "1 folder(s) not compressed"; the setup script's EXIT trap guarded only the heredoc, so a cut after it exited 0 (confirmed by the reviewer with a cut copy); scenario 21 exercised the source copy instead of the installed one; absorb kept a ctime per file; two inline copies of `remove()`; the pipeline rule misfired under a wrapper such as sudo; the size guard counted characters, not bytes. The run: 94 unit tests on Python 3.11 to 3.15, 21 of 21 scenarios, scenario 20 now merging a conflicting CLAUDE.md and scenario 21 cutting the script in both places. The main version (`97602f6bc218`) had run clean on this session's real resume that morning (boot 16:50, hook header first).
