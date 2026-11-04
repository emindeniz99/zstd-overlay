# zstd-overlay

## Why

- **Problem:** a Claude Code cloud session has about 30 GB of disk. A repository with nine languages (toolchains, dependency caches, build output) fills it.
- **Success:** the same work fits with room to spare. The full toolchain of `apple-purchase-receipt-verifier` takes 40% or less of its normal size. After a VM restore one command brings everything back, and no write is lost or hidden. Every scenario in `tests/run.sh` passes.
- **Out of scope:** `/usr`, `/opt` and other system folders; macOS (see [`apfs-compress`](../apfs-compress)); non-root environments; machines without Python 3.11+; deduplication; any tool the base image lacks.

## What it does

`zstd-overlay` puts the folders you name on top of a zstd-compressed btrfs image. Writes under those folders land in the image, compressed. What the folders held before stays where it was and stays readable. Programs see plain files, so pnpm, cargo, uv, mise, dotnet and git need no flags.

It is one Python 3.11+ file using only the standard library, and it uses only what the kernel already has: btrfs, overlayfs and loop devices. It resizes btrfs and reserves disk blocks with kernel calls (`BTRFS_IOC_RESIZE`, `fallocate`), so it needs no btrfs-progs. The kernel can mount btrfs but cannot create one, and `mkfs.btrfs` is not installed, so an empty btrfs filesystem (1.9 KB: its 188 KiB of superblocks and trees, xz-compressed) ships at the end of the file. A cloud session has Python 3.13; a machine without `python3` gets an error from `env` and nothing is mounted.

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

`--hook` matters: Claude Code reads a hook's output only when it exits 0. So in that mode `up` always exits 0, and when it leaves a folder unmounted it answers in JSON: a warning you see, and the list of files plus the rule "merge only after the user agreed" for Claude. It also does nothing unless `CLAUDE_CODE_REMOTE` is `true`, which only a cloud session sets, so a settings file that reaches a laptop does not try to mount there. Every start, clean or not, opens its report with four lines for Claude: what is compressed, the space used and free inside the image, the space free outside it (where `/tmp`, `/var`, Docker and apt write, uncompressed), that `.git` stays outside, and the rule never to run `up --merge` without the user's agreement. A field report found that a session otherwise saw only "compressed: ..." lines and learned the tool from its source. The hook runs in the foreground on purpose: an `async` hook would let the session write into the folders before they are mounted, the very conflict the safety rule exists for.

To change the reserve or the image's place, set `ZSTD_OVERLAY_RESERVE_MB` (and the others under Environment in `--help`) in the environment's variables; a session reads them again at every restore. Not tested: a cloud thread in a Claude project, where repository hooks do not run; whether it runs a user-level hook is unknown.

Run `install` from the environment's setup script. This repository is private, so the setup script cannot download the file; paste it in. `build-setup-script.sh` writes the script for a commit:

```bash
./build-setup-script.sh <commit> > setup-script.sh    # a commit that is on GitHub; --embed for an environment that cannot reach github.com
```

