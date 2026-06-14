#!/usr/bin/env bash
# vim: set ft=sh ts=2 sw=2 et:

set -uo pipefail

DEBUG="${DEBUG:-0}"
log() { [ "$DEBUG" -eq 1 ] && echo "[DEBUG] $*"; }

# ---------- Colors ----------
RED="$(printf '\033[1;31m')"
GREEN="$(printf '\033[1;32m')"
YELLOW="$(printf '\033[1;33m')"
BLUE="$(printf '\033[1;34m')"
CYAN="$(printf '\033[1;36m')"
BOLD="$(printf '\033[1m')"
RESET="$(printf '\033[0m')"

# ---------- Keypress ----------
if [ -n "${ZSH_VERSION:-}" ]; then
  read_key() { read -r -k 1 </dev/tty; }
else
  read_key() { read -r -n 1 </dev/tty; }
fi

# ---------- Spinner ----------
spinner() {
  local pid="$1"
  local prefix="$2"
  local spin='|/-\'

  while kill -0 "$pid" 2>/dev/null; do
    for i in 0 1 2 3; do
      printf "\r%-100s\r%s [%c]" "" "$prefix" "${spin:$i:1}"
      sleep 0.1
    done
  done
}

# ---------- Changelog parsing ----------
is_header() {
  printf '%s\n' "$1" | grep -Eq \
    '^[^[:space:]]+[[:space:]]+\([^)]*\)[[:space:]]+[^;]+;'
}

header_pkg() {
  printf '%s\n' "$1" | awk '{print $1}'
}

header_version() {
  local line="$1"
  local v="${line#*(}"
  printf '%s\n' "${v%%)*}"
}

# ---------- Process changelog ----------
process_one() {
  local installed="$1"
  local file="$2"

  local printing=0
  local seen_pkg=""

  while IFS= read -r line; do
    if is_header "$line"; then
      hdr_pkg=$(header_pkg "$line")
      hdr_ver=$(header_version "$line")

      if [ -n "$seen_pkg" ] && [ "$hdr_pkg" != "$seen_pkg" ]; then
        printf "%s\n" "${BOLD}${YELLOW}== Renamed package: $seen_pkg → $hdr_pkg ==${RESET}"
        break
      fi

      seen_pkg="$hdr_pkg"
      printing=1

      if dpkg --compare-versions "$hdr_ver" le "$installed"; then
        break
      fi
    fi

    if [ "$printing" -eq 1 ]; then
      case "$line" in
        *CVE-*|*security*|*Security*)
          printf "%s%s%s\n" "$RED" "$line" "$RESET"
          ;;
        *fix*|*Fix*|*bug*|*Bug*)
          printf "%s%s%s\n" "$YELLOW" "$line" "$RESET"
          ;;
        *)
          printf "%s\n" "$line"
          ;;
      esac
    fi
  done < "$file"
}

# ---------- Main ----------
echo "${BOLD}==> Simulating upgrade...${RESET}"
echo

mapfile -t pkgs < <(
  (apt-get -s full-upgrade 2>/dev/null || true) \
  | awk '/^Inst / {print $2}'
)

echo "${BOLD}==> Found ${#pkgs[@]} packages${RESET}"
echo
echo "${BOLD}==> Fetching changelogs (serial, apt-safe)...${RESET}"
echo

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# ---------- SERIAL FETCH ----------
for pkg in "${pkgs[@]}"; do
  outfile="$tmpdir/$pkg"

  prefix=$(printf "%sFetching %s%s" \
    "$CYAN" "$pkg" "$RESET")

  apt-get changelog "$pkg" > "$outfile" 2>/dev/null &
  pid=$!

  spinner "$pid" "$prefix"

  if ! wait "$pid"; then
    log "Failed to fetch changelog for $pkg"
    : > "$outfile"
  fi

  printf "\r%-100s\r%s ${GREEN}done${RESET}\n" "" "$prefix"
done

echo
echo "${GREEN}Done fetching changelogs${RESET}"
echo

# ---------- DISPLAY ----------
for pkg in "${pkgs[@]}"; do
  installed=$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null || echo "none")
  candidate=$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2}')

  [ -z "$candidate" ] || [ "$installed" = "$candidate" ] && continue

  printf "%s%s%s  %s→%s\n" \
    "$CYAN" "$pkg" "$RESET" \
    "$YELLOW$installed$RESET" "$GREEN$candidate$RESET"

  echo "${BLUE}--------------------------------------------------${RESET}"

  file="$tmpdir/$pkg"

  if [ ! -s "$file" ]; then
    echo "${RED}(No changelog available)${RESET}"
    echo
    continue
  fi

  process_one "$installed" "$file"

  echo
  printf "%sPress any key to continue...%s" "$BOLD" "$RESET"
  read_key
  echo
  echo
done

