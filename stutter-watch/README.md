# stutter-watch

A low-overhead, seven-day recorder for correlating intermittent desktop stutter with CPU, memory/zram, storage, thermal, GPU, compositor, power-policy, service, and wallpaper activity. It uses Python's standard library plus read-only system tools.

Notes about a specific host's investigation (hardware baseline, findings, what was changed) go in `~/.local/state/stutter-watch/NOTES.md`, not here. `stutter-watch bundle` includes that file.

## Install / uninstall

Not installed by the main dotfiles `install.sh`. Run from this directory:

```sh
./install.sh            # script, user service, MangoHud profile, GeForce NOW wiring
./install.sh --system   # also the /usr/local/bin/game-performance wrapper (sudo)
./uninstall.sh          # removes all of the above; recorded data is kept
```

`install.sh` also writes the Hyprland binds below to `~/.config/hypr/stutter_watch.lua` and loads it from `hyprland.lua`; `uninstall.sh` removes both.

## Start / check / mark / stop

The user service is enabled to start at login and resume the same seven-day capture after a reboot or service restart.

```sh
systemctl --user status stutter-watch.service
stutter-watch status
stutter-watch mark "brief freeze while scrolling in browser"
systemctl --user stop stutter-watch.service
stutter-watch bundle
```

`mark` is especially useful: record a mark as soon as a stutter is noticed, optionally with a short, non-sensitive note. The timestamp lets a later analysis compare the event with samples immediately before and after it. Stopping the service pauses the session; starting it again resumes. After seven days it completes and exits. Start another capture with `stutter-watch new-session`.

After the session is complete (or stopped), `stutter-watch bundle` creates a compressed `.tar.gz` beside the session directory for sharing with an analysis tool. It refuses to bundle while recording so the archive is consistent.

## Data

The current capture is under:

```text
~/.local/state/stutter-watch/sessions/<session-id>/
```

- `inventory.json`: host/kernel, CPU, block devices/mounts, running and failed services, selected package versions, Variety settings, initial Btrfs reports, and available telemetry tools.
- `samples.jsonl`: one compact JSON object every five seconds. Rates are deltas between samples; counters are cumulative where named `*_counters`.
- `events.jsonl`: user marks, boots/restarts, selected kernel warnings, changes to power/scheduler policy, running/failed services, Hyprland monitor configuration, wallpaper changes, and periodic Btrfs usage snapshots.
- `manifest.json`: capture times, deadline, status, schema context, and privacy summary.

Most `*_bytes` fields are bytes; `cpu_frequency_khz` is kHz; `sensors_raw` preserves hwmon units (temperature in millidegrees Celsius, fan speed in RPM, power in microwatts); GPU engine values are percentages. CPU and disk rates are interval deltas. The first sample after a start/reboot has no valid interval delta and may have empty rate fields.

