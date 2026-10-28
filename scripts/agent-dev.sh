#!/usr/bin/env bash
# vim: set ft=sh ts=2 sw=2 et:
#
# agent-dev — build a devcontainer and open a tmux workspace with two panes:
#
#   • an "agent" pane running OpenCode inside a devcontainer
#   • an "IDE/terminal" pane running a shell inside a devcontainer
#
# The devcontainer image is built once, then started twice with
# `devcontainer up`:
#
#   • role "terminal"  -> mounts ${HOME} and the host SSH agent socket
#   • role "opencode"  -> mounts the OpenCode configuration directory
#
# Usage:
#   agent-dev [path/to/workspace] [--config path/to/devcontainer.json]
#             [--background] [--remove-containers]
#   agent-dev list
#   agent-dev attach [session-name]
#   agent-dev reconnect [session-name]
#
#   The workspace defaults to the current directory and the config defaults to
#   .devcontainer/devcontainer.json relative to the workspace. With
#   --background the tmux session is created detached and the script exits
#   without attaching (prints how to attach). --remove-containers removes the
#   workspace's existing devcontainers first so they pick up a rebuilt image.
#
#   `list` lists running agent sessions; `attach` attaches to one (interactively
#   picking with gum when no session name is given). `reconnect` recreates any
#   missing OpenCode or terminal pane in a session and restarts its container
#   if it stopped; it doesn't attach.
#
#   Must be run from a plain terminal — not from inside tmux (it manages the
#   host's tmux session directly and attaches with `attach-session`). The
#   exception is `reconnect`, which never attaches.

set -uo pipefail

# Ctrl+C (or SIGTERM) must abort the whole startup.  The container-start steps
# (`devcontainer up`) respond to this directly; the build step swallows SIGINT
# (the CLI cancels gracefully and exits 0), so its interruption is detected via
# the per-run image label instead (see the build section).
trap 'printf "%s✗ agent-dev: interrupted%s\n" "$ERR_RED" "$ERR_RESET" >&2; exit 130' INT
trap 'exit 143' TERM

# --- helpers ---------------------------------------------------------------

# Colors are ANSI codes only when the stream is a terminal and NO_COLOR is unset,
# so redirected output and logs stay plain text.
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  OUT_CYAN=$'\e[36m'; OUT_GREEN=$'\e[32m'; OUT_DIM=$'\e[2m'; OUT_RESET=$'\e[0m'
else
  OUT_CYAN=""; OUT_GREEN=""; OUT_DIM=""; OUT_RESET=""
fi
if [[ -t 2 && -z "${NO_COLOR:-}" ]]; then
  ERR_RED=$'\e[31m'; ERR_YELLOW=$'\e[33m'; ERR_BOLD=$'\e[1m'; ERR_RESET=$'\e[0m'
else
  ERR_RED=""; ERR_YELLOW=""; ERR_BOLD=""; ERR_RESET=""
fi

die()  { printf '%s✗ agent-dev: error:%s %s\n' "$ERR_RED$ERR_BOLD" "$ERR_RESET" "$*" >&2; exit 1; }
warn() { printf '%s⚠ agent-dev: warning:%s %s\n' "$ERR_YELLOW" "$ERR_RESET" "$*" >&2; }
info() { printf '%s›%s agent-dev: %s\n' "$OUT_CYAN" "$OUT_RESET" "$*"; }
ok()   { printf '%s✔%s agent-dev: %s\n' "$OUT_GREEN" "$OUT_RESET" "$*"; }

has_cmd() { command -v "$1" >/dev/null 2>&1; }

# OpenCode TUI settings for the agent pane: Ctrl+C and Ctrl+D don't exit; Ctrl+X
# then Q does.
OPENCODE_CLI_CONFIG='{"keybinds":{"app.exit":["<leader>q"]}}'

# Where the OpenCode container sees the dotfiles' skills (inside its config dir).
OPENCODE_SKILLS_TARGET=/opencode-config/skills

# agent-dev manages the host's tmux session directly and attaches with
# `attach-session`; running it from inside tmux would nest a second tmux, so
# refuse early.
if [[ -n "${TMUX:-}" && "${1:-}" != "reconnect" && "${1:-}" != "adopt" ]]; then
  die "agent-dev cannot be run from inside tmux; run it from a plain terminal"
fi

usage() {
  cat <<'EOF'
usage: agent-dev [path/to/workspace] [--config path/to/devcontainer.json]
                 [--background] [--remove-containers]
       agent-dev list
       agent-dev attach [session-name]
       agent-dev reconnect [session-name]

Build a devcontainer and open a tmux workspace with two panes:
  • an OpenCode agent pane (runs `opencode` in the "opencode" container)
  • a terminal/IDE pane (runs a shell in the "terminal" container)

The workspace defaults to the current directory and the devcontainer config
defaults to .devcontainer/devcontainer.json relative to the workspace.

  -b, --background   create the tmux session detached and exit without
                     attaching (prints how to attach).

  --remove-containers
                     remove this workspace's existing terminal and OpenCode
                     containers before starting, so they are recreated from
                     the freshly built image.

  list               list running agent sessions.
  attach [name]      attach to an agent session; picks one with gum when no
                     name is given (name may omit the "agent-" prefix).
  reconnect [name]   recreate a missing OpenCode or terminal pane in a session
                     (restarting its container if needed), without attaching.
EOF
}

