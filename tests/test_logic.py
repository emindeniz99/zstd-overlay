"""Unit tests for the decisions zstd-overlay makes without touching the kernel.

The mounting itself (btrfs, overlayfs, loop, resize) needs root and a kernel; the
scenarios in tests/run.sh cover that in Docker.
"""

from __future__ import annotations

import contextlib
import importlib.machinery
import importlib.util
import json
import os
import shutil
import stat
import sys
import time
from pathlib import Path

import pytest

_path = Path(__file__).resolve().parent.parent / "zstd-overlay"
_loader = importlib.machinery.SourceFileLoader("zstd_overlay", str(_path))
_spec = importlib.util.spec_from_loader("zstd_overlay", _loader)
assert _spec is not None
zo = importlib.util.module_from_spec(_spec)
sys.modules["zstd_overlay"] = zo  # dataclasses on Python 3.11 look the module up while it loads
_loader.exec_module(zo)

MiB = zo.MiB
GiB = zo.GiB


@pytest.fixture
def cfg(tmp_path: Path) -> zo.Config:
    return zo.Config(img="/var/lib/zstd-overlay/disk.img", mnt="/mnt/zstd-overlay", reserve=4096 * MiB,
                     home="/root", project="/work/repo")  # fmt: skip


# --- guard: what must never be covered -------------------------------------------------------


@pytest.mark.parametrize("path", ["/", "/usr", "/usr/lib/dotnet", "/opt", "/opt/claude-code", "/etc", "/var",
                                  "/var/lib", "/var/lib/dpkg", "/root", "/home"])  # fmt: skip
def test_system_folders_are_refused(cfg, path):
    # Covering these would hide the OS, apt's state or Claude Code itself after a restart.
    assert zo.guard(path, cfg, []) == "a system folder"


@pytest.mark.parametrize("path", ["/usr/local/share/tool", "/opt/swift", "/work/repo", "/root/.cache", "/tmp"])
def test_tool_and_work_folders_are_allowed(cfg, path):
    assert zo.guard(path, cfg, []) is None


def test_claude_state_is_never_covered(cfg):
    # ~/.claude holds the session's own settings and the hook; it must stay on the normal disk.
    assert zo.guard("/root/.claude", cfg, []) == "it holds /root/.claude"
    assert zo.guard("/root/.claude/projects", cfg, []) == "it is inside /root/.claude"


def test_the_image_and_its_mount_are_never_covered(cfg):
    # Covering the image's own folder would hide the image under itself.
    assert zo.guard("/var/lib/zstd-overlay", cfg, []) == "it holds /var/lib/zstd-overlay/disk.img"
    assert zo.guard("/mnt", cfg, []) == "it holds /mnt/zstd-overlay"
    assert zo.guard("/mnt/zstd-overlay/upper", cfg, []) == "it is inside /mnt/zstd-overlay"


def test_nesting_with_a_mounted_folder_is_refused_both_ways(cfg):
    # An overlay inside (or around) another one would stack layers and split one folder's writes.
    assert zo.guard("/root/.cache/pip", cfg, ["/root/.cache"]) == "it is inside /root/.cache, which is already mounted"
    assert zo.guard("/work", cfg, ["/work/repo"]) == "it holds /work/repo, which is already mounted"
    assert zo.guard("/root/.cache", cfg, ["/root/.cache"]) is None


def test_prefix_is_not_containment(cfg):
    # /root/.cache-old is not inside /root/.cache.
    assert zo.guard("/root/.cache-old", cfg, ["/root/.cache"]) is None


def test_listed_folders_inside_each_other_are_refused():
    keep, refused = zo.resolve(["/a", "/a/b", "/c", "/c"])
    assert keep == ["/a", "/c"]
    assert refused == ["refused: /a/b (it is inside /a, also listed)"]


# --- default list ----------------------------------------------------------------------------


def test_default_list_covers_project_and_the_stack_toolchain(tmp_path):
    # mise, pnpm and uv write under ~/.local/share and ~/.cache; toolchain folders count when present.
    (tmp_path / ".rustup").mkdir()
    cfg = zo.Config(img="/i", mnt="/m", reserve=0, home=str(tmp_path), project="/work/repo")
    dirs = zo.default_dirs(cfg)
    assert dirs[0] == "/work"
    assert [os.path.relpath(d, tmp_path) for d in dirs[1:]] == [".cache", ".local/share", ".local/bin", ".npm",
                                                                 ".rustup"]  # fmt: skip


@pytest.mark.parametrize(
    ("project", "covered"),
    [
        # A cloud session clones every repository under /home/user, also ones attached later.
        ("/home/user/playground", "/home/user"),
        # A session opened on /home/user itself: /home is protected, so the folder itself.
        ("/home/user", "/home/user"),
        # /root holds ~/.claude: the repository alone.
        ("/root/repo", "/root/repo"),
    ],
)
def test_the_folder_holding_the_repository_is_covered(project, covered):
    cfg = zo.Config(img="/var/lib/zstd-overlay/disk.img", mnt="/mnt/zstd-overlay", reserve=0, home="/root",
                    project=project)  # fmt: skip
    assert zo.workspace(cfg) == covered


def test_no_project_dir_outside_claude_code(tmp_path):
    cfg = zo.Config(img="/i", mnt="/m", reserve=0, home=str(tmp_path), project="")
    assert zo.default_dirs(cfg)[0] == str(tmp_path / ".cache")


# --- sizing ----------------------------------------------------------------------------------


def test_capacity_leaves_the_reserve_outside():
    # The image takes its own blocks plus what is free, minus the reserve for writers outside.
    assert zo.target_capacity(held=10_000 * MiB, avail=8_000 * MiB, reserve=4_096 * MiB) == 13_904 * MiB


def test_capacity_has_a_floor():
    assert zo.target_capacity(held=0, avail=MiB, reserve=4_096 * MiB) == zo.MIN_CAPACITY


def test_capacity_is_whole_mib():
    assert zo.target_capacity(held=MiB + 5, avail=10_000 * MiB, reserve=0) % MiB == 0


def test_shrink_goes_down_in_256_mib_steps():
    # One big shrink failed with ENOSPC about half the time; steps of 256 MiB did not.
    assert zo.shrink_steps(cur=1757 * MiB, target=733 * MiB) == [1501 * MiB, 1245 * MiB, 989 * MiB, 733 * MiB]
    assert zo.shrink_steps(cur=733 * MiB, target=733 * MiB) == []


# --- change detection: the rule that nothing gets hidden -----------------------------------


def _later() -> None:
    """Let the clock move on, so the next write has a later ctime (the kernel's is coarse)."""
    time.sleep(0.02)


def _stamp_then_wait(tmp_path: Path) -> int:
    stamp = tmp_path / "stamp"
    stamp.touch()
    time.sleep(0.02)
    return stamp.stat().st_mtime_ns