The recorder samples `/proc` CPU/memory/VM/process/disk data, PSI, zram, cpufreq/intel_pstate, RAPL energy, thermal/hwmon sensors, NVMe sysfs health/temperature fields, battery state, Btrfs device counters/free-space reports, power-profiles-daemon and sched-ext state, kernel VM/THP tunables, system and user timers, and Hyprland monitor state. It samples Intel Xe GPU activity using `gputop` every 15 seconds (`intel_gpu_top` doesn't support Xe). Variety's one-hour change interval, wallpaper target metadata, and relevant appended Variety log lines are recorded. Hyprland does not provide direct per-frame presentation timestamps through the queried interface, so this is correlation telemetry rather than a frame-time profiler; use `stutter-watch mark` when you feel a hitch.

Sampling runs as the user, not root. Full NVMe SMART/NVMe error-log data is therefore not queried: `/dev/nvme*` is normally root-only. Readable sysfs counters and temperatures are still captured. Kernel journal messages are included only if the current user has permission to read them; the recorder records a single `sensor_unavailable` event otherwise.

No process command-line arguments, document contents, or network payloads are recorded. Process name/PID, cgroup leaf (usually a systemd unit), CPU, RSS, and read/write rates are recorded to identify responsible workloads. Wallpaper paths are reduced to basenames. Logs are mode 0600 by default; samples are buffered and synced about once per minute to limit filesystem write pressure. The sample log has a 2 GiB safety limit.

## Hotkeys and diagnostics

Hotkeys (in `~/.config/hypr/stutter_watch.lua`):

- **Super+Shift+M** → `stutter-watch mark`. Records the keypress time plus a diagnostic snapshot: memory fragmentation (`/proc/buddyinfo`), meminfo, PSI, Hyprland/noctalia/Xwayland/hyprpaper CPU over 1 s plus RSS and **swap**, top processes over 1 s, window/workspace counts, active window class (no titles), blur state, and whether a game is running. A desktop notification confirms it.
- **Super+Shift+B** → `stutter-watch probe`. Turns Hyprland blur off for 2 minutes, then restores it (press again to cancel early). Marks made during a probe show whether the stutter persists without blur. If the probe process dies, the recorder restores blur within about 3 minutes; a Hyprland config reload also restores it.

Per-sample fields for this: `buddyinfo` (free blocks per order; `normal_free_mib_order_ge_9` = free memory in ≥2 MiB contiguous blocks), `desktop_procs` (CPU, RSS, and swap of the desktop stack), `hyprland_layout` (window and workspace counts, refreshed every 15 s), `game_active`, and more vmstat counters (compaction success, THP fallback, allocation stalls, workingset refaults). Events: `game_started`, `game_ended`, `probe_started`, `probe_ended`, and `user_mark.diagnostics`.

Game detection uses a shared flock on `$XDG_RUNTIME_DIR/game-active.lock`, held by `/usr/local/bin/game-performance` (installed by `install.sh --system`).

## Live stutter detector

The recorder runs a detector alongside the 5-second sampler:

- **Kernel stall alerts (PSI triggers, ~2 s latency)** on Hyprland's service cgroup (compositor, noctalia, Xwayland, hyprpaper), on Steam's cgroup (where Steam games run), and system-wide memory. Each alert becomes a `stall_episode` event.
- **Game frame times.** The wrapper runs games under MangoHud with `~/.config/MangoHud/stutter-watch.conf`: a small top-left HUD (FPS, 1% low, frame-time graph, CPU/GPU, RAM, swap), toggled with Shift_R+F12. It also writes a per-frame log to `~/.local/state/stutter-watch/frametimes/`, kept for 14 days. The detector reads the log live. A frame counts as a hitch if it takes at least 25 ms and at least twice the recent median. Hitches less than 3 s apart form one episode. An episode is reported as a `stutter_detected` event if it has at least 4 hitches or one frame of at least 100 ms. The first 20 s of each log are ignored.

When it asks:

- **Desktop:** right away, as "Possible stutter just now?" with buttons Yes, stuttered / No / Not sure. At most once every 15 minutes; the notification expires after 45 s.
- **Games:** never while you play. After the game exits (sessions of at least 2 minutes), a notification offers Review / Later / Skip, then steps through the 5 worst detections one at a time, and finally asks "Anything we missed?". "Later" keeps them for `stutter-watch review`. If MangoHud wasn't used, the game's own stall alerts are reviewed instead.

Answers are logged as `stutter_confirmation` events (linked to the detection `id`). `stutter-watch prompts off|on` turns the pop-ups off or on; detections are logged either way. Thresholds are at the top of the script (`PSI_*`, `HITCH_*`, `EPISODE_*`). Tune them against the confirmations.

Opt a game out of MangoHud: `STUTTER_WATCH_MANGOHUD=0 game-performance %command%`. Games whose launch options already use MangoHud keep their own setup. For gamescope launches, MangoHud is inserted after `--`, so it measures the game rather than gamescope.

## GeForce NOW

If the `com.nvidia.geforcenow` user Flatpak is installed, `install.sh` wires it up the same way as Steam games:

- **Performance profile, idle inhibit, game-active lock:** the menu entry `~/.local/share/applications/com.nvidia.geforcenow.desktop` is changed to run `env STUTTER_WATCH_MANGOHUD=0 game-performance "<NVIDIA launcher>"`, with the original saved as `~/.local/state/stutter-watch/com.nvidia.geforcenow.desktop.orig`. The launcher script itself is left alone, because it overwrites itself when it updates.
- **MangoHud:** `flatpak override --user com.nvidia.geforcenow --env=MANGOHUD=1 --env=MANGOHUD_CONFIGFILE=~/.config/MangoHud/stutter-watch.conf`, which applies however GFN is launched. This needs the `org.freedesktop.Platform.VulkanLayer.MangoHud` branch that matches GFN's runtime (`flatpak info com.nvidia.geforcenow`).
- **Frame logs:** the Flatpak keeps a private `~/.local/state`, so its logs land in `~/.var/app/com.nvidia.geforcenow/.local/state/stutter-watch/frametimes/`. The detector watches that folder too (`FRAME_DIRS`).
- In GFN, a "stutter" can also be network jitter or dropped frames from the stream. To tell them apart, compare detections against GFN's `geronimo.log` under `~/.var/app/com.nvidia.geforcenow/.local/state/NVIDIA/GeForceNOW/`.
