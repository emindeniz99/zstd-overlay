# zstd-overlay

## Why

- **Problem:** a Claude Code cloud session has about 30 GB of disk. A repository with nine languages (toolchains, dependency caches, build output) fills it.
- **Success:** the same work fits with room to spare. The full toolchain of `apple-purchase-receipt-verifier` takes 40% or less of its normal size. After a VM restore one command brings everything back, and no write is lost or hidden. Every scenario in `tests/run.sh` passes.
- **Out of scope:** `/usr`, `/opt` and other system folders; macOS (see [`apfs-compress`](../apfs-compress)); non-root environments; machines without Python 3.11+; deduplication; any tool the base image lacks.

## What it does

`zstd-overlay` puts the folders you name on top of a zstd-compressed btrfs image. Writes under those folders land in the image, compressed. What the folders held before stays where it was and stays readable. Programs see plain files, so pnpm, cargo, uv, mise, dotnet and git need no flags.

It is one Python 3.11+ file using only the standard library, and it uses only what the kernel already has: btrfs, overlayfs and loop devices. It resizes btrfs and reserves disk blocks with kernel calls (`BTRFS_IOC_RESIZE`, `fallocate`), so it needs no btrfs-progs. The kernel can mount btrfs but cannot create one, and `mkfs.btrfs` is not installed, so an empty btrfs filesystem (7.5 KB compressed) ships at the end of the file. A cloud session has Python 3.13; a machine without `python3` gets an error from `env` and nothing is mounted.

