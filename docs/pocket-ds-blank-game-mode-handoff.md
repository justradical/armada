# Pocket DS blank screen after Desktop -> Game Mode handoff

## Problem statement

On AYANEO Pocket DS running the `ghcr.io/justradical/armada:gamescope-changes` image, switching from the Desktop/Plasma GUI back to Game Mode can leave the device with no visible display output.

The reported user-visible symptom is: after initiating the Desktop -> Game Mode switch, the Pocket DS screen shows nothing. In the failing state observed during this triage, remote access was temporarily unavailable, so live post-failure DRM state could not be captured until the device was physically recovered.

## Image / branch under test

The device had previously been rebased to:

```text
ostree-unverified-registry:ghcr.io/justradical/armada:gamescope-changes
Digest:  sha256:e73376d0c401c5dbeb6b61e5083f0be0855dc26bfcfc7db1f779aee41fdd026d
Version: 20260820.e6c2ae0
```

The source branch inspected for this triage is:

```text
justradical/gamescope-changes @ e6c2ae0
```

## Remote access / live-debug status

Remote access was unavailable while the device was in the initial black-screen state. After physical recovery, live status could be collected again. With the companion gamescope lease-plane fix applied, the Desktop -> Game Mode handoff was validated with `--lease-connector DSI-2` still enabled.

## Relevant pre-failure journal evidence

A prior `journalctl --user -xu gamescope-session-plus@steam.service` delta, captured after the `gamescope-changes` rebase, shows the Steam gamescope service being stopped and restarted:

```text
Aug 20 11:48:04 ... Stopping gamescope-session-plus@steam.service
Aug 20 11:48:04 ... Killing process ... gamescope-wl ... Xwayland ... steam ...
Aug 20 11:48:04 ... Stopped gamescope-session-plus@steam.service
Aug 20 11:49:43 ... Started gamescope-session-plus@steam.service
```

The restarted gamescope instance selected the expected primary panel and leased the lower panel:

```text
drm:   DSI-2 (connected)
drm:   DSI-1 (connected)
drm: lease-connector: main connector 'DSI-1' prefers CRTC 109
drm: lease-connector: selected shared primary plane 49 for CRTC 110
drm: lease-connector: leased 'DSI-2' (connector=39, crtc=110, plane=49) -> fd=28, lessee=1
drm: selecting connector DSI-1
drm: selecting mode 1080x1920@120Hz
wlserver: touch device 'bottom_touchscreen' matches --ignore-touch-device 'bottom_touchscreen'
```

This confirms the gamescope side can start on `DSI-1` with `DSI-2` leased when the handoff succeeds.

## Branch differences that matter

`justradical/gamescope-changes` switched to installing a packaged `gamescope-session-steam` and moved the Steam session snippet from:

```text
system_files/etc/gamescope-session-plus/sessions.d/steam
```

to:

```text
system_files/usr/share/gamescope-session-plus/sessions.d/steam
```

During that move, Armada-specific session policy was dropped from the new `/usr/share` session snippet:

- `eval "$(/usr/libexec/armada/device-env)"`
- `OUTPUT_CONNECTOR="$ARMADA_PRIMARY_CONNECTOR"`
- `ORIENTATION="$ARMADA_PANEL_ORIENTATION"`
- `SCREEN_WIDTH` / `SCREEN_HEIGHT`
- `CUSTOM_REFRESH_RATES` / `STEAM_DISPLAY_REFRESH_LIMITS`
- lower touchscreen inhibit at gamescope startup
- `ARMADA_TWEAKS_CONFIG` -> `GAMESCOPE_FORCE_VULKAN_REALTIME`
- HDR capability exports gated by `ARMADA_HDR_CAPABLE`

The same branch also lacks the safer Desktop -> Game Mode handoff policy in `session-control` that existed in the Pocket DS dual-screen work: before logging Plasma out, it should inhibit the lower touch device and disable the secondary KScreen output.

## Root-cause hypothesis

Most likely cause: the `gamescope-changes` branch rebased the Steam session and game-mode handoff path over the Pocket DS dual-screen policy, leaving the transition dependent on whatever DRM/KScreen state Plasma left behind.

For Pocket DS, this is unsafe because Desktop Mode deliberately enables and lays out both panels, while Game Mode expects a single visible primary panel (`DSI-1`) plus an optional `DSI-2` DRM lease. If the Game Mode handoff does not explicitly clean up the Desktop lower-output state before Plasma exits and does not re-import Armada device metadata in the Steam session, gamescope can start with stale or generic display policy after the transition. The visible symptom can be a dark/blank panel even though the service starts.

The current unreachable SSH state may be a separate power/network side effect, but the branch-level display regression is clear and testable without the device.

## Proposed solution

Carry the Pocket DS display contract forward into `gamescope-changes`:

