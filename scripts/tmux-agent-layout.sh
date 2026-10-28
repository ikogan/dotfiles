#!/usr/bin/env bash
# vim: set ft=sh ts=2 sw=2 et:
#
# tmux-agent-layout — arrange a two-pane "agentic workflow" window based on the
# client's (terminal's) aspect ratio.
#
# Panes are identified by the pane user option `@agentwork-role`, which is set
# by the agent-dev script to either `opencode` or `terminal`. The layout rules
# are:
#
#   - visually wider than tall  -> side-by-side: terminal (large) on the left,
#                                  opencode on the right.
#   - visually taller than wide -> stacked: opencode (large) on the top,
#                                  terminal on the bottom.
#
# "Visually" here assumes a ~2:1 monospaced character cell (height ≈ 2×
# width), so a window counts as taller than wide when `height * 2 > width`.
# This keeps the decision free of any pixel/tty dependency: dimensions come
# straight from tmux's client size (`client_width` x `client_height`).
#
# The "main" (large) pane in tmux's main-vertical / main-horizontal layouts is
# the lowest-indexed pane (whatever the pane-base-index happens to be), so when
# the wrong pane is in that slot we swap the two panes into place. This keeps
# the same logical pane consistently in the correct position as the terminal is
# resized or rotated.
#
# Usage: tmux-agent-layout [target-window] [width] [height]
#   target-window  "session" or "session:window" (defaults to the current window)
#   width, height  client dimensions in cells (defaults to the current client)
#
# ---------------------------------------------------------------------------
# TESTING / ENVIRONMENT NOTE — READ BEFORE CHANGING LAYOUT / RESIZE LOGIC
# ---------------------------------------------------------------------------
# This script decides orientation from tmux's `client_width` x `client_height`
# (character cells) plus a ~2:1 cell assumption.  It does NOT need a tty to
# run, and deliberately avoids `stty size` and the ANSI pixel query
# (ESC [ 14 t) because both require a real terminal.
#
# The coding agent that maintains this script has NO controlling terminal:
# its stdin/stdout are not a tty, and reading /dev/tty fails with
# "No such device or address".  So it can verify the *logic* here but cannot
# exercise real attach/resize behavior.  Any change to how the layout is
# triggered or sized MUST be tested by the human user in a real terminal —
# ASK THE USER to run it.
#
# Verified facts (do not relearn these):
#   • `stty size` reports rows×columns in CHARACTER CELLS, not pixels; a normal
#     font's cell is ~2:1 (height:width), so a 55×86 grid is visually TALL,
#     not wide.  Never compare cols/rows directly to decide orientation.
#   • tmux `run-shell` (the client-attached / client-resized hooks) runs with
#     NO controlling terminal, so the ANSI pixel query can only run from
#     `agent-dev` itself — which is exactly why we don't use it.

set -uo pipefail

target="${1:-}"
width="${2:-}"
height="${3:-}"

if [[ -z "$target" ]]; then
  target="$(tmux display -p '#{session_name}:#{window_index}' 2>/dev/null)" || exit 0
fi

# Resolve dimensions when not supplied (e.g. when invoked by hand).
if [[ -z "$width$height" ]]; then
  width="$(tmux display -p '#{client_width}' 2>/dev/null)"
  height="$(tmux display -p '#{client_height}' 2>/dev/null)"
fi

# Nothing to do unless we have a usable orientation.
[[ "$width" =~ ^[0-9]+$ && "$height" =~ ^[0-9]+$ && "$width" -gt 0 && "$height" -gt 0 ]] || exit 0

# Locate the agent and terminal panes by their role (id + index), so we don't
# depend on pane-base-index being 0.
agent_line="$(tmux list-panes -t "$target" -F '#{pane_id} #{pane_index} #{@agentwork-role}' 2>/dev/null \
  | awk '$3 == "opencode" { print $1, $2; exit }')"
term_line="$(tmux list-panes -t "$target" -F '#{pane_id} #{pane_index} #{@agentwork-role}' 2>/dev/null \
  | awk '$3 == "terminal" { print $1, $2; exit }')"

agent_id="${agent_line%% *}";  agent_idx="${agent_line##* }"
term_id="${term_line%% *}";    term_idx="${term_line##* }"

# Not one of our agent windows (or roles not set yet): leave it alone.
[[ -n "$agent_id" && -n "$term_id" ]] || exit 0

# The "main" (large) pane is whichever pane has the lowest index.
if (( agent_idx < term_idx )); then
  agent_is_main=1
else
  agent_is_main=0
fi

if (( height * 2 > width )); then
  # Visually taller: stacked. opencode (large, top) = 80%, terminal (bottom) = 20%.
  main_size="$(( height * 80 / 100 ))"
  (( main_size >= 1 )) || main_size=1
  tmux set-option -w -t "$target" main-pane-height "$main_size"
  tmux select-layout -t "$target" main-horizontal
  if [[ "$agent_is_main" != "1" ]]; then
    tmux swap-pane -s "$term_id" -t "$agent_id"
  fi
else
  # Visually wider: side by side. main (large, left) = terminal, secondary = opencode.
  main_size="$(( width * 60 / 100 ))"
  (( main_size >= 1 )) || main_size=1
  tmux set-option -w -t "$target" main-pane-width "$main_size"
  tmux select-layout -t "$target" main-vertical
  if [[ "$agent_is_main" == "1" ]]; then
    tmux swap-pane -s "$agent_id" -t "$term_id"
  fi
fi