def test_untouched_folder_reports_nothing(tmp_path):
    (tmp_path / "d").mkdir()
    (tmp_path / "d" / "a").write_text("x")
    stamp = _stamp_then_wait(tmp_path)
    assert zo.changed_since(str(tmp_path / "d"), stamp) == []


def test_edit_after_the_mount_is_reported(tmp_path):
    d = tmp_path / "d"
    d.mkdir()
    (d / "a").write_text("x")
    stamp = _stamp_then_wait(tmp_path)
    (d / "a").write_text("edited while unmounted")
    assert zo.changed_since(str(d), stamp) == [str(d / "a")]


def test_an_edit_with_its_mtime_set_back_is_still_reported(tmp_path):
    # `cp -a` and `tar -p` restore old mtimes; ctime cannot be set back, so the edit still shows.
    d = tmp_path / "d"
    d.mkdir()
    (d / "a").write_text("x")
    stamp = _stamp_then_wait(tmp_path)
    (d / "a").write_text("y")
    os.utime(d / "a", (0, 0))
    assert str(d / "a") in zo.changed_since(str(d), stamp)


def test_a_delete_alone_is_not_reported(tmp_path):
    # Only files the image would hide count. After a delete on the normal disk the file stays
    # deleted, unless the session changed it too: then the image's version shows (a limit,
    # documented in the README: no write is hidden, but a delete can be undone).
    d = tmp_path / "d"
    (d / "sub").mkdir(parents=True)
    (d / "sub" / "gone").write_text("x")
    stamp = _stamp_then_wait(tmp_path)
    (d / "sub" / "gone").unlink()
    assert zo.changed_since(str(d), stamp) == []


def test_git_folders_are_not_entered(tmp_path):
    # .git stays on the normal disk, so the platform's write to .git/config is not a change.
    d = tmp_path / "d"
    (d / "repo" / ".git").mkdir(parents=True)
    stamp = _stamp_then_wait(tmp_path)
    (d / "repo" / ".git" / "config").write_text("[core]")
    (d / "repo" / "file").write_text("x")
    assert zo.changed_since(str(d), stamp, frozenset({str(d / "repo" / ".git")})) == [str(d / "repo" / "file")]


# --- what the image would hide --------------------------------------------------------------


def test_a_file_the_image_has_no_version_of_shows_through(tmp_path):
    # A new log file written before the hook (an MCP server, Claude Code) is not a conflict.
    (tmp_path / "logs").mkdir()
    assert not zo.hidden_by_upper("logs/new.log", str(tmp_path))
    assert not zo.hidden_by_upper("elsewhere/new.log", str(tmp_path))


def test_a_file_the_image_also_has_would_be_hidden(tmp_path):
    (tmp_path / "repo").mkdir()
    (tmp_path / "repo" / "notes.txt").write_text("the session's version")
    assert zo.hidden_by_upper("repo/notes.txt", str(tmp_path))


def test_a_file_where_the_lower_side_has_a_folder_hides_it(tmp_path):
    (tmp_path / "x").write_text("a file in the image")
    assert zo.hidden_by_upper("x/inside.txt", str(tmp_path))


@pytest.mark.skipif(os.geteuid() != 0, reason="mknod and trusted.* xattrs need root")
def test_a_deleted_or_replaced_folder_in_the_image_hides_what_is_below(tmp_path):
    os.mknod(tmp_path / "gone", 0o600 | stat.S_IFCHR, 0)  # overlayfs's whiteout
    assert zo.hidden_by_upper("gone/file", str(tmp_path))
    (tmp_path / "replaced").mkdir()
    os.setxattr(tmp_path / "replaced", "trusted.overlay.opaque", b"y")
    assert zo.hidden_by_upper("replaced/file", str(tmp_path))


def test_repositories_are_found_two_levels_down_but_not_in_node_modules(tmp_path):
    for p in ("a/.git", "owner/b/.git", "c/node_modules/pkg/.git", "deep/x/y/z/.git"):
        (tmp_path / p).mkdir(parents=True)
    found = [os.path.relpath(g, tmp_path) for g in zo.git_dirs(str(tmp_path))]
    assert found == ["a/.git", "owner/b/.git"]


# --- moving .git out of the image -----------------------------------------------------------


@pytest.mark.skipif(os.geteuid() != 0, reason="mknod needs root")
def test_merge_tree_applies_deletes_and_keeps_newer_files(tmp_path):
    upper, lower = tmp_path / "upper", tmp_path / "lower"
    (upper / "refs").mkdir(parents=True)
    (lower / "refs").mkdir(parents=True)
    (lower / "index.lock").write_text("stale")
    (lower / "refs" / "main").write_text("old commit")
    _later()
    os.mknod(upper / "index.lock", 0o600 | stat.S_IFCHR, 0)  # the session deleted it
    (upper / "refs" / "main").write_text("session commit")  # the session moved the branch
    (upper / "FETCH_HEAD").write_text("older")
    _later()
    (lower / "FETCH_HEAD").write_text("written after the session")
    zo.merge_tree(str(upper), str(lower))
    assert not (lower / "index.lock").exists()
    assert (lower / "refs" / "main").read_text() == "session commit"
    assert (lower / "FETCH_HEAD").read_text() == "written after the session"


@pytest.mark.skipif(shutil.which("git") is None, reason="needs git")
def test_both_sides_of_git_config_are_kept(tmp_path):
    # The session ran `git push -u` (branch.main.remote); the platform rewrote the file on resume.
    # move_git_out merges the image's .git onto the normal disk's .git, as here.
    upper, lower = tmp_path / "upper" / ".git", tmp_path / "lower" / ".git"
    upper.mkdir(parents=True)
    lower.mkdir(parents=True)
    (upper / "config").write_text('[core]\n\tbare = false\n[branch "main"]\n\tremote = origin\n')
    _later()
    (lower / "config").write_text("[core]\n\tbare = false\n\tsshCommand = platform\n")
    zo.merge_tree(str(upper), str(lower))
    text = (lower / "config").read_text()
    assert "sshCommand = platform" in text
    assert "remote = origin" in text
    assert text.count("bare = false") == 1


@pytest.mark.skipif(shutil.which("git") is None, reason="needs git")
def test_git_config_keeps_only_the_platforms_value_of_a_key_it_rewrote(tmp_path):
    # On resume the platform writes a fresh remote URL. The image's stale one must not become a
    # second url: git would push to both. Keys only the session set keep all their values.
    upper, lower = tmp_path / "upper" / ".git", tmp_path / "lower" / ".git"
    upper.mkdir(parents=True)
    lower.mkdir(parents=True)
    (upper / "config").write_text(
        '[remote "origin"]\n\turl = http://proxy:1111/old\n'
        '[remote "fork"]\n\tfetch = +refs/a/*:refs/x/*\n\tfetch = +refs/b/*:refs/y/*\n'
    )
    _later()
    (lower / "config").write_text('[remote "origin"]\n\turl = http://proxy:2222/new\n')
    zo.merge_tree(str(upper), str(lower))
    text = (lower / "config").read_text()
    assert "2222/new" in text
    assert "1111/old" not in text
    assert "refs/a/*" in text
    assert "refs/b/*" in text