1. Restore Armada device-env import in the `/usr/share/gamescope-session-plus/sessions.d/steam` session snippet.
2. Derive `OUTPUT_CONNECTOR`, `ORIENTATION`, native size, refresh rates, rotation shader, fake-output-mm, HDR, and gamescope realtime variables from device-env in that session snippet.
3. Keep `ARMADA_SECONDARY_CONNECTOR=DSI-2` active for Game Mode so `gamescope-session-plus` continues to pass `--lease-connector DSI-2`. The black screen is addressed in gamescope itself by detaching the stale fbcon plane before creating the DRM lease, rather than by suppressing the lease from Armada.
4. Re-inhibit the secondary touchscreen at gamescope startup with `sudo -n /usr/libexec/armada/touchscreen-inhibit "$ARMADA_SECONDARY_TOUCHSCREEN" 1`.
5. Add a narrow NOPASSWD sudoers rule for `touchscreen-inhibit`, because the Steam and desktop session snippets run as user `armada` but `/sys/class/input/*/inhibited` is root-owned.
6. Re-enable the secondary touchscreen from `desktop-bootstrap` through that same `sudo -n` path.
7. Restore pre-logout Game Mode policy in `session-control`:
   - inhibit `ARMADA_SECONDARY_TOUCHSCREEN`,
   - disable `ARMADA_SECONDARY_CONNECTOR` through `kscreen-doctor`,
   - then log Plasma out / restart SDDM.
8. Re-export the legacy display variables from `device-env` and restore Pocket DS native dimensions/refresh rates so session assignments are not no-ops.

## Verification added

A new focused regression test was added:

```bash
bash tests/pocket-ds-game-handoff-test.sh
```

It fails on `justradical/gamescope-changes @ e6c2ae0` before the patch because `session-control` lacks `device-env` import and the handoff cleanup calls.

After the patch it passes and asserts:

- `session-control` imports device-env,
- Game Mode handoff calls `set_secondary_touchscreen 1`,
- Game Mode handoff calls `set_secondary_output disable`,
- the Steam session imports device-env,
- the Steam session exports primary connector/orientation/native modes,
- the Steam session inhibits lower touch,
- the Steam session keeps `ARMADA_SECONDARY_CONNECTOR` intact so `--lease-connector DSI-2` is still emitted,
- desktop bootstrap re-enables lower touch through the same sudo path,
- the image grants a narrow NOPASSWD rule for `touchscreen-inhibit`,
- `device-env` still emits the display variables,
- Pocket DS profile declares `1080x1920` and `60,120`.

Existing tests that specifically covered the moved Steam session policy also improved:

```bash
bash tests/odin3-hdr-session-test.sh
# passed
```

```bash
bash tests/perf-settings-test.sh
# progressed past the previously failing session realtime block; then failed on
# the local validation host because the test expects Pocket DS/SM8550 CPUs 4-7
# but that host exposes fewer CPUs. That later failure is an existing
# host-topology limitation, not a failure of this patch's Steam-session
# restoration.
```

Syntax/static checks:

```bash
bash -n system_files/usr/share/gamescope-session-plus/sessions.d/steam \
       system_files/usr/libexec/armada/session-control \
       system_files/usr/libexec/armada/device-env

git diff --check
```

Both passed.

## Verified Desktop -> Game Mode state with patched gamescope

With the companion gamescope fix installed as a transient live overlay, a full Game Mode -> Desktop -> Game Mode switch was validated while preserving the DRM lease path:

```text
gamescope ... --lease-connector DSI-2 --ignore-touch-device bottom_touchscreen --prefer-output DSI-1
fb0.blank=0
DSI-1 enabled / DPMS On
DSI-2 enabled / DPMS On
lease-connector: detached plane 49 from CRTC 109 before lease
lease-connector: leased 'DSI-2'
```

Physical validation confirmed the primary screen remained live after the switch. DRM debug state showed the stale fbcon plane was detached before leasing:

```text
plane[49]: crtc=(null), fb=0
plane[67]: crtc=crtc-0, allocated by gamescope-xwm
```

This means the Armada branch preserves the original dual-screen/lease contract: `ARMADA_SECONDARY_CONNECTOR=DSI-2` remains available for the future companion/dual-screen gamescope session, and the black-screen fix belongs in gamescope's lease setup rather than in Armada suppressing the lease argument.

## Next live validation when device is reachable

After physical recovery / reboot, verify the live state with the equivalent of:

```bash
for d in /sys/class/drm/card*-DSI-*; do
  printf "%s status=%s enabled=%s dpms=%s\n" \
    "$(basename "$d")" "$(cat "$d/status")" \
    "$(cat "$d/enabled" 2>/dev/null || echo na)" \
    "$(cat "$d/dpms" 2>/dev/null || echo na)"
done

XDG_RUNTIME_DIR=/run/user/1000 systemctl --user status \
  gamescope-session-plus@steam --no-pager -l
```

Then reproduce Desktop -> Game Mode and confirm:

- `DSI-1` is enabled/DPMS On in Game Mode,
- `DSI-2` is disabled or leased as intended, but not a stale Plasma output,
- `bottom_touchscreen` is inhibited,
- gamescope command includes the primary connector/orientation/native refresh policy,
- Steam is visible on the top panel.
