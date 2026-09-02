# claude-mesh (plugin source)

This file is for work **inside this repository**. It is not a plugin component.

Consumer projects that install `claude-mesh` get `skills/`, `commands/`, `agents/`,
and `hooks/` — not this file. Grok and Claude Code load `AGENTS.md` / `CLAUDE.md`
from the **current project's** tree (`projectRoot` → cwd), listed under
`grok inspect` → `projectInstructions`. Installed plugins are a separate list.
A copy of this file may sit on disk under `~/.grok/installed-plugins/claude-mesh-*`
after `grok plugin update`; that does not inject it into other projects unless
the session's cwd is that snapshot.

## Load an unpublished tree

Smoke unreleased changes without a marketplace release. `plugin.json` may still
read the last published version — identify the load by **path** and by a byte
match against this working tree, not by the version number.

Do not edit the user's `~/.claude/plugins/data/claude-mesh-*/config.yaml` or
`~/.grok/config.toml`. Ask the user to change presets.

### Claude Code — live working tree, this session only

Interactive Claude has no durable "install this folder". Session flag, from the
repo root (or pass the absolute path):

```bash
claude plugin disable claude-mesh@zinin
claude --plugin-dir "$PWD"
```

`--plugin-dir` is a live mount: the session runs the tree as it is. Disable the
marketplace copy first so the session does not mix the published cache with the
branch.

After smoke: `claude plugin enable claude-mesh@zinin`.

### Grok Build — copy into `installed-plugins`

Interactive `grok` has no `--plugin-dir`. That flag exists on `grok agent … stdio`
and is **ignored in leader mode**. Install the tree:

```bash
grok plugin install /absolute/path/to/claude-mesh --trust
grok plugin enable claude-mesh
```

Then start a **new** session (or reload plugins). This is a **copy**, not a
symlink, at `~/.grok/installed-plugins/claude-mesh-<hash>`. After you change
the working tree, edits do not apply until you **reinstall**:

```bash
grok plugin uninstall claude-mesh --confirm
grok plugin install /absolute/path/to/claude-mesh --trust
grok plugin enable claude-mesh
```

and start a new session. `grok plugin update claude-mesh` does **not** recopy a
local install — measured 2026-09-01: it answered `local symlink, already live`
while the directory stayed the old copy. The Claude marketplace cache under
`~/.claude/plugins/cache/zinin/claude-mesh/` is left alone — Claude Code smoke
still uses `--plugin-dir`.

**Keep exactly one snapshot.** The resolver picks the `claude-mesh-<hash>` that
sorts last, and the hash is not a version: with two snapshots (installed from two
paths, e.g. a worktree) the pick is arbitrary. `ls -d ~/.grok/installed-plugins/claude-mesh-*`
must list one entry; uninstall before installing from another path. The
snapshot is searched only inside a Grok session (`GROK_SESSION_ID` set), so a
stale one cannot reach a Claude Code run — but it will reach the next Grok one.

Remove the native copy: `grok plugin uninstall claude-mesh --confirm`.

### Confirm this session loaded the branch

Grok:

```bash
SNAP=$(grok inspect --json | python3 -c 'import json,sys; d=json.load(sys.stdin)
print([p["path"] for p in d["plugins"] if p["name"]=="claude-mesh"][0])')
echo "$SNAP"
cmp -s "$SNAP/commands/mesh-review.md" commands/mesh-review.md \
  && echo "SNAP == working tree" || echo "STOP: snapshot is not this tree"
```

Expect a path under `~/.grok/installed-plugins/claude-mesh-*` and `SNAP == working tree`.
`cmp` one file alone proves little: `commands/mesh-review.md` matched a snapshot that was
three commits stale because those commits never touched it. Compare a file your change
touched, or the whole tree — `diff -rq "$SNAP" . -x .git -x docs -x runs` prints nothing
when the snapshot is current.
If the path is `~/.claude/plugins/cache/zinin/claude-mesh/…`, STOP — that is the
published cache, not this tree.

Claude Code: the session was started with `--plugin-dir <this-repo>` and
`claude-mesh@zinin` is disabled. Commands and skills resolve from the working
tree, not `~/.claude/plugins/cache/`.

## While working in this repo

- Agents never edit the user's plugin `config.yaml`.
- Do not bump `.claude-plugin/plugin.json` on a feature branch; version releases
  are a separate `chore(release)` commit on master.
- Before a PR: `git rm -r docs/superpowers/` and commit — plan/design docs must
  not appear in the PR diff (they stay in branch history).