def test_merge_tree_judges_age_by_ctime_not_mtime(tmp_path):
    # `cp -a` or `tar -xp` on the normal disk writes new content with an old mtime; it is still
    # the newer write and must not be replaced by the image's copy.
    upper, lower = tmp_path / "upper", tmp_path / "lower"
    upper.mkdir()
    lower.mkdir()
    (upper / "f").write_text("image")
    _later()
    (lower / "f").write_text("restored later with cp -a")
    os.utime(lower / "f", (1, 1))
    zo.merge_tree(str(upper), str(lower))
    assert (lower / "f").read_text() == "restored later with cp -a"


def test_merge_tree_keeps_a_folder_holding_a_newer_file(tmp_path):
    # The image has a file where the normal disk has a folder (or the other way round). The
    # normal disk's side holds something written later: it stays, whatever its type.
    upper, lower = tmp_path / "upper", tmp_path / "lower"
    (upper / "b").mkdir(parents=True)
    (lower / "a" / "deep").mkdir(parents=True)
    (upper / "a").write_text("image file where a folder is")
    (upper / "b" / "inner").write_text("image")
    _later()
    (lower / "a" / "deep" / "new").write_text("written later")
    (lower / "b").write_text("normal disk file where the image has a folder")
    zo.merge_tree(str(upper), str(lower))
    assert (lower / "a" / "deep" / "new").read_text() == "written later"
    assert (lower / "b").read_text() == "normal disk file where the image has a folder"


def test_merge_tree_does_not_write_through_a_symlink(tmp_path):
    # The normal disk has an older symlink where the image has a folder: the folder replaces the
    # symlink; nothing is written where the symlink pointed.
    upper, lower, outside = tmp_path / "upper", tmp_path / "lower", tmp_path / "outside"
    lower.mkdir()
    outside.mkdir()
    (lower / "d").symlink_to(outside)
    _later()
    (upper / "d").mkdir(parents=True)
    (upper / "d" / "f").write_text("image")
    zo.merge_tree(str(upper), str(lower))
    assert list(outside.iterdir()) == []
    assert not (lower / "d").is_symlink()
    assert (lower / "d" / "f").read_text() == "image"


# --- mountinfo ---------------------------------------------------------------------------


MOUNTINFO = (
    "22 1 254:0 / / rw,relatime - ext4 /dev/vda rw\n"
    "90 22 7:2 / /mnt/zstd-overlay rw,noatime - btrfs /dev/loop2 rw,compress-force=zstd:3\n"
    "91 22 0:50 / /work/my\\040repo rw,relatime - overlay overlay "
    "rw,lowerdir=/work/my\\040repo,upperdir=/mnt/zstd-overlay/upper/%work%my repo,workdir=/x\n"
    "92 22 0:51 / /var/lib/docker/x rw - overlay overlay rw,lowerdir=/a,upperdir=/var/lib/docker/u,workdir=/w\n"
)


def test_mountinfo_unescapes_spaces_and_finds_only_our_overlays():
    mounts = zo.parse_mountinfo(MOUNTINFO)
    assert [m.target for m in mounts] == ["/", "/mnt/zstd-overlay", "/work/my repo", "/var/lib/docker/x"]
    assert mounts[1].source == "/dev/loop2"
    # Docker's own overlays are not ours and must not count as mounted folders.
    assert zo.our_overlays(mounts, "/mnt/zstd-overlay") == ["/work/my repo"]


def test_read_only_is_the_first_mount_option():
    m = zo.parse_mountinfo("90 22 7:2 / /m ro,noatime - btrfs /dev/loop2 ro,compress-force=zstd:3\n")[0]
    assert m.options.split(",")[0] == "ro"


# --- the hook -----------------------------------------------------------------------------


def test_install_adds_one_hook_and_keeps_everything_else():
    settings = {"model": "x", "hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "echo mine"}]}],
                                        "Stop": []}}  # fmt: skip
    once = zo.merge_hook(json.loads(json.dumps(settings)))
    twice = zo.merge_hook(json.loads(json.dumps(once)))
    assert twice == once
    assert twice["model"] == "x"
    assert "Stop" in twice["hooks"]
    assert [h["command"] for e in twice["hooks"]["SessionStart"] for h in e["hooks"]] == ["echo mine", zo.HOOK_COMMAND]


def test_install_replaces_an_older_zstd_overlay_hook():
    old = {"hooks": {"SessionStart": [{"hooks": [{"type": "command", "command": "/usr/local/bin/zstd-overlay up"}]}]}}
    entries = zo.merge_hook(old)["hooks"]["SessionStart"]
    assert len(entries) == 1
    assert entries[0]["matcher"] == "startup|resume"
    assert entries[0]["hooks"][0]["command"] == "/usr/local/bin/zstd-overlay up --hook"


def test_hook_output_is_plain_text_when_all_went_well():
    assert zo.hook_output(["zstd-overlay: compressed: /work/repo"], 0) == "zstd-overlay: compressed: /work/repo"


def test_hook_output_warns_the_user_and_tells_claude_not_to_merge_alone():
    # Claude Code reads a SessionStart hook's stdout only on exit 0, so a refusal travels as JSON.
    out = json.loads(zo.hook_output(["zstd-overlay: NOT MOUNTED: /work/repo ...", "    /work/repo/README"], 1))
    assert out["systemMessage"] == "zstd-overlay: 1 folder(s) not compressed this session; details: zstd-overlay doctor"
    ctx = out["hookSpecificOutput"]["additionalContext"]
    assert out["hookSpecificOutput"]["hookEventName"] == "SessionStart"
    assert "/work/repo/README" in ctx
    assert "only after the user has looked at the listed files and agreed" in ctx


def test_install_refuses_invalid_json_and_leaves_it(tmp_path, monkeypatch):
    (tmp_path / ".claude").mkdir()
    settings = tmp_path / ".claude" / "settings.json"
    settings.write_text("{broken")
    monkeypatch.setattr(zo, "INSTALL_PATH", tmp_path / "bin-zstd-overlay")
    s = zo.Session(zo.Config(img="/i", mnt="/m", reserve=0, home=str(tmp_path), project=""), quiet=True)
    with pytest.raises(zo.Stop, match="not valid JSON"):
        s.install()
    assert settings.read_text() == "{broken"


