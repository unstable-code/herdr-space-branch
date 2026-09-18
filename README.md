# herdr-space-branch

**English** | [한국어](README.ko.md)

A [herdr](https://herdr.dev) plugin that makes the spaces sidebar show the branch of the pane you are
**actually looking at**, instead of whichever repository happens to be in the first tab.

## Why

herdr 0.9.0 resolves a workspace's git identity from the root pane of its **first tab**
(`Workspace::resolved_identity_cwd_from` in `src/workspace.rs`), and both the `branch` and `git_status`
columns come from that one directory. A workspace holding two repositories therefore shows one of them
and never the other:

```
space: PIXELBOOST
├── tab: research-archive   (main)     ← sidebar shows this…
└── tab: homepage           (develop)  ← …while you work here
```

Reordering tabs or splitting the workspace per repository works, but has to be redone by hand every time.

## How it works

- Hooks on `pane.focused`, `tab.focused`, `workspace.focused` and `pane.moved`.
- Each run refreshes **every** workspace, not only the one the event carries: the sidebar draws a row per
  workspace, and switching tabs inside one changes which repository that row should show. A single
  `herdr api snapshot` gives the pane each workspace's active tab is showing.
- Reads that pane's `foreground_cwd` (it follows `cd`, unlike the pane's start directory) and reports two
  workspace metadata tokens with `herdr workspace report-metadata`:

  | token | value |
  |---|---|
  | `branch` | current branch, or `detached@<short sha>` when HEAD is detached |
  | `git_status` | `↑N ↓M` against the upstream, matching the built-in column (`src/ui/sidebar.rs`); cleared when both are zero |

- Both tokens are **cleared** when the focused pane is not inside a git work tree, so the sidebar never shows
  a branch belonging to some other pane.
- Each report carries a millisecond sequence number, so out-of-order events cannot resurrect an older value.
- Some changes reach no hook at all: a branch switched **inside** a pane emits no herdr event, and a tab
  switch does not always deliver one either. A small daemon (`bin/watch`) covers both. It starts detached
  from the `[[startup]]` hook, and the event hooks restart it when it is not running — which also covers
  installing the plugin into an already running server. Only one instance runs (`flock`), and it stops once
  the herdr server stops answering (a stopped server can leave its socket file behind, so three silent
  snapshots in a row are the signal).
  - Each tick (2 s) costs one snapshot plus a `stat` of each workspace's HEAD file; it runs `git` and calls
    herdr only when the visible repository or its HEAD actually changed. Every 15th tick it recomputes
    ahead/behind anyway, which can change on fetch or push without HEAD moving.
  - Both numbers are settings; see Configuration below.
- Which pane a workspace's row follows: the pane focused right now, else the pane that workspace was
  last focused on (remembered per workspace), else the remaining panes of its active tab in layout
  order. The first candidate that really is a git work tree wins — only the globally focused pane is
  marked in the snapshot, so without that order an unfocused workspace would fall back to whatever
  pane happens to come first, often a shell in `$HOME` that would blank the row.

## Requirements

- herdr ≥ 0.9.0 (Linux / macOS)
- `bash`, `jq`, `git`, `flock` (util-linux) on the herdr server's `PATH`

## Installation

```sh
herdr plugin install unstable-code/herdr-space-branch
```

For development, link a local clone instead; the working tree is used directly, so `git pull` is the update:

```sh
git clone https://github.com/unstable-code/herdr-space-branch.git
herdr plugin link ./herdr-space-branch
```

Then render the tokens instead of the built-in columns in `~/.config/herdr/config.toml`:

```toml
[ui.sidebar.spaces]
rows = [["state_icon", "workspace"], ["$branch", "$git_status"]]
```

Apply with `herdr server reload-config` (or your reload key).

Optionally bind the manual refresh action, for when you would rather not wait for a daemon tick:

```toml
[[keys.command]]
key = "prefix+shift+b"
type = "plugin_action"
command = "unstable-code.herdr-space-branch.refresh"
description = "refresh space branch"
```

## Configuration

Optional, in `config.toml` inside this plugin's config directory
(`herdr plugin config-dir unstable-code.herdr-space-branch`):

```toml
strict = false       # see below
interval = 2         # daemon tick, seconds
refresh_every = 15   # ticks between ahead/behind recomputes
```

`strict` decides what happens when the pane you are on is **not** a git work tree — a shell sitting in
`$HOME`, say:

| | `strict = false` (default) | `strict = true` |
|---|---|---|
| Pane you are on is a repository | that repository | that repository |
| Pane you are on is not, another pane of the same tab is | that other repository | row cleared |
| No pane of the tab is a repository | row cleared | row cleared |

So the default keeps the row useful while you step into a plain shell; `strict` keeps it exactly
honest about the pane you are in.

## Verification

Checked on an isolated herdr 0.9.0 server with one workspace holding two repositories: `repo-a` on `main`
(first tab) and `repo-b` on `develop`, two commits ahead of its upstream.

| Focused pane | Workspace tokens |
|---|---|
| `repo-b` | `branch=develop`, `git_status=↑2` |
| `repo-a` | `branch=main` (git_status cleared) |

Running `git switch -c feature-x` inside the focused pane — which herdr emits no event for — was picked up by
the daemon within six seconds, and switching the workspace's active tab to the other repository within five.
Five concurrent `bin/watch --spawn` calls left exactly one daemon, and it stopped after the server did. All
hook runs exited 0, taking about 50-110 ms each.

## Limitations

- The workspace **label** still comes from the first tab; only the branch columns follow the focus.
- A branch switched inside a pane shows up on the next daemon tick (2 s by default) rather than instantly.
- Every focus event spawns a shell, one `herdr pane get` and a couple of `git` calls; the daemon adds one
  `stat` per workspace every two seconds.
- `git_status` is ahead/behind only, like the built-in column. It says nothing about uncommitted changes.

## License

[MIT](LICENSE)