# canonicalize a path without requiring it to exist
canonicalize() {
  local p="$1"
  if has_cmd realpath; then
    realpath -m "$p" 2>/dev/null || realpath "$p" 2>/dev/null || printf '%s' "$p"
  else
    local d b
    d="$(dirname "$p")"; b="$(basename "$p")"
    ( cd "$d" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$b" ) || printf '%s' "$p"
  fi
}

# read a single top-level field from a JSON document (jq, then python3 fallback)
json_field() {
  local json="$1" key="$2"
  if has_cmd jq; then
    jq -r --arg k "$key" '.[$k] // empty' <<<"$json" 2>/dev/null
  else
    KEY="$key" python3 -c 'import json,sys,os
try:
    v = json.load(sys.stdin).get(os.environ["KEY"])
    print(v if isinstance(v, str) else "")
except Exception:
    pass' <<<"$json" 2>/dev/null
  fi
}

# extract the JSON result line from a devcontainer CLI stdout blob (the CLI
# prints a banner line first, then the JSON result on the last line)
extract_json() {
  printf '%s' "$1" | grep -E '^\{' | tail -1
}

# Return 0 if the devcontainer (per its resolved configuration) already has a
# mount whose target equals $1, 1 otherwise. Used to avoid passing a duplicate
# --mount (Docker rejects duplicate mount points).
devcontainer_mounts_have_target() {
  local target="$1" rc_raw rc_json mounts
  has_cmd devcontainer || return 1
  rc_raw="$(devcontainer read-configuration \
      --workspace-folder "$WORKSPACE_DIR" \
      --config "$DEVCONTAINER_JSON" \
      --include-merged-configuration 2>/dev/null)"
  rc_json="$(extract_json "$rc_raw")"
  [[ -n "$rc_json" ]] || return 1

  if has_cmd jq; then
    jq -e --arg t "$target" '
        ((.configuration.mounts // []) + [.workspace.workspaceMount // ""])
        | any(.[]; (split(",") | index("target=" + $t)))' \
      <<<"$rc_json" >/dev/null 2>&1
  else
    mounts="$(printf '%s\n' "$rc_json" | sed -n 's/.*"target=\([^"]*\)".*/\1/p')"
    [[ "$mounts" == *"$target"* ]]
  fi
}

# Print the home directory of the devcontainer's remote user (where gpg looks
# for ~/.gnupg). Prints nothing when the remote user can't be determined.
devcontainer_remote_home() {
  local rc_raw rc_json user
  has_cmd devcontainer && has_cmd jq || return 0
  rc_raw="$(devcontainer read-configuration \
      --workspace-folder "$WORKSPACE_DIR" \
      --config "$DEVCONTAINER_JSON" \
      --include-merged-configuration 2>/dev/null)"
  rc_json="$(extract_json "$rc_raw")"
  user="$(jq -r '.mergedConfiguration.remoteUser // .configuration.remoteUser // empty' <<<"$rc_json" 2>/dev/null)"
  case "$user" in
    "") return 0 ;;
    root) printf '/root' ;;
    *) printf '/home/%s' "$user" ;;
  esac
}

# Emit a temporary override config for the OpenCode container and print its
# path. The override is the resolved devcontainer configuration with the host
# home mount stripped (so the OpenCode container doesn't see the home dir) and,
# when the host has one, a read-only mount of the host's ~/.gitconfig added.
# Printing nothing means no override is needed. Used with `--override-config`,
# so devcontainer.json itself is never edited.
devcontainer_agent_override() {
  local rc_raw rc_json stripped tmp gc="" sk="" skills_src
  has_cmd devcontainer || return 0
  rc_raw="$(devcontainer read-configuration \
      --workspace-folder "$WORKSPACE_DIR" \
      --config "$DEVCONTAINER_JSON" \
      --include-merged-configuration 2>/dev/null)"
  rc_json="$(extract_json "$rc_raw")"
  [[ -n "$rc_json" ]] || return 0
  [[ -f "$HOME/.gitconfig" ]] && gc="type=bind,source=$HOME/.gitconfig,target=$HOME/.gitconfig,readonly"
  # The dotfiles' OpenCode skills, mounted read-only into the OpenCode config
  # directory (OPENCODE_CONFIG_DIR=/opencode-config), which OpenCode reads skills
  # from. This shadows the host's skills directory, whose links don't resolve in
  # the container.
  skills_src="$(dirname "$SCRIPT_DIR")/opencode/skills"
  [[ -d "$skills_src" ]] && sk="type=bind,source=$skills_src,target=$OPENCODE_SKILLS_TARGET,readonly"

  if has_cmd jq; then
    stripped="$(jq -c --arg home "$HOME" --arg gc "$gc" --arg sk "$sk" '
        .configuration
        | del(.configFilePath)
        | (.mounts // []) as $m
        | ($m | any(.[];
               (. | type) == "string" and
               ((split(",") | index("source=" + $home)) != null or
                (split(",") | index("target=" + $home)) != null))) as $hasHome
        | if $hasHome or $gc != "" or $sk != "" then
            .mounts = ([ $m[] | select(
                (. | type) != "string" or
                ((split(",") | index("source=" + $home)) == null and
                 (split(",") | index("target=" + $home)) == null)) ]
              + (if $gc == "" then [] else [$gc] end)
              + (if $sk == "" then [] else [$sk] end))
          else empty
          end
      ' <<<"$rc_json" 2>/dev/null)"
  else
    stripped="$(HOME="$HOME" GC="$gc" SK="$sk" python3 -c '
import json, sys, os
d = json.load(sys.stdin)
home = os.environ.get("HOME", "")
extra = [v for v in (os.environ.get("GC", ""), os.environ.get("SK", "")) if v]
cfg = d.get("configuration")
if isinstance(cfg, dict):
    cfg.pop("configFilePath", None)
    mounts = cfg.get("mounts") or []
    kept = [m for m in mounts if not (isinstance(m, str) and ("source=" + home in m.split(",") or "target=" + home in m.split(",")))]
    removed = len(kept) != len(mounts)
    if removed or extra:
        cfg["mounts"] = kept + extra
        print(json.dumps(cfg))
' <<<"$rc_json" 2>/dev/null)"
  fi
  [[ -n "$stripped" ]] || return 0

  tmp="$(mktemp "${TMPDIR:-/tmp}/agent-dev-override.XXXXXX")"
  printf '%s\n' "$stripped" > "$tmp"
  printf '%s' "$tmp"
}

# Generate a temporary override config for the build that tags the image with
# `agent-dev-build=<id>` (via `build.options`).  This lets us verify the build
# actually completed, since `devcontainer build` exits 0 even on Ctrl+C.  Prints
# the path, or nothing when the devcontainer is image-based (nothing to build)
# or on failure.
#
# The override is written to a temp file, so any RELATIVE build paths (legacy
# `dockerFile`/`context`, or `build.dockerfile`/`build.context`) must be
# resolved to absolute paths first — otherwise the CLI resolves them relative to
# the temp file's directory instead of `.devcontainer/`.
devcontainer_build_override_with_label() {
  local id="$1" rc_raw rc_json stripped tmp cfgdir
  has_cmd devcontainer || return 0
  rc_raw="$(devcontainer read-configuration \
      --workspace-folder "$WORKSPACE_DIR" \
      --config "$DEVCONTAINER_JSON" \
      --include-merged-configuration 2>/dev/null)"
  rc_json="$(extract_json "$rc_raw")"
  [[ -n "$rc_json" ]] || return 0

  # Directory the devcontainer.json lives in (relative build paths resolve here).
  cfgdir="$(dirname "$DEVCONTAINER_JSON")"

  if has_cmd jq; then
    stripped="$(jq -c --arg id "$id" --arg cfgdir "$cfgdir" '
        def abs($p): if ($p | startswith("/")) then $p else ($cfgdir + "/" + $p) end;
        .configuration
        | del(.configFilePath)
        # legacy dockerFile/context -> build.dockerfile/build.context (absolute)
        | if (.dockerFile != null) then
            .build = ((.build // {}) + { dockerfile: abs(.dockerFile) }) | del(.dockerFile)
          else . end
        | if (.context != null) then
            .build = ((.build // {}) + { context: abs(.context) }) | del(.context)
          else . end
        # modern build.dockerfile/build.context (relative -> absolute)
        | if (.build != null) then
            (if .build.dockerfile != null then .build.dockerfile = abs(.build.dockerfile) else . end)
            | (if .build.context != null then .build.context = abs(.build.context) else . end)
          else . end
        # tag the build so we can confirm it completed (image-based -> no output)
        | if (.build != null) then
            .build.options = ((.build.options // []) + ["--label", ("agent-dev-build=" + $id)])
          else empty end
      ' <<<"$rc_json" 2>/dev/null)"
  else
    stripped="$(ID="$id" CFGDIR="$cfgdir" python3 -c '
import json, sys, os
d = json.load(sys.stdin)
cfg = d.get("configuration")
if isinstance(cfg, dict):
    cfg.pop("configFilePath", None)
    cfgdir = os.environ.get("CFGDIR", "")
    def absp(p):
        return p if p.startswith("/") else os.path.normpath(os.path.join(cfgdir, p))
    # legacy dockerFile/context -> build.dockerfile/build.context (absolute)
    if cfg.get("dockerFile"):
        b = cfg.setdefault("build", {})
        b["dockerfile"] = absp(cfg["dockerFile"])
        del cfg["dockerFile"]
    if cfg.get("context"):
        b = cfg.setdefault("build", {})
        b["context"] = absp(cfg["context"])
        del cfg["context"]
    # modern build.dockerfile/build.context (relative -> absolute)
    b = cfg.get("build")
    if isinstance(b, dict):
        if b.get("dockerfile"):
            b["dockerfile"] = absp(b["dockerfile"])
        if b.get("context"):
            b["context"] = absp(b["context"])
        b.setdefault("options", []).extend(["--label", "agent-dev-build=" + os.environ["ID"]])
        print(json.dumps(cfg))
' <<<"$rc_json" 2>/dev/null)"
  fi
  [[ -n "$stripped" ]] || return 0

  tmp="$(mktemp "${TMPDIR:-/tmp}/agent-dev-build.XXXXXX")"
  printf '%s\n' "$stripped" > "$tmp"
  printf '%s' "$tmp"
}

# Run `devcontainer up "$@"`, showing its output (including the output of the
# container's lifecycle scripts) live, and store the full output in the variable
# named by the first argument. The CLI's JSON result line is left out of the
# display; it is still in the stored output for extract_json.
devcontainer_up() {
  local __out_var="$1" __log __rc
  shift
  __log="$(mktemp)"
  devcontainer up "$@" 2>&1 | tee "$__log" \
    | sed -u -e '/^{"outcome"/d' -e "s/^/${OUT_DIM}│ ${OUT_RESET}/"
  __rc=${PIPESTATUS[0]}
  printf -v "$__out_var" '%s' "$(cat "$__log")"
  rm -f "$__log"
  return "$__rc"
}

# Print the JSON error from a failed `devcontainer up` and exit non-zero.
fail_devcontainer_up() {
  local label="$1" out="${2:-}" err=""
  if [[ -n "$out" ]] && has_cmd jq; then
    err="$(extract_json "$out" | jq -r '.message // .description // empty' 2>/dev/null | head -5)"
  fi
  if [[ -n "$err" ]]; then
    printf '%s✗ agent-dev: devcontainer up (%s) failed:%s\n%s\n' "$ERR_RED$ERR_BOLD" "$label" "$ERR_RESET" "$err" >&2
  else
    printf '%s✗ agent-dev: devcontainer up (%s) failed%s\n' "$ERR_RED$ERR_BOLD" "$label" "$ERR_RESET" >&2
  fi
  exit 1
}

# --- session helpers --------------------------------------------------------

# List tmux sessions created by agent-dev (named "agent-*").
agent_sessions() {
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^agent-' || true
}

# Resolve a user-provided name (with or without the "agent-" prefix) to the
# actual session name; returns non-zero if the session doesn't exist.
resolve_session() {
  local name="$1" resolved
  if [[ "$name" == agent-* ]]; then
    resolved="$name"
  else
    resolved="agent-$name"
  fi
  tmux has-session -t "$resolved" 2>/dev/null || return 1
  printf '%s' "$resolved"
}

# Attach the current terminal to a session.
attach_session() {
  tmux attach-session -t "$1"
}

# Interactive picker fallback when gum is unavailable: numbered list + prompt.
# Returns non-zero if the selection is invalid.
pick_session() {
  local sessions="$1" name n i=1
  while IFS= read -r name; do
    printf '%d) %s\n' "$i" "$name" >&2
    i=$((i+1))
  done <<< "$sessions"
  printf 'Select a session [1-%d]: ' "$((i-1))" >&2
  IFS= read -r n
  [[ "$n" =~ ^[0-9]+$ && "$n" -ge 1 && "$n" -lt "$i" ]] || return 1
  printf '%s\n' "$sessions" | sed -n "${n}p"
}

# agent-dev list — list running agent sessions.
cmd_list() {
  has_cmd tmux || die "tmux not found on PATH"
  local sessions name status
  sessions="$(agent_sessions)"
  if [[ -z "$sessions" ]]; then
    info "no agent sessions"
    return 0
  fi
  while IFS= read -r name; do
    status="$(tmux display-message -p -t "$name" '#{?session_attached,attached,detached}' 2>/dev/null)"
    if [[ "$status" == "attached" ]]; then
      printf '%s●%s %-32s %sattached%s\n' "$OUT_GREEN" "$OUT_RESET" "$name" "$OUT_GREEN" "$OUT_RESET"
    else
      printf '%s○%s %-32s %sdetached%s\n' "$OUT_DIM" "$OUT_RESET" "$name" "$OUT_DIM" "$OUT_RESET"
    fi
  done <<< "$sessions"
}

# agent-dev attach [name] — attach to an agent session (gum picker if no name).
cmd_attach() {
  has_cmd tmux || die "tmux not found on PATH"
  local target="${1:-}" sessions name
  sessions="$(agent_sessions)"
  [[ -n "$sessions" ]] || die "no agent sessions to attach to"

  if [[ -n "$target" ]]; then
    if ! name="$(resolve_session "$target")"; then
      die "no agent session: $target"
    fi
  elif [[ "$sessions" != *$'\n'* ]]; then
    # Exactly one session — attach to it directly (nothing to choose).
    name="$sessions"
  elif has_cmd gum; then
    # Note: gum renders its TUI to stderr, so don't redirect it away.
    name="$(printf '%s\n' "$sessions" | gum choose --header 'Select an agent session' || true)"
    [[ -n "$name" ]] || die "no session selected"
  else
    if ! name="$(pick_session "$sessions")"; then
      die "invalid selection"
    fi
  fi

  info "attaching to session '$name'..."
  attach_session "$name"
}

# The devcontainer of a given role for a workspace (empty if none exists).
role_container() {
  docker ps -aq --filter "label=devcontainer.role=$1" --filter "label=devcontainer.local_folder=$2" 2>/dev/null | head -1
}

# The remote user devcontainer recorded for a container.
remote_user_of() {
  docker inspect -f '{{index .Config.Labels "devcontainer.metadata"}}' "$1" 2>/dev/null \
    | jq -r '[.. | objects | .remoteUser? // empty] | last // empty' 2>/dev/null
}

# Start a container if it isn't running; fails if it doesn't exist.
ensure_running() {
  local id="$1" role="$2" state
  [[ -n "$id" ]] || die "no $role container for this workspace; rebuild it with: agent-dev <workspace>"
  state="$(docker inspect -f '{{.State.Status}}' "$id")"
  if [[ "$state" != "running" ]]; then
    info "starting $role container ($state)..."
    docker start "$id" >/dev/null || die "could not start the $role container"
  fi
}

# Set pane_cmd to the docker exec command that runs a role's pane.
pane_command() {
  local role="$1" cid="$2" user ws shell
  ws="/workspaces/$(basename "$workspace")"
  user="$(remote_user_of "$cid")"
  [[ -n "$user" ]] || die "could not determine the remote user of the $role container"
  if [[ "$role" == "opencode" ]]; then
    pane_exec=(docker exec -it -u "$user" -w "$ws"
      -e "OPENCODE_CONFIG_DIR=/opencode-config" -e "XDG_DATA_HOME=/opencode-data"
      -e "OPENCODE_CLI_CONFIG_CONTENT=$OPENCODE_CLI_CONFIG" "$cid" opencode)
    [[ "$(docker inspect "$cid" --format '{{.HostConfig.NetworkMode}}')" == "host" ]] && pane_exec+=(--standalone)
  else
    pane_exec=(docker exec -it -u "$user" -w "$ws" -e "GNUPGHOME=")
    local runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}" ssh_sock=""
    if docker exec "$cid" test -d "$runtime_dir" 2>/dev/null; then
      pane_exec+=(-e "XDG_RUNTIME_DIR=$runtime_dir")
    fi
    if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
      case "$SSH_AUTH_SOCK" in
        "$runtime_dir"/*) ssh_sock="$SSH_AUTH_SOCK" ;;
        *) ssh_sock="/var/lib/ssh-agent/$(basename "$SSH_AUTH_SOCK")" ;;
      esac
      docker exec "$cid" test -S "$ssh_sock" 2>/dev/null && pane_exec+=(-e "SSH_AUTH_SOCK=$ssh_sock")
    fi
    shell="$(docker exec "$cid" sh -c \
      'for s in zsh bash; do p=$(command -v "$s" 2>/dev/null) && { printf "%s" "$p"; exit 0; }; done; printf "/bin/sh"' 2>/dev/null)"
    pane_exec+=("$cid" "${shell:-/bin/sh}" -l)
  fi
}

# agent-dev reconnect [name] — recreate or restart the OpenCode and terminal
# panes of an agent session, starting their containers first if they stopped.
cmd_reconnect() {
  has_cmd tmux   || die "tmux not found on PATH"
  has_cmd docker || die "docker not found on PATH"
  has_cmd jq     || die "jq not found on PATH"
  local target="${1:-}" sessions session workspace role pane dead cid window created=0
  sessions="$(agent_sessions)"
  [[ -n "$sessions" ]] || die "no agent sessions to reconnect"
  if [[ -n "$target" ]]; then
    session="$(resolve_session "$target")" || die "no agent session: $target"
  elif [[ "$sessions" != *$'\n'* ]]; then
    session="$sessions"
  else
    die "several agent sessions; name one: agent-dev reconnect <name> ($(tr '\n' ' ' <<<"$sessions" | sed 's/ $//'))"
  fi

  workspace="$(tmux display-message -p -t "$session" '#{session_path}')"
  [[ -d "$workspace" ]] || die "cannot determine the workspace for $session"

  for role in opencode terminal; do
    read -r pane dead <<<"$(tmux list-panes -t "$session" -F '#{pane_id}|#{@agentwork-role}|#{pane_dead}' \
      | awk -F'|' -v r="$role" '$2 == r { print $1, $3; exit }')"
    if [[ -n "$pane" && "$dead" != "1" ]]; then
      ok "$role pane is connected"
      continue
    fi

    cid="$(role_container "$role" "$workspace")"
    ensure_running "$cid" "$role"
    pane_command "$role" "$cid"

    if [[ -n "$pane" ]]; then
      tmux respawn-pane -k -t "$pane" "${pane_exec[@]}"
      ok "restarted $role pane"
    else
      local base new
      base="$(tmux list-panes -t "$session" -F '#{pane_id}' | head -1)"
      new="$(tmux split-window -t "$base" -h -c "$workspace" -P -F '#{pane_id}' "${pane_exec[@]}")"
      tmux set-option -p -t "$new" @agentwork-role "$role"
      tmux select-pane -t "$new" -T "$role"
      ok "recreated $role pane"
      created=1
    fi
  done

  # Re-apply the layout when panes were added, using the same helper as the
  # attach hook.
  if [[ "$created" == "1" ]]; then
    local self layout
    self="$(readlink -f "${BASH_SOURCE[0]}")"
    layout="$(dirname "$self")/tmux-agent-layout.sh"
    if [[ -x "$layout" ]]; then
      window="$session:$(tmux display-message -p -t "$session" '#{window_index}')"
      local w h
      read -r w h <<<"$(tmux display-message -p -t "$session" '#{window_width} #{window_height}')"
      "$layout" "$window" "$w" "$h"
    fi
  fi
  ok "session '$session' is ready; attach with: agent-dev attach ${session#agent-}"
}

# agent-dev adopt <pane> — turn a new host shell pane in an agent session into a
# container shell. If no OpenCode pane is running in the session, it runs
# OpenCode instead, so a split brings the agent back after it exits. Run by
# tmux's after-split-window hook, so splits made any way end up in the container.
cmd_adopt() {
  local pane="${1:-}" session workspace role cid
  [[ -n "$pane" ]] || die "adopt needs a pane id"
  has_cmd tmux   || die "tmux not found on PATH"
  has_cmd docker || die "docker not found on PATH"
  has_cmd jq     || die "jq not found on PATH"

  session="$(tmux display-message -p -t "$pane" '#{session_name}')"
  [[ "$session" == agent-* ]] || return 0
  # Already a container pane (for example one created by reconnect): nothing to do.
  if tmux display-message -p -t "$pane" '#{pane_start_command}' | grep -q 'docker exec'; then
    return 0
  fi

  role="terminal"
  if ! tmux list-panes -t "$session" -F '#{pane_id}|#{@agentwork-role}|#{pane_dead}' \
      | awk -F'|' -v p="$pane" '$1 != p && $2 == "opencode" && $3 == "0" { found = 1 } END { exit !found }'; then
    role="opencode"
  fi

  workspace="$(tmux display-message -p -t "$pane" '#{session_path}')"
  [[ -d "$workspace" ]] || die "cannot determine the workspace for pane $pane"
  cid="$(role_container "$role" "$workspace")"
  ensure_running "$cid" "$role"
  pane_command "$role" "$cid"
  tmux respawn-pane -k -t "$pane" "${pane_exec[@]}"
  tmux set-option -p -t "$pane" @agentwork-role "$role"
  tmux select-pane -t "$pane" -T "$role"
}

# --- argument parsing ------------------------------------------------------

COMMAND="build"     # build | list | attach | reconnect | adopt
WORKSPACE_ARG=""
CONFIG_ARG=""
BACKGROUND=0
REMOVE_CONTAINERS=0
ATTACH_TARGET=""
SUB_ARGS=()

# Detect the subcommand when the first argument is one of the subcommands below.
if [[ "${1:-}" == "list" || "${1:-}" == "attach" || "${1:-}" == "reconnect" || "${1:-}" == "adopt" ]]; then
  COMMAND="$1"
  shift
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      [[ $# -ge 2 ]] || die "--config requires a path"
      CONFIG_ARG="$2"; shift 2 ;;
    --config=*)
      CONFIG_ARG="${1#--config=}"; shift ;;
    -b|--background)
      BACKGROUND=1; shift ;;
    --remove-containers)
      REMOVE_CONTAINERS=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    -*)
      die "unknown option: $1" ;;
    *)
      case "$COMMAND" in
        adopt)
          SUB_ARGS+=("$1"); shift ;;
        attach|reconnect)
          [[ -z "$ATTACH_TARGET" ]] || die "unexpected argument: $1"
          ATTACH_TARGET="$1"; shift ;;
        *)
          [[ -z "$WORKSPACE_ARG" ]] || die "unexpected argument: $1"
          WORKSPACE_ARG="$1"; shift ;;
      esac
      ;;
  esac
done

# list/attach/reconnect don't go through the devcontainer build — dispatch and exit.
case "$COMMAND" in
  list)
    cmd_list
    exit 0 ;;
  attach)
    cmd_attach "$ATTACH_TARGET"
    exit 0 ;;
  reconnect)
    cmd_reconnect "$ATTACH_TARGET"
    exit 0 ;;
  adopt)
    cmd_adopt "${SUB_ARGS[@]}"
    exit 0 ;;
esac

WORKSPACE_ARG="${WORKSPACE_ARG:-.}"

# --- preflight -------------------------------------------------------------

has_cmd devcontainer || die "devcontainer CLI not found on PATH"
has_cmd docker      || die "docker not found on PATH"
has_cmd tmux        || die "tmux not found on PATH"

WORKSPACE_DIR="$(cd "$WORKSPACE_ARG" 2>/dev/null && pwd -P)" \
  || die "cannot access workspace: $WORKSPACE_ARG"

if [[ -n "$CONFIG_ARG" ]]; then
  if [[ "$CONFIG_ARG" = /* ]]; then
    DEVCONTAINER_JSON="$(canonicalize "$CONFIG_ARG")"
  else
    DEVCONTAINER_JSON="$(canonicalize "$WORKSPACE_DIR/$CONFIG_ARG")"
  fi
else
  DEVCONTAINER_JSON="$(canonicalize "$WORKSPACE_DIR/.devcontainer/devcontainer.json")"
fi

# Relative path for the `devcontainer.config_file` label (VS Code convention).
if [[ "$DEVCONTAINER_JSON" = "$WORKSPACE_DIR"/* ]]; then
  DEVCONTAINER_JSON_REL="${DEVCONTAINER_JSON#"$WORKSPACE_DIR"/}"
else
  DEVCONTAINER_JSON_REL="$DEVCONTAINER_JSON"
fi

USERNAME="$(id -un)"
OPENCODE_CONFIG_DIR_HOST="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
# Per-workspace OpenCode data dir persisted on the host, so each container keeps
# its OWN SQLite DB (sessions + credentials) across recreation — never shared
# with the host or other containers. Credentials are copied in with
# `opencode auth import` rather than by sharing the DB.
#
# Layout: .../opencode-containers/<basename>/<hash-of-full-path> so it's easy to
# find by name, but two workspaces that share a basename don't collide.
OPENCODE_WORKSPACE_KEY="$(basename "$WORKSPACE_DIR")/$(printf '%s' "$WORKSPACE_DIR" | sha256sum | cut -c1-12)"
OPENCODE_DATA_PERSIST_DIR="${XDG_DATA_HOME:-${HOME}/.local/share}/opencode-containers/${OPENCODE_WORKSPACE_KEY}"

# Resolve the layout helper script next to this script (through symlinks).
SELF="${BASH_SOURCE[0]}"
if has_cmd readlink; then
  SELF="$(readlink -f "$SELF" 2>/dev/null || printf '%s' "$SELF")"
fi
SCRIPT_DIR="$(cd "$(dirname "$SELF")" && pwd -P)"
LAYOUT_HELPER="$SCRIPT_DIR/tmux-agent-layout.sh"
[[ -x "$LAYOUT_HELPER" ]] || LAYOUT_HELPER="$SCRIPT_DIR/tmux-agent-layout"
[[ -x "$LAYOUT_HELPER" ]] || LAYOUT_HELPER=""
SETUP_MCP="$SCRIPT_DIR/setup-mcp.sh"
[[ -x "$SETUP_MCP" ]] || SETUP_MCP="$(command -v setup-mcp 2>/dev/null || true)"
[[ -x "${SETUP_MCP:-}" ]] || SETUP_MCP=""

# Ensure the OpenCode MCP config points at the network MCP servers before the
# agent container mounts it (otherwise it would try to invoke them locally).
if [[ -n "$SETUP_MCP" ]]; then
  "$SETUP_MCP" --translate-only || warn "OpenCode MCP config translation failed"
else
  warn "setup-mcp not found; OpenCode MCP config will not be translated"
fi

# --- remove existing containers (--remove-containers) ----------------------

if [[ "$REMOVE_CONTAINERS" == "1" ]]; then
  mapfile -t old_ctrs < <(docker ps -aq --filter "label=devcontainer.local_folder=$WORKSPACE_DIR" 2>/dev/null)
  if (( ${#old_ctrs[@]} )); then
    info "removing ${#old_ctrs[@]} existing container(s) for this workspace..."
    docker rm -f "${old_ctrs[@]}" >/dev/null || die "could not remove existing containers"
  else
    info "no existing containers to remove"
  fi
fi

# --- build the devcontainer image ------------------------------------------

info "workspace: $WORKSPACE_DIR"
info "config:    $DEVCONTAINER_JSON_REL"
info "building devcontainer image..."

# Build runs in the foreground: the devcontainer CLI needs the real terminal to
# build and show progress.  It exits 0 even when Ctrl+C cancels the build, so we
# tag the image with a unique per-run label and verify it afterwards.
build_id="$(date +%s)-$$"
build_override="$(devcontainer_build_override_with_label "$build_id")"
if [[ -n "$build_override" ]]; then
  if ! devcontainer build --workspace-folder "$WORKSPACE_DIR" --config "$build_override"; then
    rm -f "$build_override"
    die "devcontainer build failed"
  fi
  rm -f "$build_override"

  # Confirm the image was actually rebuilt (Ctrl+C cancels the build but still
  # exits 0, so the exit code alone can't tell us).
  found=""
  while IFS= read -r img; do
    img_label="$(docker inspect --format '{{index .Config.Labels "agent-dev-build"}}' "$img" 2>/dev/null)"
    [[ "$img_label" == "$build_id" ]] && { found=1; break; }
  done < <(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep "^vsc-$(basename "$WORKSPACE_DIR")-")
  [[ "$found" == "1" ]] || die "devcontainer build was interrupted — image was not rebuilt"
else
  if ! devcontainer build --workspace-folder "$WORKSPACE_DIR" --config "$DEVCONTAINER_JSON"; then
    die "devcontainer build failed"
  fi
fi

# --- start the two devcontainers -------------------------------------------

# Common arguments for both containers.
common_args=(
  --workspace-folder "$WORKSPACE_DIR"
  --config "$DEVCONTAINER_JSON"
  --id-label "devcontainer.local_folder=$WORKSPACE_DIR"
  --id-label "devcontainer.config_file=$DEVCONTAINER_JSON_REL"
)

# 1. IDE/terminal container: mounts ${HOME} and the host SSH agent socket.
info "starting terminal/IDE devcontainer..."
term_args=("${common_args[@]}")
term_args+=(--id-label "devcontainer.role=terminal")

# Mount the host HOME at /home/<username> for the terminal container, but only
# if the devcontainer doesn't already do it (Docker rejects duplicate mount
# points — e.g. grafana's devcontainer.json bind-mounts ${HOME} readonly).
HOME_MOUNT_TARGET="/home/$USERNAME"
if devcontainer_mounts_have_target "$HOME_MOUNT_TARGET"; then
  info "devcontainer already mounts $HOME_MOUNT_TARGET; skipping duplicate HOME mount"
else
  term_args+=(--mount "type=bind,source=$HOME,target=$HOME_MOUNT_TARGET")
fi

# Forward the host's SSH + GPG agents into the terminal container.  The gcr
# (SSH) and gpg-agent sockets — and the gnome-keyring/libsecret socket — live
# under $XDG_RUNTIME_DIR, and the GnuPG keyring lives in ~/.gnupg.  Mount socket
# DIRECTORIES (not socket files): a file mount goes stale when the agent
# recreates its socket on restart.
runtime_dir="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
if [[ -d "$runtime_dir" ]]; then
  term_args+=(--mount "type=bind,source=$runtime_dir,target=$runtime_dir")
  term_args+=(--remote-env "XDG_RUNTIME_DIR=$runtime_dir")
fi

ssh_auth_sock_fwd=""
if [[ -n "${SSH_AUTH_SOCK:-}" ]]; then
  case "$SSH_AUTH_SOCK" in
    "$runtime_dir"/*)
      # Already under the mounted runtime dir — keep the original path.
      ssh_auth_sock_fwd="$SSH_AUTH_SOCK" ;;
    *)
      ssh_dir="$(dirname "$SSH_AUTH_SOCK")"; ssh_name="$(basename "$SSH_AUTH_SOCK")"
      term_args+=(--mount "type=bind,source=$ssh_dir,target=/var/lib/ssh-agent")
      ssh_auth_sock_fwd="/var/lib/ssh-agent/$ssh_name" ;;
  esac
  term_args+=(--remote-env "SSH_AUTH_SOCK=$ssh_auth_sock_fwd")
else
  warn "SSH_AUTH_SOCK is not set; skipping SSH agent forwarding"
fi

# GnuPG: the host agent does the unlocking.  It runs pinentry-gnome3, which
# prompts through gcr/gnome-keyring (libsecret) on the host session bus and
# caches the passphrase, so the container only needs to reach that agent and
# read the keyring.  gpg finds the agent socket under $XDG_RUNTIME_DIR/gnupg
# (forwarded above) only when its homedir is the remote user's default
# ~/.gnupg; any other homedir looks elsewhere and falls back to a local agent
# with no pinentry.  So: GNUPGHOME is cleared (this also overrides a GNUPGHOME
# baked into the image), and the host ~/.gnupg is mounted at the remote user's
# default ~/.gnupg.
term_args+=(--remote-env "GNUPGHOME=")
term_gnupg_target=""
if [[ -d "$HOME/.gnupg" ]]; then
  term_home="$(devcontainer_remote_home)"
  if [[ -n "$term_home" ]]; then
    term_gnupg_target="$term_home/.gnupg"
    if devcontainer_mounts_have_target "$term_gnupg_target"; then
      info "devcontainer already mounts $term_gnupg_target; skipping GnuPG keyring mount"
    else
      term_args+=(--mount "type=bind,source=$HOME/.gnupg,target=$term_gnupg_target")
    fi
  else
    warn "could not determine the devcontainer's remote user home; skipping GnuPG keyring mount"
  fi
else
  warn "no ~/.gnupg; skipping GnuPG keyring mount"
fi

# If an existing terminal container predates the agent-forwarding mounts (or
# has the old /tmp-* mounts, which the docker-in-docker tmpfs covers), remove it
# so `devcontainer up` recreates it — `up` reuses an existing container by label
# and would otherwise keep the stale mounts.
if [[ -d "$runtime_dir" ]]; then
  existing_term="$(docker ps -aq --filter "label=devcontainer.role=terminal" --filter "label=devcontainer.local_folder=$WORKSPACE_DIR" 2>/dev/null | head -1)"
  if [[ -n "$existing_term" ]]; then
    mounts="$(docker inspect "$existing_term" --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>/dev/null)"
    stale=0
    grep -qxF "$runtime_dir" <<<"$mounts" || stale=1
    grep -qxF "/var/lib/gnupg" <<<"$mounts" && stale=1
    if [[ -n "$term_gnupg_target" ]] && ! grep -qxF "$term_gnupg_target" <<<"$mounts"; then
      stale=1
    fi
    if [[ "$stale" == "1" ]]; then
      info "removing existing terminal container (missing agent-forwarding mounts)"
      docker rm -f "$existing_term" >/dev/null 2>&1 || true
      info "recreating terminal container (applies features + postCreateCommand; this can take a while)..."
    fi
  fi
fi

if ! devcontainer_up term_out "${term_args[@]}"; then
  fail_devcontainer_up "terminal" "$term_out"
fi
term_json="$(extract_json "$term_out")"
term_id="$(json_field "$term_json" containerId)"
term_user="$(json_field "$term_json" remoteUser)"
term_ws="$(json_field "$term_json" remoteWorkspaceFolder)"
[[ -n "$term_id" ]] || die "could not determine container id for the terminal container"

# 2. Agent container: mounts the OpenCode config dir and a per-container
#    persistent data dir (NOT the host's shared data dir).
info "starting OpenCode agent devcontainer..."
# Pre-create the data dir (not just its parent): OpenCode creates log/ etc. with
# a non-recursive mkdir, so the data dir itself must already exist.
mkdir -p "$OPENCODE_DATA_PERSIST_DIR/opencode"
agent_args=("${common_args[@]}")
agent_args+=(--id-label "devcontainer.role=opencode")
agent_args+=(--mount "type=bind,source=$OPENCODE_CONFIG_DIR_HOST,target=/opencode-config")
agent_args+=(--remote-env "OPENCODE_CONFIG_DIR=/opencode-config")
agent_args+=(--mount "type=bind,source=$OPENCODE_DATA_PERSIST_DIR,target=/opencode-data")
agent_args+=(--remote-env "XDG_DATA_HOME=/opencode-data")

# Ignore any home-directory mount the devcontainer.json declares: OpenCode uses
# its own isolated config/data dirs, so the host home mount is unwanted here.
# We strip it via a generated --override-config instead of editing the file.
agent_override="$(devcontainer_agent_override)"
if [[ -n "$agent_override" ]]; then
  agent_args+=(--override-config "$agent_override")
fi

# If an existing agent container was created before this override existed, it
# still carries the devcontainer.json's home-dir mount.  Remove it so
# `devcontainer up` recreates it without the mount (otherwise it would just be
# reused as-is and the home dir would remain visible).
if [[ -n "$agent_override" ]]; then
  existing_agent="$(docker ps -aq --filter "label=devcontainer.role=opencode" --filter "label=devcontainer.local_folder=$WORKSPACE_DIR" 2>/dev/null | head -1)"
  if [[ -n "$existing_agent" ]] \
      && docker inspect "$existing_agent" --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>/dev/null | grep -qxF "$HOME"; then
    info "removing existing OpenCode container (still has home-dir mount)"
    docker rm -f "$existing_agent" >/dev/null 2>&1 || true
    info "recreating OpenCode container (applies features + postCreateCommand; this can take a while)..."
  fi
fi

# Likewise, a container created before the git config mount existed must be
# recreated so it picks the mount up.
if [[ -f "$HOME/.gitconfig" ]]; then
  existing_agent="$(docker ps -aq --filter "label=devcontainer.role=opencode" --filter "label=devcontainer.local_folder=$WORKSPACE_DIR" 2>/dev/null | head -1)"
  if [[ -n "$existing_agent" ]] \
      && ! docker inspect "$existing_agent" --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>/dev/null | grep -qxF "$HOME/.gitconfig"; then
    info "removing existing OpenCode container (missing git config mount)"
    docker rm -f "$existing_agent" >/dev/null 2>&1 || true
    info "recreating OpenCode container (applies features + postCreateCommand; this can take a while)..."
  fi
fi

# Likewise for the shared OpenCode skills mount.
if [[ -d "$(dirname "$SCRIPT_DIR")/opencode/skills" ]]; then
  existing_agent="$(docker ps -aq --filter "label=devcontainer.role=opencode" --filter "label=devcontainer.local_folder=$WORKSPACE_DIR" 2>/dev/null | head -1)"
  if [[ -n "$existing_agent" ]] \
      && ! docker inspect "$existing_agent" --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>/dev/null | grep -qxF "$OPENCODE_SKILLS_TARGET"; then
    info "removing existing OpenCode container (missing skills mount)"
    docker rm -f "$existing_agent" >/dev/null 2>&1 || true
    info "recreating OpenCode container (applies features + postCreateCommand; this can take a while)..."
  fi
fi

devcontainer_up agent_out "${agent_args[@]}" \
  || { fail_devcontainer_up "opencode" "$agent_out"; }
[[ -n "$agent_override" ]] && rm -f "$agent_override"
agent_json="$(extract_json "$agent_out")"
agent_id="$(json_field "$agent_json" containerId)"
agent_user="$(json_field "$agent_json" remoteUser)"
agent_ws="$(json_field "$agent_json" remoteWorkspaceFolder)"
[[ -n "$agent_id" ]] || die "could not determine container id for the agent container"

# --- decide what to run in each pane ---------------------------------------

# Prefer zsh, then bash, then plain sh for the terminal pane.
term_shell="$(docker exec "$term_id" sh -c \
  'for s in zsh bash; do p=$(command -v "$s" 2>/dev/null) && { printf "%s" "$p"; exit 0; }; done; printf "/bin/sh"' 2>/dev/null)"
term_shell="${term_shell:-/bin/sh}"

have_opencode=0
if docker exec "$agent_id" sh -c 'command -v opencode >/dev/null 2>&1' 2>/dev/null; then
  have_opencode=1
else
  # Install opencode into the agent container by copying the host binary
  # (same architecture; the devcontainer image may not ship opencode).
  host_opencode="$(command -v opencode 2>/dev/null || true)"
  if [[ -n "$host_opencode" ]] \
      && docker cp "$host_opencode" "$agent_id":/usr/local/bin/opencode 2>/dev/null \
      && docker exec "$agent_id" sh -c 'command -v opencode >/dev/null 2>&1' 2>/dev/null; then
    ok "installed opencode into the agent container from $host_opencode"
    have_opencode=1
  else
    warn "'opencode' is not installed in the agent container and could not be copied; the agent pane will open a shell instead"
  fi
fi
if [[ "$have_opencode" != "1" ]]; then
  agent_shell="$(docker exec "$agent_id" sh -c \
    'for s in zsh bash; do p=$(command -v "$s" 2>/dev/null) && { printf "%s" "$p"; exit 0; }; done; printf "/bin/sh"' 2>/dev/null)"
  agent_shell="${agent_shell:-/bin/sh}"
fi

# Copy the host's OpenCode credentials into the container's own DB (idempotent:
# `auth import` skips credentials already present). This is how we avoid sharing
# the SQLite DB between the host and container servers. Run as the container's
# remote user so the DB it creates is owned by the same user that runs OpenCode.
if [[ "$have_opencode" == "1" ]]; then
  creds="$(opencode auth export --standalone 2>/dev/null || true)"
  if [[ -n "$creds" && "$creds" != "[]" ]]; then
    if docker exec -i -u "$agent_user" -e "XDG_DATA_HOME=/opencode-data" -e "OPENCODE_CONFIG_DIR=/opencode-config" \
        "$agent_id" opencode auth import --standalone <<<"$creds" 2>/dev/null; then
      ok "imported host OpenCode credentials into the agent container"
    else
      warn "failed to import OpenCode credentials into the agent container"
    fi
  fi
fi

# Terminal pane: docker exec a login shell with the SSH + GPG agents forwarded.
term_exec=(docker exec -it)
[[ -n "$term_user" ]] && term_exec+=(-u "$term_user")
[[ -n "$term_ws" ]] && term_exec+=(-w "$term_ws")
[[ -n "$ssh_auth_sock_fwd" ]] && term_exec+=(-e "SSH_AUTH_SOCK=$ssh_auth_sock_fwd")
term_exec+=(-e "GNUPGHOME=")
[[ -d "$runtime_dir" ]] && term_exec+=(-e "XDG_RUNTIME_DIR=$runtime_dir")
term_exec+=("$term_id" "$term_shell" -l)

# The agent container inherits the devcontainer's network mode.  With host
# networking (runArgs: ["--network=host"]) it shares the host's loopback, so
# OpenCode's background service would collide with the host's own OpenCode
# service port (49374) and kill the pane.  Only in that case run --standalone
# (a private server on a random port); otherwise keep the normal background
# service.
agent_net="$(docker inspect "$agent_id" --format '{{.HostConfig.NetworkMode}}' 2>/dev/null)"

# Agent pane: docker exec opencode (or a shell fallback) with the config + data.
agent_exec=(docker exec -it)
[[ -n "$agent_user" ]] && agent_exec+=(-u "$agent_user")
[[ -n "$agent_ws" ]] && agent_exec+=(-w "$agent_ws")
agent_exec+=(-e "OPENCODE_CONFIG_DIR=/opencode-config")
agent_exec+=(-e "XDG_DATA_HOME=/opencode-data")
agent_exec+=(-e "OPENCODE_CLI_CONFIG_CONTENT=$OPENCODE_CLI_CONFIG")
if [[ "$have_opencode" == "1" ]]; then
  if [[ "$agent_net" == "host" ]]; then
    agent_exec+=("$agent_id" opencode --standalone)
  else
    agent_exec+=("$agent_id" opencode)
  fi
else
  agent_exec+=("$agent_id" "$agent_shell" -l)
fi

# --- set up the tmux session -----------------------------------------------

SESSION="agent-$(basename "$WORKSPACE_DIR")"

# Recreate the session fresh so re-running the script gives a clean workspace.
tmux kill-session -t "$SESSION" 2>/dev/null || true

# Run `docker exec` directly as each pane's command (no intermediate shell), so
# the pane exits when the container exits (or its process ends).
tmux new-session -d -s "$SESSION" -c "$WORKSPACE_DIR" -n dev "${agent_exec[@]}"

# The first pane is the agent; split for the terminal pane. Use pane IDs so we
# don't depend on pane-base-index being 0.
agent_pane="$(tmux list-panes -t "$SESSION" -F '#{pane_id}' | head -1)"
term_pane="$(tmux split-window -t "$agent_pane" -h -c "$WORKSPACE_DIR" -P -F '#{pane_id}' "${term_exec[@]}")"

# Tag each pane with its role (used by tmux-agent-layout) and a cosmetic title.
tmux set-option -p -t "$agent_pane" @agentwork-role opencode
tmux set-option -p -t "$term_pane" @agentwork-role terminal
tmux select-pane -t "$agent_pane" -T opencode
tmux select-pane -t "$term_pane" -T terminal

# The initial layout is applied by the client-attached hook below when the user
# attaches — there is no client to size against before then, and we deliberately
# avoid `stty`/`COLUMNS`/`LINES` (unreliable and tty-dependent).
if [[ -z "$LAYOUT_HELPER" ]]; then
  warn "tmux-agent-layout not found; layout will not auto-arrange"
fi

# (Re)install the resize/attach hooks using the resolved helper path, so the
# layout auto-switches even if the running tmux server predates the hooks in
# tmux.conf.local (or they were never reloaded).
if [[ -n "$LAYOUT_HELPER" ]]; then
  tmux set-hook -g client-attached "run-shell \"$LAYOUT_HELPER #{session_name}:#{window_index} #{client_width} #{client_height}\""
  tmux set-hook -g client-resized  "run-shell \"$LAYOUT_HELPER #{session_name}:#{window_index} #{client_width} #{client_height}\""
fi

info "terminal container:  $term_id  ($term_shell)"
info "opencode container:  $agent_id"

if [[ "$BACKGROUND" == "1" ]]; then
  ok "tmux session '$SESSION' ready in the background; attach with:"
  info "  tmux attach-session -t '$SESSION'"
  exit 0
fi

info "opening tmux session '$SESSION'..."
tmux attach-session -t "$SESSION"