def test_install_writes_the_hook_and_copies_itself(tmp_path, monkeypatch):
    monkeypatch.setattr(zo, "INSTALL_PATH", tmp_path / "bin-zstd-overlay")
    s = zo.Session(zo.Config(img="/i", mnt="/m", reserve=0, home=str(tmp_path), project=""), quiet=True)
    s.install()
    data = json.loads((tmp_path / ".claude" / "settings.json").read_text())
    assert data["hooks"]["SessionStart"][0]["hooks"][0]["command"] == zo.HOOK_COMMAND
    assert (tmp_path / "bin-zstd-overlay").read_bytes() == _path.read_bytes()
    assert os.access(tmp_path / "bin-zstd-overlay", os.X_OK)


# --- migrate's check before it deletes ------------------------------------------------------


def test_tree_signature_counts_entries_and_file_bytes_not_link_targets(tmp_path):
    (tmp_path / "a").write_bytes(b"12345")
    (tmp_path / "sub").mkdir()
    (tmp_path / "sub" / "b").write_bytes(b"123")
    (tmp_path / "link").symlink_to("a")
    assert zo.tree_sig(str(tmp_path)) == (5, 8)


# --- the command line -----------------------------------------------------------------------


def test_help_needs_no_root(capsys):
    assert zo.main(["--help"]) == 0
    assert capsys.readouterr().out.startswith("zstd-overlay:")


def test_non_root_is_refused(monkeypatch, capsys):
    monkeypatch.setattr(os, "geteuid", lambda: 1000)
    assert zo.main(["up"]) == 2
    assert "needs root" in capsys.readouterr().err


def test_unknown_command(capsys):
    assert zo.main(["frobnicate"]) == 2
    assert "unknown command" in capsys.readouterr().err


def test_config_defaults():
    c = zo.Config.from_env({"HOME": "/root"})
    assert (c.img, c.mnt, c.reserve, c.project) == ("/var/lib/zstd-overlay/disk.img", "/mnt/zstd-overlay",
                                                     4096 * MiB, "")  # fmt: skip


def test_own_shell_is_not_a_stale_process():
    # The hook runs inside a shell whose working directory is the repository; that shell started
    # before the mount but is ours, so `up` must not tell the user to restart it.
    mine = zo.ancestors(os.getpid())
    assert {os.getpid(), os.getppid()} <= mine


@pytest.mark.skipif(os.geteuid() != 0, reason="mknod needs root")
def test_merge_tree_never_removes_a_newer_file(tmp_path):
    # Folding an old layer: the session deleted a file then, and wrote it again later on the
    # normal disk. The later write wins.
    upper, lower = tmp_path / "upper", tmp_path / "lower"
    upper.mkdir()
    lower.mkdir()
    os.mknod(upper / "notes.txt", 0o600 | stat.S_IFCHR, 0)
    os.utime(upper / "notes.txt", (1, 1), follow_symlinks=False)
    (lower / "notes.txt").write_text("written later")
    zo.merge_tree(str(upper), str(lower))
    assert (lower / "notes.txt").read_text() == "written later"


@pytest.mark.skipif(shutil.which("git") is None, reason="needs git")
def test_git_config_below_the_folder_keeps_both_sides(tmp_path):
    # A repository's own old layer holds .git/config one level down, not at the top.
    upper, lower = tmp_path / "upper", tmp_path / "lower"
    (upper / ".git").mkdir(parents=True)
    (lower / ".git").mkdir(parents=True)
    (upper / ".git" / "config").write_text('[branch "main"]\n\tremote = origin\n')
    os.utime(upper / ".git" / "config", (1, 1))
    (lower / ".git" / "config").write_text("[core]\n\tsshCommand = platform\n")
    zo.merge_tree(str(upper), str(lower))
    text = (lower / ".git" / "config").read_text()
    assert "sshCommand = platform" in text
    assert "remote = origin" in text


def test_the_hook_does_nothing_outside_a_cloud_session(monkeypatch, capsys):
    # CLAUDE_CODE_REMOTE is "true" only in cloud sessions; on a laptop the hook must not mount or
    # fail at every session start, even run without root.
    monkeypatch.delenv("CLAUDE_CODE_REMOTE", raising=False)
    monkeypatch.setattr(os, "geteuid", lambda: 1000)
    assert zo.main(["up", "--hook"]) == 0
    assert capsys.readouterr().out == ""


# --- caches: what the normal disk holds moves into the image ---------------------------------


def test_absorb_empties_the_normal_disk_and_keeps_every_file(tmp_path):
    # A cache folder below the mount must stay empty: anything written there while unmounted
    # (npm, MCP servers, Claude Code before the hook) moves into the image, and wins.
    lower, upper = tmp_path / "lower", tmp_path / "upper"
    (lower / "_cacache" / "index").mkdir(parents=True)
    (lower / "_cacache" / "index" / "bucket").write_text("written before the hook")
    (lower / "_logs").mkdir()
    (lower / "_logs" / "new.log").write_text("log")
    (lower / "link").symlink_to("_logs/new.log")
    os.chmod(lower / "_logs" / "new.log", 0o640)
    (upper / "_cacache" / "index").mkdir(parents=True)
    (upper / "_cacache" / "index" / "bucket").write_text("from the session")
    (upper / "_cacache" / "kept").write_text("only in the image")
    assert zo.absorb(str(lower), str(upper)) == (3, len("written before the hook") + len("log"))
    assert list(lower.iterdir()) == []
    assert (upper / "_cacache" / "index" / "bucket").read_text() == "written before the hook"
    assert (upper / "_cacache" / "kept").read_text() == "only in the image"
    assert os.readlink(upper / "link") == "_logs/new.log"
    assert stat.S_IMODE((upper / "_logs" / "new.log").stat().st_mode) == 0o640


def test_absorb_keeps_hard_links_together(tmp_path):
    # pnpm's store hard-links the same file into several places; one copy, not two.
    lower, upper = tmp_path / "lower", tmp_path / "upper"
    (lower / "a").mkdir(parents=True)
    upper.mkdir()
    (lower / "a" / "one").write_text("x" * 1000)
    os.link(lower / "a" / "one", lower / "two")
    zo.absorb(str(lower), str(upper))
    assert (upper / "a" / "one").stat().st_ino == (upper / "two").stat().st_ino


@pytest.mark.skipif(os.geteuid() != 0, reason="mknod needs root")
def test_absorb_replaces_a_deletion_marker(tmp_path):
    # The session deleted `x`; npm wrote it again before the hook: the new `x` must show.
    lower, upper = tmp_path / "lower", tmp_path / "upper"
    lower.mkdir()
    upper.mkdir()
    os.mknod(upper / "x", 0o600 | stat.S_IFCHR, 0)
    (lower / "x").write_text("written again")
    zo.absorb(str(lower), str(upper))
    assert (upper / "x").read_text() == "written again"


def test_absorb_on_an_empty_folder_does_nothing(tmp_path):
    (tmp_path / "lower").mkdir()
    (tmp_path / "upper").mkdir()
    assert zo.absorb(str(tmp_path / "lower"), str(tmp_path / "upper")) == (0, 0)


