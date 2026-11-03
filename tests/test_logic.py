"""Unit tests for the decisions zstd-overlay makes without touching the kernel.

The mounting itself (btrfs, overlayfs, loop, resize) needs root and a kernel; the
scenarios in tests/run.sh cover that in Docker.
"""

from __future__ import annotations

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
    os.mknod(upper / "index.lock", 0o600 | stat.S_IFCHR, 0)  # the session deleted it
    (upper / "refs" / "main").write_text("session commit")  # the session moved the branch
    (lower / "refs" / "main").write_text("old commit")
    os.utime(lower / "refs" / "main", (1, 1))
    (lower / "FETCH_HEAD").write_text("written after the session")
    (upper / "FETCH_HEAD").write_text("older")
    os.utime(upper / "FETCH_HEAD", (1, 1))
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
    os.utime(upper / "config", (1, 1))
    (lower / "config").write_text("[core]\n\tbare = false\n\tsshCommand = platform\n")
    zo.merge_tree(str(upper), str(lower))
    text = (lower / "config").read_text()
    assert "sshCommand = platform" in text
    assert "remote = origin" in text
    assert text.count("bare = false") == 1


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