| Measured in a cloud session (2026-11-02) | Normal size | In the image |
|---|---|---|
| `node_modules` of a pnpm workspace (ai-date) | 757 MB | 257 MB |
| Rust `target/` (tokio, reqwest, serde, clap) | 497 MB | 138 MB |
| Swift 6.3 toolchain | 3,364 MiB | 1,101 MiB |
| `apple-purchase-receipt-verifier`: nine toolchains, dependencies, builds, tests (without composer's cache, see below) | 12.8 GB | 4.6 GB |
| The same with composer's cache (git packs, which do not compress) | 18.3 GB | 10.1 GB |

Details and method: [`docs/evidence/2026-11-02-cloud-session-measurements.md`](docs/evidence/2026-11-02-cloud-session-measurements.md).

## How to run

As root:

```bash
zstd-overlay up                  # the default list (below)
zstd-overlay up /opt/swift DIR   # these folders instead
zstd-overlay status              # stored vs on disk, capacity, mounted folders
zstd-overlay doctor              # every default folder: mounted, refused, or changed
zstd-overlay migrate ~/.gradle   # move what a folder already holds into the image
zstd-overlay install             # copy to /usr/local/bin and add a SessionStart hook
```

The default list is the folder that holds `$CLAUDE_PROJECT_DIR` (in a cloud session `/home/user`, so every repository is covered, also one attached later; the repository itself when that folder is a protected one such as `/root`), `~/.cache`, `~/.local/share`, `~/.local/bin`, `~/.npm`, and whichever of `~/.rustup ~/.cargo ~/go ~/.m2 ~/.gradle ~/.nuget ~/.dotnet ~/.bun` exist. That covers mise's tools (`~/.local/share/mise`), pnpm's store, uv's cache and Pythons, and the usual language caches.

### In a cloud environment

A VM restore keeps files but drops every mount, so the folders must be mounted again at each session start. `install` adds this hook to `~/.claude/settings.json`:

```json
{ "matcher": "startup|resume", "hooks": [{ "type": "command", "command": "/usr/local/bin/zstd-overlay up --hook", "timeout": 600 }] }
```

`--hook` matters: Claude Code reads a hook's output only when it exits 0. So in that mode `up` always exits 0, and when it leaves a folder unmounted it answers in JSON: a warning you see, and the list of files plus the rule "merge only after the user agreed" for Claude.

Run `install` from the environment's setup script. This repository is private, so the setup script cannot download the file; paste it in:

```bash
cat > /tmp/zstd-overlay <<'ZSTD_OVERLAY_EOF'
# ...the whole file...
ZSTD_OVERLAY_EOF
python3 /tmp/zstd-overlay install
```

`install` creates no image. The image appears at the first session start, after the environment cache snapshot, so the snapshot holds a few kilobytes instead of a disk image.

Checked on 2026-11-03 in a new environment with this setup script: the snapshot kept the hook, the hook ran at session start and mounted the repository and 8 cache folders, and a 200 MB file of repeated text grew the image by 7 MB. Not observed yet: the hook on `resume` after an idle restore. The platform docs say a cloud session runs hooks from server-managed settings and the repository, and that user-level hooks stay on your machine; the hook in the VM's own `~/.claude/settings.json` ran anyway. If a future session shows nothing mounted, check that first. Run `zstd-overlay doctor` in a session to see the state.

In a session that started before the hook existed, run `zstd-overlay up` once.

## Safety

- **A folder written to while it was not mounted is not mounted again.** Mounting would hide those writes under the image. `up` records the time of each mount; at the next mount it looks for anything in the folder with a newer ctime (which `cp -a` and `tar -p` cannot set back), refuses that folder, lists the files, and leaves it on the normal disk. Deletions count too. `zstd-overlay up --merge DIR` mounts it anyway and puts the changed files on top, after you have looked.
- **The image reserves its space.** It is allocated with `fallocate` and leaves `ZSTD_OVERLAY_RESERVE_MB` (4096) free outside it. When the disk fills from outside, the writer outside gets "No space left on device" and the image keeps working. A sparse image would take that error itself, as an I/O error, and btrfs would turn read-only and lose its last writes; scenario 6 reproduced that before this design. `up` grows the image when the disk has room and gives space back, in 256 MiB steps, when the outside runs short.
- **`migrate` never deletes before it has verified.** It copies the folder's merged view into a new layer, compares entry counts and byte totals, swaps the layer in, compares again, and only then deletes the old copy. A `kill -9` in the middle leaves the content intact (scenario 5). It refuses a repository and the folder that holds one: repositories are mounted, never migrated.
- **Refused targets:** `/`, `/usr` (except `/usr/local/...`), `/opt`, `/opt/claude-code`, `/etc`, `/var`, `/root`, `/home`, `~/.claude`, the image and its mount, a folder inside another mounted or listed folder, and the reverse.
- A lock serialises concurrent runs. Non-root use stops with an error.

## Limits

- **Reflinks stop at a folder boundary.** overlayfs refuses a reflink between two mounted folders, so pnpm (store in `~/.local/share`, `node_modules` in the repository) and uv (cache in `~/.cache`, `.venv` in the repository) copy instead of linking. The copies are compressed, so they cost little.
- **A process that was already inside a folder keeps the old folder.** What it writes by relative path goes under the mount. `up` names such processes; restart them if they write there. Claude Code itself is not affected: it resolves its working directory for every command, so in a live session the commands and file tools after `up` saw the mounted repository.
- **Data that is already compressed** (git packs, `.tgz`, `.jar`) does not shrink.
- **The image lives on the VM.** When the platform reclaims a VM, the image goes with it, like everything not pushed.
- After a delete in a full image, btrfs takes up to about 15 seconds to offer the space again.

## Tests

Two layers. The unit tests cover every decision that needs no kernel: what is refused, what counts as changed while unmounted, sizing, the settings merge, the hook's output. The scenarios cover what the kernel does.

```bash
mise run check      # format, ruff, ty, unit tests with coverage (Python from .python-version)
mise run matrix     # unit tests on Python 3.11, 3.12, 3.13, 3.14
sudo ZO_CA_BUNDLE=/path/to/ca.pem tests/run.sh       # every scenario
sudo tests/run.sh 3 6                                # some of them
```

Coverage from the unit tests alone is about 42%; the rest is mounting, resizing and copying, which only the scenarios run.

Each scenario runs in its own privileged Ubuntu 24.04 container. The containers share the host kernel, so they test the same btrfs, overlayfs and loop code a session uses, and `docker restart` reproduces a VM restore: processes and mounts go, files stay. Firecracker could not run here: the session VM exposes no `/dev/kvm`.

| # | Scenario |
|---|---|
| 1 | fresh session: default list, compression, the image reserves its capacity, 4 GiB stay free, no btrfs-progs needed |
| 2 | `up` twice changes nothing |
| 3 | restart: data and git history come back |
| 4 | a write or a delete while unmounted: refused and named; `--merge`; no false alarm; `--hook` exits 0 and reports in JSON |
| 5 | `migrate`: attributes kept, deletions stay deleted, repository refused, `kill -9` safe |
| 6 | disk full from inside the image and from outside; reserve given back and taken again |
| 7 | deleted space is reused inside the image |
| 8 | reflinks, git commit/branch/stash/gc/fsck |
| 9 | mise installs node 24 + pnpm 12 and uv + Python; installs land in the image |
| 10 | `install`: merges into existing settings, once; invalid JSON untouched; no jq needed; a base without python3 stops cleanly |
| 11 | the real Claude Code binary runs the hook |
| 12 | a snapshot after `install` stays small |
| 13 | concurrent runs, nesting, system folders, non-root |

Last results: [`docs/evidence/2026-11-02-cloud-session-measurements.md`](docs/evidence/2026-11-02-cloud-session-measurements.md#test-results).