def test_absorb_drops_a_leftover_the_image_had_superseded(tmp_path):
    # 94085a131cbe's merge copied files into the image but left them below the mount too; the
    # session then appended to the image's copy. After an upgrade, the leftover must not win.
    lower, upper = tmp_path / "lower", tmp_path / "upper"
    (lower / "index").mkdir(parents=True)
    (upper / "index").mkdir(parents=True)
    (lower / "index" / "bucket").write_text("stale copy left below")
    (lower / "index" / "only-below").write_text("no version in the image")
    mounted = _stamp_then_wait(tmp_path)  # the last mount, after the leftover was written
    (upper / "index" / "bucket").write_text("stale copy left below\nappended while mounted")
    (lower / "index" / "fresh.log").write_text("written after the mount")
    (upper / "index" / "fresh.log").write_text("older")
    zo.absorb(str(lower), str(upper), mounted)
    assert (upper / "index" / "bucket").read_text().endswith("appended while mounted")
    assert (upper / "index" / "only-below").read_text() == "no version in the image"
    assert (upper / "index" / "fresh.log").read_text() == "written after the mount"
    assert list(lower.iterdir()) == []  # nothing left below the mount, the leftover included


# --- the files Claude Code reads before the hook ----------------------------------------------


def test_write_back_moves_startup_files_to_the_normal_disk(tmp_path):
    # Claude Code reads CLAUDE.md, .claude/ and .mcp.json before the hook mounts: the session's
    # edits to them must be on the normal disk for the next start, and out of the image.
    upper, lower = tmp_path / "upper", tmp_path / "lower"
    (upper / "repo" / ".claude" / "rules").mkdir(parents=True)
    (lower / "repo" / ".claude").mkdir(parents=True)
    (upper / "repo" / "CLAUDE.md").write_text("edited in the session")
    (lower / "repo" / "CLAUDE.md").write_text("as cloned")
    (upper / "repo" / ".claude" / "rules" / "new.md").write_text("a new rule")
    (upper / "repo" / "src.py").write_text("code stays in the image")
    rels = [f"repo/{f}" for f in zo.STARTUP_FILES]
    written, deleted = zo.write_back(str(upper), str(lower), rels)
    assert sorted(written) == ["repo/.claude/rules/new.md", "repo/CLAUDE.md"]
    assert deleted == []
    assert (lower / "repo" / "CLAUDE.md").read_text() == "edited in the session"
    assert (lower / "repo" / ".claude" / "rules" / "new.md").read_text() == "a new rule"
    assert not (upper / "repo" / "CLAUDE.md").exists()
    assert not (upper / "repo" / ".claude").exists()
    assert (upper / "repo" / "src.py").exists()


@pytest.mark.skipif(os.geteuid() != 0, reason="mknod needs root")
def test_write_back_applies_a_deleted_startup_file(tmp_path):
    upper, lower = tmp_path / "upper", tmp_path / "lower"
    upper.mkdir()
    lower.mkdir()
    (lower / ".mcp.json").write_text("{}")
    os.mknod(upper / ".mcp.json", 0o600 | stat.S_IFCHR, 0)  # the session deleted it
    assert zo.write_back(str(upper), str(lower), [".mcp.json"]) == ([], [".mcp.json"])
    assert not (lower / ".mcp.json").exists()
    assert not os.path.lexists(upper / ".mcp.json")


def test_write_back_without_edits_does_nothing(tmp_path):
    (tmp_path / "upper").mkdir()
    (tmp_path / "lower").mkdir()
    assert zo.write_back(str(tmp_path / "upper"), str(tmp_path / "lower"), ["CLAUDE.md", ".claude"]) == ([], [])


def test_absorb_judges_every_hard_link_by_the_same_age(tmp_path):
    # Removing one name of a hard-linked leftover sets the inode's ctime to now; the next name
    # must still count as a leftover, not as a fresh write that replaces the image's version.
    lower, upper = tmp_path / "lower", tmp_path / "upper"
    lower.mkdir()
    upper.mkdir()
    (lower / "a").write_text("stale")
    os.link(lower / "a", lower / "b")
    mounted = _stamp_then_wait(tmp_path)
    (upper / "a").write_text("newer a")
    (upper / "b").write_text("newer b")
    zo.absorb(str(lower), str(upper), mounted)
    assert ((upper / "a").read_text(), (upper / "b").read_text()) == ("newer a", "newer b")
    assert list(lower.iterdir()) == []


@pytest.mark.skipif(os.geteuid() != 0, reason="mknod needs root")
def test_absorb_keeps_a_deleted_folder_deleted(tmp_path):
    # An earlier version left pip/ below the mount; the session ran `rm -rf ~/.cache/pip`. The
    # old files must not come back; a file written there after the mount does.
    lower, upper = tmp_path / "lower", tmp_path / "upper"
    (lower / "pip" / "http").mkdir(parents=True)
    (lower / "pip" / "http" / "old").write_text("left below")
    upper.mkdir()
    mounted = _stamp_then_wait(tmp_path)
    os.mknod(upper / "pip", 0o600 | stat.S_IFCHR, 0)
    zo.absorb(str(lower), str(upper), mounted)
    assert zo.is_whiteout(os.lstat(upper / "pip"))
    assert list(lower.iterdir()) == []
    (lower / "pip" / "http").mkdir(parents=True)
    (lower / "pip" / "http" / "new").write_text("written before the hook")
    zo.absorb(str(lower), str(upper), mounted)
    assert sorted(os.listdir(upper / "pip" / "http")) == ["new"]


@pytest.mark.skipif(os.geteuid() != 0, reason="trusted xattrs need root")
def test_absorb_keeps_a_replaced_folder_replaced(tmp_path):
    # `rm -rf d && mkdir d` in the session makes d opaque: the old files it hid stay hidden.
    lower, upper = tmp_path / "lower", tmp_path / "upper"
    (lower / "d").mkdir(parents=True)
    (lower / "d" / "old").write_text("hidden by the new folder")
    mounted = _stamp_then_wait(tmp_path)
    (upper / "d").mkdir(parents=True)
    os.setxattr(upper / "d", "trusted.overlay.opaque", b"y")
    (upper / "d" / "new").write_text("the session's")
    zo.absorb(str(lower), str(upper), mounted)
    assert os.listdir(upper / "d") == ["new"]


def test_absorb_does_not_write_through_a_symlink(tmp_path):
    # The session replaced a cache folder with a symlink; npm wrote the folder again before the
    # hook. The new files go into the image, not where the symlink points.
    lower, upper, outside = tmp_path / "lower", tmp_path / "upper", tmp_path / "outside"
    upper.mkdir()
    outside.mkdir()
    (upper / "d").symlink_to(outside)
    mounted = _stamp_then_wait(tmp_path)
    (lower / "d").mkdir(parents=True)
    (lower / "d" / "new").write_text("written before the hook")
    zo.absorb(str(lower), str(upper), mounted)
    assert list(outside.iterdir()) == []
    assert (upper / "d" / "new").read_text() == "written before the hook"


