# claude-restore

Reopen the [Claude Code](https://claude.com/claude-code) sessions you had open
before a crash, a hard power cycle, a GNOME session restart, or a terminal
window that got killed. Linux, GNOME Terminal.

## How it works

1. **A hook records every interactive session.** `hooks/session-registry.sh`
   runs on `SessionStart`, `UserPromptSubmit` and `SessionEnd`, and keeps one
   JSON entry per session in `~/.claude/open-sessions/`: session id, working
   directory, transcript path, and the identity of the `claude` process (pid,
   process start time, boot id).
2. **`claude-restore` works out which of those are gone.** A session is a
   restore candidate when its process is no longer running. The boot id and
   process start time stop a recycled pid from looking alive. A `SessionEnd`
   only marks an entry; a later prompt from the same session clears the mark.
3. **It reopens them** as tabs in a GNOME Terminal window, each running
   `claude --resume <id>` from the directory the session was started in.

Entries that can't be restored are moved to `~/.claude/open-sessions/.retired/`
instead of being offered again and again:

- sessions that never got a prompt, which have nothing to resume
- sessions whose last restore was launched but never started (no
  `SessionStart` within two minutes)

An unreadable entry is rebuilt from its transcript and the events log.
Every hook call and every retirement is appended to
`~/.claude/open-sessions/.events.log`.

## Install

Needs `python3`, `jq`, `flock`, `gnome-terminal`, and `notify-send` for the
desktop launcher.

```sh
git clone https://github.com/jarabek/claude-restore.git
cd claude-restore
./install.sh          # symlinks into ~/.local/bin and ~/.claude/hooks
./install.sh --copy   # or install copies instead
```

Then merge `hooks/settings-snippet.json` into `~/.claude/settings.json`,
replacing `$HOME` with your home directory. If you already have sessions
running, `claude-restore --adopt` records them.

## Use

```sh
claude-restore            # list candidates, then pick which to reopen
claude-restore -y         # reopen all of them
claude-restore --list     # list only
claude-restore -n         # print the commands instead of running them
claude-restore --select 1,3-5
claude-restore --forget 2 # drop an entry
claude-restore --all      # also offer sessions that ended cleanly
claude-restore --json     # machine-readable state
claude-restore --check    # one quiet line if anything is restorable (for a shell rc)
```

`bin/claude-restore-desktop` wraps it for the desktop launcher
(`desktop/claude-restore.desktop.in`): a double-click guard and a notification
with the result.

## Notes

- Closing the terminal window is fine. Claude Code still runs `SessionEnd`
  (reason `other`), so the session is recorded as closed and isn't restored.
- The `UserPromptSubmit` hook runs async, so calls for the same session can
  overlap. Writes go through a registry lock and a unique temp file that must
  hold a valid entry before it replaces the old one. An earlier version shared
  one temp file name per entry, and overlapping calls could leave an entry
  0 bytes long. Because `jq` turns an empty input into an empty output, it then
  stayed empty and the session was skipped.