The script is a few lines: it downloads `zstd-overlay` at the named commit from this repository (GitHub's archive of the commit, which fills in the commit line as `git archive` does), checks the file's SHA-256 against the one in the script, and runs `install`. `zstd-overlay version` then names the commit and its date. An EXIT trap turns a paste cut short, anywhere, into exit 1 with a message, and a file that does not match the hash installs nothing, so the platform reports a failed setup either way (scenarios 21 and 22). For an environment that cannot reach github.com, `--embed` writes the tool itself into the script, xz-compressed and base64-encoded with a readable header, about 30 KB of the field's 64 KB; the plain file no longer fits, which is why the project left the monorepo it was written in.

`zstd-overlay version` prints the installed file's hash, the commit and the commit date; `doctor` adds when the file was installed, which is when the environment cache was built or the session updated by hand. A file taken from a checkout with `git show` or `cp` carries no commit and says `working copy, not built with git archive`; its hash also differs from the built one by that line. That is expected for a file copied that way, not a defect; the manual-update commands below use `git archive` so a hand-updated session names its commit too.

`install` creates no image. The image appears at the first session start, after the environment cache snapshot, so the snapshot holds a few kilobytes instead of a disk image.

Checked on 2026-11-03 in a new environment with this setup script: the snapshot kept the hook, the hook ran at session start and mounted the repository and 8 cache folders, and a 200 MB file of repeated text grew the image by 7 MB. On 2026-11-03 the hook also ran on `resume` in a session that had `9fdf465928aa` installed: it moved `.git` out of the image, mounted `/home/user` and the caches without a refusal, and moved 1.8 GB of existing caches into the image; the repository was clean and `git fsck` passed afterwards. The platform docs say a cloud session runs hooks from server-managed settings and the repository, and that user-level hooks stay on your machine; the hook in the VM's own `~/.claude/settings.json` ran anyway. If a future session shows nothing mounted, check that first. Run `zstd-overlay doctor` in a session to see the state.

A session that is already running never sees a changed setup script: the script runs only when the environment cache is built, not on resume. Update such a session by hand, once:

```bash
bash setup-script.sh && zstd-overlay up && zstd-overlay doctor   # the same script the environment got
```

`up` folds the layer of any folder an earlier version mounted on its own (versions up to `dd94e60` mounted the repository, later ones the folder holding it) into the normal disk, newer file winning, so nothing written then stays hidden in the image.

## Safety

- **No write is hidden under the image.** `up` records the time of each mount. At the next mount it looks for files with a newer ctime (which `cp -a` and `tar -p` cannot set back) that the image also has a version of: mounting would hide those. In the folder holding the repositories, such a file refuses the folder: `up` lists the files and leaves the folder on the normal disk, and `zstd-overlay up --merge DIR` mounts it with the normal disk's files on top, after you have looked. A file the image has no version of (a new log) shows through and changes nothing.
- **A cache folder is always empty on the normal disk.** Before it mounts one of the default home folders (caches and toolchains), `up` moves everything the normal disk holds there into the image: the first time, what the cloud image ships (about 2 GB, 10 to 30 seconds); on a resume, what npm, MCP servers and Claude Code wrote before the hook, which is by construction newer than anything in the image. No comparison and no conflict: only the tool that wrote a cache file reads it. Each file is copied before its original is removed, so a kill leaves at most a duplicate, which the next run moves again. A file that was already below the mount at the last mount, and that did not show through it (the image has its own version, or deleted or replaced a folder above it), is not newer: it is a leftover the image had superseded (the version `94085a131cbe` left such copies below `~/.npm`), so the image's version stays and the leftover goes. `up` tells the two apart by ctime against the time of the last mount, which archive tools that restore old mtimes cannot fake.
- **Git metadata never goes into the image.** Each repository's `.git` stays on the normal disk and is bind-mounted into the mounted folder. The platform rewrites every `.git/config` when a VM resumes, before the hook runs (measured in two sessions); kept outside the image, that write is not a conflict. Git packs are zlib-compressed already, so the image would gain little from them. `up` moves a `.git` it finds in the image to the normal disk, keeping the platform's keys of `.git/config` and adding the ones only the session set (a second remote URL would make git push to both): earlier versions kept `.git` in the image, and a repository cloned while mounted starts there.
- **The image reserves its space.** It is allocated with `fallocate` and leaves `ZSTD_OVERLAY_RESERVE_MB` (4096) free outside it. When the disk fills from outside, the writer outside gets "No space left on device" and the image keeps working. A sparse image would take that error itself, as an I/O error, and btrfs would turn read-only and lose its last writes; scenario 6 reproduced that before this design. `up` grows the image when the disk has room and gives space back, in 256 MiB steps, when the outside runs short.
- **`migrate` never deletes before it has verified.** It copies the folder's merged view into a new layer, compares entry counts and byte totals, swaps the layer in, compares again, and only then deletes the old copy. A `kill -9` in the middle leaves the content intact (scenario 5); if it lands after the original was moved aside, the next `up` or `migrate` puts it back and runs the migration again (scenario 18). It refuses a repository and the folder that holds one: repositories are mounted, never migrated.
- **Refused targets:** a path containing `%` (it names the folder's layer), `/`, `/usr` (except `/usr/local/...`), `/opt`, `/opt/claude-code`, `/etc`, `/var`, `/root`, `/home`, `~/.claude`, the image and its mount, a folder inside another mounted or listed folder, and the reverse.
- A lock serialises concurrent runs. Non-root use stops with an error. One folder that fails to mount does not stop the others; a failure after a folder's overlay was mounted (the merge copy, the stamp) unmounts it again, so "NOT MOUNTED" is true and the next start compares against the same stamp. `up --hook` reports any error in its JSON with exit 0, the only exit code whose output Claude Code reads; an error that stopped the run before any folder (the lock, the image) is reported as a stop, not as a refused folder.

## Limits

- **Reflinks stop at a folder boundary.** overlayfs refuses a reflink between two mounted folders, so pnpm (store in `~/.local/share`, `node_modules` in the repository) and uv (cache in `~/.cache`, `.venv` in the repository) copy instead of linking. The copies are compressed, so they cost little.
- **overlayfs cannot reflink a file that was on the normal disk before the mount** (`EXDEV`), though both sides report the same device. uv took that for a clone that must work and stopped ("Failed to clone ... Invalid cross-device link"). A cache folder keeps nothing below the mount, so it cannot happen there. The repository folder is not moved: a reflink from a repository file older than the mount still fails, and tools that fall back to a copy are unaffected.
- **Claude Code reads each repository's `CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `.claude/` and `.mcp.json` when it starts, a few seconds before the hook mounts.** So `up` keeps those files on the normal disk: before it mounts the folder, it moves the image's versions of them down and out of the image. `.claude/worktrees` stays in the image: it holds whole checkouts, and nothing reads it before the hook. The start that follows a resume still read the older copies, so `up` names each file that changed under what it needs: instructions (`CLAUDE.md`, `CLAUDE.local.md`, `AGENTS.md`, `.claude/CLAUDE.md`, `.claude/rules/**/*.md`) to read again now, or to disregard when deleted; everything else under `.claude/`, and `.mcp.json`, at the next start, because the harness loads it once (settings, hooks, agents, commands, the skill list). A skill's files and nested `CLAUDE.md` files load when used, from the mount, so they are current then. A conflict on one of them (the session changed it and so did the normal disk) still refuses the folder. The rest of the repository stays in the image: build output and dependencies are written there as they appear, which is what makes a large build fit.
- **A process that was already inside a folder keeps the old folder.** What it writes by relative path goes under the mount. `up` names such processes; restart them if they write there. Claude Code itself is not affected: it resolves its working directory for every command, so in a live session the commands and file tools after `up` saw the mounted repository.
- **Memory:** the loop device is switched to direct I/O, so a block the image reads is cached once, as btrfs's page, not also as the file's. Measured: 1 GiB read from the image took 2 GiB of cache without it and 1 GiB with it, and the cold read was 25% faster. Where the switch is refused, `up` says so and the image works, cached twice.
- **Data that is already compressed** (git packs, `.tgz`, `.jar`) does not shrink.
- **`/tmp` and `~/.claude` live in the reserve.** Both are on the normal disk, so a download or build that puts more than `ZSTD_OVERLAY_RESERVE_MB` into `/tmp` gets "No space left" there while the image still has room; the image gives space back only at the next `up`. Raise the reserve in the environment's variables when a project needs a large `/tmp`.
- **An abrupt stop loses the same window on both sides.** The VM's normal disk is ext4 mounted without a journal (kernel log, 2026-11-03), flushed every 30 s with no ordering; the image is btrfs, copy-on-write, committed every 30 s. A pause the platform does not sync before can lose the last seconds of writes on either, but it cannot leave the image inconsistent: btrfs comes back at its last commit.
- **The image lives on the VM.** When the platform reclaims a VM, the image goes with it, like everything not pushed.
- After a delete in a full image, btrfs takes up to about 15 seconds to offer the space again.
- **A delete on the normal disk while unmounted can be undone.** If the session had changed that file too, the image's version shows after the mount. No write is lost or hidden; the delete is.
- **The image is one file.** Every mounted folder's writes live in it, so a VM stop that cuts a btrfs write half way could leave its newest tree root unreadable. Two things keep that from losing the image: the image's blocks are allocated up front, so the normal disk's metadata for it never changes under a write; and `up` retries a failed mount with `usebackuproot`, which mounts the newest of the older roots btrfs keeps, reporting that the last seconds before the stop may be missing. Not reproduced: no stop in two days of sessions damaged the image.
- **The conflict check trusts the clock.** A write made while unmounted is found by its ctime against the time of the last mount; a clock set back across a resume could make such a write look old. A cloud VM takes its clock from the host, which does not go back.
- **Nothing can mount earlier than the hook.** The setup script runs only when the environment cache is built, not on resume, and the VM has no init system to hook into (PID 1 is `process_api`).
- **Until the hook runs, the default home folders are empty.** Their contents are in the image, which is not mounted yet after a resume. Claude Code itself is not there (`/opt/claude-code`), and the platform's git and npm are in `/usr` and `/opt`. What does break is anything that runs before or beside the hook from `~/.local/bin` or a toolchain folder: an MCP server started with `uvx`, or another SessionStart hook that calls `uv`, `mise` or `cargo` (hooks run in parallel). Such a hook can run `zstd-overlay up` first; it waits for the lock and returns once the folders are mounted.

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
| 4 | a write the image would hide: refused and named; `--merge`; no false alarm; a new file or a delete: mounted; `--hook` exits 0 and reports in JSON |
| 5 | `migrate`: attributes kept, deletions stay deleted, repository refused, `kill -9` in the middle of the copy safe |
| 6 | disk full from inside the image and from outside; reserve given back and taken again |
| 7 | deleted space is reused inside the image |
| 8 | reflinks, git commit/branch/stash/gc/fsck |
| 9 | mise installs node 24 + pnpm 12 and uv + Python for the projects in `tests/fixtures/`; installs land in the image |
| 10 | `install`: merges into existing settings, once; invalid JSON untouched; no jq needed; a base without python3 stops cleanly |
| 11 | the real Claude Code binary runs the hook |
| 12 | a snapshot after `install` stays small |
| 13 | concurrent runs, nesting, system folders, non-root |
| 14 | resume with the writes measured before the hook (the platform's `.git/config`, npm's cache and logs, Claude Code's MCP logs): nothing refused, nothing lost, the caches below the mount empty; a real conflict in the repository folder still refused |
| 15 | a `.git` left in the image by an earlier version moves out: commit kept, both sides of `.git/config` kept, `git fsck` clean |
| 16 | a cache folder below the mount stays empty: its files move into the image, a reflink from them works, a second `up` moves nothing, a write from before the hook moves in after a restart |
| 17 | an old session (the repository mounted on its own, then refused on resume): the new version folds the old layer, keeps the later edits and the early commit, refuses nothing |
| 18 | a migration killed after the original was moved aside (each step, as a VM pause during the first start could leave it): `up` puts the original back, migrates again, content intact, nothing left over |
| 19 | upgrade from `94085a131cbe`: a leftover below a cache does not roll the image's newer version back; `up \| tail` names no process |
| 20 | the session edits `CLAUDE.md` and `.claude/settings.json`: on the next mount they go back to the normal disk and out of the image, Claude is told to read `CLAUDE.md` again, the start after that reads them current, code stays in the image, a real conflict still refuses |
| 21 | the built setup script: installs from the paste, `version` names the commit, a truncated paste exits non-zero and installs nothing |

Last results: [`docs/evidence/2026-11-02-cloud-session-measurements.md`](docs/evidence/2026-11-02-cloud-session-measurements.md#test-results).