@pytest.mark.skipif(os.geteuid() != 0, reason="trusted xattrs need root")
def test_write_back_of_a_replaced_folder_drops_the_old_files(tmp_path):
    # `rm -rf .claude && mkdir .claude` in the session: the old settings must not come back.
    upper, lower = tmp_path / "upper", tmp_path / "lower"
    (lower / ".claude").mkdir(parents=True)
    (lower / ".claude" / "old-hook.json").write_text("deleted in the session")
    (upper / ".claude").mkdir(parents=True)
    os.setxattr(upper / ".claude", "trusted.overlay.opaque", b"y")
    (upper / ".claude" / "settings.json").write_text("{}")
    zo.write_back(str(upper), str(lower), [".claude"])
    assert os.listdir(lower / ".claude") == ["settings.json"]
    assert not (upper / ".claude").exists()


@pytest.mark.skipif(os.geteuid() != 0, reason="trusted xattrs need root")
def test_write_back_leaves_worktrees_in_the_image(tmp_path):
    # .claude/worktrees holds whole checkouts; moving them out of the image at every mount would
    # fill the normal disk. The rest of .claude is written back, and what stays hides nothing.
    upper, lower = tmp_path / "upper", tmp_path / "lower"
    (upper / ".claude" / "worktrees" / "wt" / "node_modules").mkdir(parents=True)
    (upper / ".claude" / "worktrees" / "wt" / "node_modules" / "big").write_text("x" * 1000)
    os.setxattr(upper / ".claude", "trusted.overlay.opaque", b"y")
    (upper / ".claude" / "settings.json").write_text("{}")
    lower.mkdir()
    assert zo.write_back(str(upper), str(lower), [".claude"]) == ([".claude/settings.json"], [])
    assert (lower / ".claude" / "settings.json").exists()
    assert not (lower / ".claude" / "worktrees").exists()
    assert (upper / ".claude" / "worktrees" / "wt" / "node_modules" / "big").exists()
    assert os.listdir(upper / ".claude") == ["worktrees"]
    assert not zo.is_opaque(str(upper / ".claude"))


def test_a_path_with_percent_is_refused():
    # A layer is named by its path with "/" written as "%": /w/a%b and /w/a/b would share one.
    assert "%" in (zo.guard("/w/50%off", zo.Config.from_env({"HOME": "/root"}), []) or "")


def test_one_folder_failing_does_not_stop_the_others(monkeypatch):
    s = zo.Session(zo.Config.from_env({"HOME": "/root"}), quiet=True)
    tried = []

    def mount_dir(self, d, merge=False, cache=False):
        tried.append(d)
        if d == "/a":
            raise OSError(28, "No space left on device")
        return True

    monkeypatch.setattr(zo.Session, "mount_image", lambda self: None)
    monkeypatch.setattr(zo.Session, "mount_dir", mount_dir)
    s.up(["/a", "/b"])
    assert tried == ["/a", "/b"]
    assert s.refused == 1
    assert "NOT MOUNTED: /a" in s.lines[0]


def test_the_hook_reports_an_error_with_exit_0(monkeypatch, capsys):
    # Claude Code reads a SessionStart hook's output only on exit 0: an error must come back as
    # the JSON report, not as exit 2 nobody sees.
    monkeypatch.setenv("CLAUDE_CODE_REMOTE", "true")
    monkeypatch.setattr(os, "geteuid", lambda: 0)
    monkeypatch.setattr(zo, "locked", contextlib.nullcontext)

    def boom(self, dirs, merge=False):
        raise zo.Stop("losetup: no free loop device")

    monkeypatch.setattr(zo.Session, "up", boom)
    assert zo.main(["up", "--hook"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert "losetup" in out["hookSpecificOutput"]["additionalContext"]
    # A stop before any folder is not a refused folder: the user must not read "1 folder(s)".
    assert out["systemMessage"].startswith("zstd-overlay: stopped (")
    assert "folder(s)" not in out["systemMessage"]


def test_the_hook_reports_an_unexpected_error_with_exit_0_too(monkeypatch, capsys):
    # README, Safety: `up --hook` reports any error in its JSON with exit 0. A bug (not a Stop or
    # an OSError) used to escape as a traceback with exit 1, which Claude Code shows nobody.
    monkeypatch.setenv("CLAUDE_CODE_REMOTE", "true")
    monkeypatch.setattr(os, "geteuid", lambda: 0)
    monkeypatch.setattr(zo, "locked", contextlib.nullcontext)

    def boom(self, dirs, merge=False):
        raise ValueError("a bug")

    monkeypatch.setattr(zo.Session, "up", boom)
    assert zo.main(["up", "--hook"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert "ValueError: a bug" in out["hookSpecificOutput"]["additionalContext"]
    assert out["systemMessage"].startswith("zstd-overlay: stopped (ValueError: a bug)")
    # Outside the hook a bug is still a traceback: nothing hides it.
    monkeypatch.delenv("CLAUDE_CODE_REMOTE")
    with pytest.raises(ValueError, match="a bug"):
        zo.main(["up"])


def test_a_reserve_that_is_not_a_number_is_reported_not_a_traceback(monkeypatch, capsys):
    # The README tells the user to set ZSTD_OVERLAY_RESERVE_MB in the environment's variables;
    # "4g" there made the hook die with a ValueError before it could report anything.
    monkeypatch.setenv("ZSTD_OVERLAY_RESERVE_MB", "4g")
    monkeypatch.setattr(os, "geteuid", lambda: 0)
    assert zo.main(["status"]) == 2
    assert "ZSTD_OVERLAY_RESERVE_MB must be a whole number of MiB, not '4g'" in capsys.readouterr().err
    monkeypatch.setenv("CLAUDE_CODE_REMOTE", "true")
    assert zo.main(["up", "--hook"]) == 0
    out = json.loads(capsys.readouterr().out)
    assert "ZSTD_OVERLAY_RESERVE_MB" in out["systemMessage"]
    assert out["hookSpecificOutput"]["additionalContext"].startswith("zstd-overlay ")


def test_flags_may_follow_the_folders(monkeypatch):
    monkeypatch.setattr(os, "geteuid", lambda: 0)
    monkeypatch.setattr(zo, "locked", contextlib.nullcontext)
    seen = []
    monkeypatch.setattr(zo.Session, "up", lambda self, dirs, merge=False: seen.append((dirs, merge)))
    assert zo.main(["up", "/work", "--merge"]) == 0
    assert seen == [(["/work"], True)]
    assert zo.main(["up", "--mrege", "/work"]) == 2


def test_direct_io_on_something_that_is_not_a_loop_device_reports_false():
    # A refusal is reported, not raised: the image works without it, only cached twice.
    assert zo.loop_direct_io("/dev/null") is False


def test_version_names_the_commit_and_its_date_when_built_with_git_archive():
    line = zo.version_line("3d898f0c0ffee0000000000000000000000000000 1793719800")
    assert line.endswith("(commit 3d898f0, 2026-11-03T15:30:00Z)")
    assert line.startswith(f"zstd-overlay {zo.VERSION} {zo.self_hash()} ")


def test_version_says_so_when_the_placeholder_was_not_filled_in(capsys):
    # A checkout, or a file copied out with `git show`, keeps the placeholder: say so instead of
    # printing it, so nobody reads "$Format" as a commit.
    assert zo.main(["version"]) == 0
    out = capsys.readouterr().out
    assert "working copy" in out
    assert "$Format" not in out


def test_an_image_that_does_not_mount_is_retried_from_a_backup_root(tmp_path, monkeypatch):
    # The image is the one place every mounted folder's writes live: when its newest tree root
    # was cut by an abrupt stop, btrfs's older roots must be tried before giving up.
    img, mnt = tmp_path / "disk.img", tmp_path / "mnt"
    img.write_bytes(b"")
    cfg = zo.Config(img=str(img), mnt=str(mnt), reserve=0, home="/root", project="")
    calls: list[tuple[str, ...]] = []

    def run(*cmd):
        calls.append(cmd)
        if len(calls) == 1:
            raise zo.Stop("mount: wrong fs type, bad option, bad superblock")

    mounted = zo.parse_mountinfo(f"90 22 7:2 / {mnt} rw,noatime - btrfs /dev/loop2 rw\n")
    monkeypatch.setattr(zo, "run", run)
    monkeypatch.setattr(zo, "mount_at", lambda t: mounted[0] if calls else None)
    monkeypatch.setattr(zo.Session, "direct_io", lambda self, dev: None)
    monkeypatch.setattr(zo.Session, "fit_image", lambda self: None)
    s = zo.Session(cfg, quiet=True)
    s.mount_image()
    assert "usebackuproot" in calls[1][2]
    assert any("backup root" in line for line in s.lines)
    assert s.refused == 0


@pytest.mark.skipif(os.geteuid() != 0, reason="mknod needs root")
def test_a_deleted_startup_file_is_reported_as_deleted_not_written(tmp_path):
    # Field report, 2026-11-03: the session deleted a probe under .claude/, and the hook said
    # "wrote 1 startup files back to the normal disk" for it. The file was gone everywhere,
    # which was right; the line was not.
    cfg = zo.Config(img=str(tmp_path / "disk.img"), mnt=str(tmp_path / "mnt"), reserve=0, home="/root",
                    project=str(tmp_path / "lower" / "repo"))  # fmt: skip
    lower, repo = tmp_path / "lower", tmp_path / "lower" / "repo"
    (repo / ".git").mkdir(parents=True)
    (repo / ".claude").mkdir()
    (repo / ".claude" / "probe.txt").write_text("written while mounted, then deleted")
    (repo / "CLAUDE.md").write_text("as cloned")
    upper = Path(zo.Session(cfg).upper(str(lower)))
    (upper / "repo" / ".claude").mkdir(parents=True)
    os.mknod(upper / "repo" / ".claude" / "probe.txt", 0o600 | stat.S_IFCHR, 0)
    (upper / "repo" / "CLAUDE.md").write_text("edited in the session")
    s = zo.Session(cfg, quiet=True)
    s.write_back_startup_files(str(lower))
    assert not (repo / ".claude" / "probe.txt").exists()
    assert (repo / "CLAUDE.md").read_text() == "edited in the session"
    wrote = [line for line in s.lines if "wrote 1 startup" in line]
    deleted = [line for line in s.lines if "deleted 1 startup" in line]
    assert len(wrote) == 1
    assert "CLAUDE.md" in wrote[0]
    assert "probe" not in wrote[0]
    assert len(deleted) == 1
    assert "probe.txt" in deleted[0]


# --- what the hook tells Claude ------------------------------------------------------------


def test_the_header_explains_the_image_in_a_few_lines():
    # Field report: a fresh session saw only "compressed: ..." lines. The header must say what
    # is compressed, how much room there is inside and outside, where .git is, and the --merge
    # rule, every start, in a few lines.
    lines = zo.hook_header("zstd-overlay abc (commit 1234567, 2026-11-03)", "/home/user",
                           ["/home/user", "/root/.cache", "/root/.npm"], 2 * GiB, 20 * GiB, 4 * GiB)  # fmt: skip
    text = "\n".join(lines)
    assert len(lines) <= 6
    assert lines[0].startswith("zstd-overlay abc (commit 1234567, 2026-11-03): /home/user and 2 home folders")
    assert "2.0 GiB used on disk, 20.0 GiB free inside" in text
    assert "only 4.0 GiB is free" in text
    assert "/tmp" in text
    assert ".git" in text
    assert "zstd-overlay doctor" in text
    assert "Never run `zstd-overlay up --merge` unless the user agreed" in text


def test_the_header_says_when_the_repository_folder_or_the_image_is_not_mounted():
    refused = zo.hook_header("v", "/home/user", ["/root/.cache"], GiB, GiB, GiB)
    assert "/home/user is NOT compressed" in refused[0]
    no_image = zo.hook_header("v", "/home/user", [], None, None, GiB)
    assert "the image is not mounted" in no_image[0]


def _hook_run(monkeypatch, capsys, up):
    monkeypatch.setenv("CLAUDE_CODE_REMOTE", "true")
    monkeypatch.setenv("CLAUDE_PROJECT_DIR", "/home/user/playground")
    monkeypatch.setattr(os, "geteuid", lambda: 0)
    monkeypatch.setattr(zo, "locked", contextlib.nullcontext)
    monkeypatch.setattr(zo.Session, "up", up)
    mnt = zo.Config.from_env().mnt
    monkeypatch.setattr(zo, "mount_at", lambda t: zo.Mount(t, "btrfs", "/dev/loop0", "rw") if t == mnt else None)
    monkeypatch.setattr(zo, "our_overlays", lambda m, d: ["/home/user", "/root/.cache"])
    monkeypatch.setattr(zo, "fs_used", lambda p: 3 * GiB)
    monkeypatch.setattr(zo, "fs_avail", lambda p: 21 * GiB if p == mnt else 4 * GiB)
    assert zo.main(["up", "--hook"]) == 0
    return capsys.readouterr().out


def test_a_clean_start_prints_the_header_with_live_numbers(monkeypatch, capsys):
    out = _hook_run(monkeypatch, capsys, lambda self, dirs, merge=False: self.say("compressed: /root/.cache"))
    lines = out.splitlines()
    assert "/home/user and 1 home folders are compressed" in lines[0]
    assert "3.0 GiB used on disk, 21.0 GiB free inside" in lines[0]
    assert "only 4.0 GiB is free" in lines[1]
    assert lines[-1] == "zstd-overlay: compressed: /root/.cache"  # the mount lines follow the header


def test_a_refusal_carries_the_header_in_its_json(monkeypatch, capsys):
    out = _hook_run(monkeypatch, capsys, lambda self, dirs, merge=False: self.refuse("NOT MOUNTED: /home/user"))
    context = json.loads(out)["hookSpecificOutput"]["additionalContext"]
    assert context.index("home folders are compressed") < context.index("NOT MOUNTED")
    assert "only 4.0 GiB is free" in context


@pytest.mark.skipif(os.geteuid() != 0, reason="mknod needs root")
def test_the_note_names_what_to_read_now_and_what_waits_for_the_next_start(tmp_path):
    # Field report: most instructions live in .claude/rules; an edited rule was
    # written back, but the note named only CLAUDE.md and put the rule under "next start".
    cfg = zo.Config(img=str(tmp_path / "disk.img"), mnt=str(tmp_path / "mnt"), reserve=0, home="/root",
                    project=str(tmp_path / "lower" / "repo"))  # fmt: skip
    lower, repo = tmp_path / "lower", tmp_path / "lower" / "repo"
    (repo / ".git").mkdir(parents=True)
    (repo / ".claude" / "rules").mkdir(parents=True)
    (repo / ".claude" / "rules" / "old.md").write_text("a rule the session deleted")
    upper = Path(zo.Session(cfg).upper(str(lower))) / "repo"
    (upper / ".claude" / "rules").mkdir(parents=True)
    (upper / ".claude" / "skills" / "s").mkdir(parents=True)
    (upper / ".claude" / "rules" / "x.md").write_text("edited rule")
    os.mknod(upper / ".claude" / "rules" / "old.md", 0o600 | stat.S_IFCHR, 0)
    (upper / ".claude" / "rules" / "nested").mkdir()
    (upper / ".claude" / "rules" / "nested" / "y.md").write_text("a rule one folder down")
    (upper / ".claude" / "CLAUDE.md").write_text("instructions under .claude")
    # Only the skill list (each SKILL.md's frontmatter) is loaded at start; the rest of a skill
    # is read from the mount when it is used.
    (upper / ".claude" / "skills" / "s" / "SKILL.md").write_text("skill")
    (upper / ".claude" / "skills" / "s" / "helper.py").write_text("read when the skill runs")
    (upper / ".mcp.json").write_text("{}")
    s = zo.Session(cfg, quiet=True)
    s.write_back_startup_files(str(lower))
    now = next(line for line in s.lines if "read them again now" in line)
    gone = next(line for line in s.lines if "disregard them" in line)
    later = next(line for line in s.lines if "next start" in line)
    assert f"{repo}/.claude/rules/x.md" in now
    assert f"{repo}/.claude/rules/nested/y.md" in now
    assert f"{repo}/.claude/CLAUDE.md" in now
    assert "skills" not in now
    assert ".mcp.json" not in now
    assert f"{repo}/.claude/rules/old.md" in gone
    assert f"{repo}/.mcp.json" in later
    assert f"{repo}/.claude/skills/s/SKILL.md" in later
    assert "rules" not in later
    assert any(line.startswith("zstd-overlay: deleted 1 startup files") and "old.md" in line for line in s.lines)


def test_startup_kind_follows_what_claude_code_loads_at_start():
    for path in ("r/CLAUDE.md", "r/CLAUDE.local.md", "r/AGENTS.md", "r/.claude/CLAUDE.md", "r/.claude/rules/a/b.md"):
        assert zo.startup_kind(path) == "read", path
    for path in ("r/.mcp.json", "r/.claude/settings.json", "r/.claude/settings.local.json", "r/.claude/hooks/h.sh",
                 "r/.claude/agents/a.md", "r/.claude/commands/c.md", "r/.claude/skills/s/SKILL.md",
                 "r/.claude/rules/notes.txt"):  # fmt: skip
        assert zo.startup_kind(path) == "restart", path


# --- --merge and a failure after the mount ----------------------------------------------------


def _conflict(tmp_path, monkeypatch, fail_on=None):
    """A repository folder whose CLAUDE.md the normal disk and the image both changed; `mount`
    and `cp` are recorded, not run. Returns (session, path, calls, aside_seen)."""
    lower, repo, mnt = tmp_path / "lower", tmp_path / "lower" / "repo", tmp_path / "mnt"
    cfg = zo.Config(img=str(tmp_path / "disk.img"), mnt=str(mnt), reserve=0, home="/root", project=str(repo))
    repo.mkdir(parents=True)
    (mnt / "stamps").mkdir(parents=True)
    (repo / "CLAUDE.md").write_text("as cloned")
    Path(zo.Session(cfg).stamp(str(lower))).touch()
    _later()
    (repo / "CLAUDE.md").write_text("edited outside")  # on the normal disk, while unmounted
    upper = Path(zo.Session(cfg).upper(str(lower))) / "repo"
    upper.mkdir(parents=True)
    (upper / "CLAUDE.md").write_text("edited in the session")  # in the image
    calls: list[tuple[str, ...]] = []
    aside_seen: dict[str, str] = {}

    def run(*cmd):
        calls.append(cmd)
        if cmd[0] == "cp":
            aside_seen["CLAUDE.md"] = Path(cmd[2][:-2], "repo", "CLAUDE.md").read_text()
        if cmd[0] == fail_on:
            raise zo.Stop(f"{cmd[0]}: No space left on device")

    monkeypatch.setattr(zo, "run", run)
    return zo.Session(cfg, quiet=True), str(lower), calls, aside_seen


def test_merge_puts_the_normal_disks_startup_file_on_top(tmp_path, monkeypatch):
    # Review finding: the write-back ran before the aside copy, so the aside held the image's
    # CLAUDE.md and the merge put that back on top; the normal disk's edit was lost.
    s, path, calls, aside_seen = _conflict(tmp_path, monkeypatch)
    assert s.mount_dir(path, merge=True)
    assert aside_seen["CLAUDE.md"] == "edited outside"
    assert [c[0] for c in calls] == ["mount", "cp"]


def test_a_failure_after_the_mount_unmounts_again_and_keeps_the_aside(tmp_path, monkeypatch):
    # Review finding: a failure after the overlay was mounted (the merge copy, the stamp) was
    # reported as NOT MOUNTED while the folder stayed mounted, with no stamp for the next start.
    s, path, calls, _ = _conflict(tmp_path, monkeypatch, fail_on="cp")
    stamp = Path(s.stamp(path))
    before = stamp.stat().st_mtime_ns
    with pytest.raises(zo.Stop, match="back on the normal disk"):
        s.mount_dir(path, merge=True)
    assert ("umount", "-R", path) in calls
    assert stamp.stat().st_mtime_ns == before  # the next start compares against the same stamp
    kept = next(line for line in s.lines if "kept at" in line)
    aside = kept.rsplit(" ", 1)[1]
    assert Path(aside, "repo", "CLAUDE.md").read_text() == "edited outside"
