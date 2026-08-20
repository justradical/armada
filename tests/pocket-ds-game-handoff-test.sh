#!/usr/bin/env bash

set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
SESSION_CONTROL="$ROOT/system_files/usr/libexec/armada/session-control"
SESSION_FILE="$ROOT/system_files/usr/share/gamescope-session-plus/sessions.d/steam"
DEVICE_ENV="$ROOT/system_files/usr/libexec/armada/device-env"
POCKET_DS_CONF="$ROOT/system_files/usr/lib/armada/devices/ayaneo-pocket-ds.conf"

require() {
    local needle="$1" file="$2" label="$3"
    if ! grep -Fq "$needle" "$file"; then
        printf 'missing %s: %s in %s\n' "$label" "$needle" "$file" >&2
        exit 1
    fi
}

forbid() {
    local needle="$1" file="$2" label="$3"
    if grep -Fq "$needle" "$file"; then
        printf 'forbidden %s: %s in %s\n' "$label" "$needle" "$file" >&2
        exit 1
    fi
}

# The Plasma -> Game Mode path must apply lower-screen policy before logout so
# gamescope gets a single visible primary panel and the lower digitizer cannot
# steer Steam during the handoff.
require 'eval "$(/usr/libexec/armada/device-env)"' "$SESSION_CONTROL" 'device-env in session-control'
require 'set_secondary_touchscreen 1' "$SESSION_CONTROL" 'pre-logout secondary touch inhibit'
require 'set_secondary_output disable' "$SESSION_CONTROL" 'pre-logout secondary output disable'
require 'kscreen-doctor "output.${ARMADA_SECONDARY_CONNECTOR}.${state}"' "$SESSION_CONTROL" 'secondary KScreen control'
require '/usr/libexec/armada/touchscreen-inhibit "${ARMADA_SECONDARY_TOUCHSCREEN}" "${inhibited}"' "$SESSION_CONTROL" 'secondary touch control'

# The gamescope Steam session lives in /usr/share on this branch; it must still
# import Armada device metadata and set the common launcher variables from it.
require 'eval "$(/usr/libexec/armada/device-env)"' "$SESSION_FILE" 'device-env in Steam session'
require 'OUTPUT_CONNECTOR="$ARMADA_PRIMARY_CONNECTOR"' "$SESSION_FILE" 'primary connector export'
require 'ORIENTATION="$ARMADA_PANEL_ORIENTATION"' "$SESSION_FILE" 'panel orientation export'
require 'SCREEN_WIDTH="$ARMADA_PANEL_NATIVE_WIDTH"' "$SESSION_FILE" 'native width export'
require 'SCREEN_HEIGHT="$ARMADA_PANEL_NATIVE_HEIGHT"' "$SESSION_FILE" 'native height export'
require 'CUSTOM_REFRESH_RATES="$ARMADA_PANEL_REFRESH_RATES"' "$SESSION_FILE" 'custom refresh export'
require 'sudo -n /usr/libexec/armada/touchscreen-inhibit "$ARMADA_SECONDARY_TOUCHSCREEN" 1' "$SESSION_FILE" 'gamescope lower touch inhibit'
forbid 'unset ARMADA_SECONDARY_CONNECTOR' "$SESSION_FILE" 'Game Mode lease suppression'
forbid 'ARMADA_GAMESCOPE_DISABLE_LEASE=1' "$POCKET_DS_CONF" 'Pocket DS lease disable default'
require 'ARMADA_SECONDARY_CONNECTOR=DSI-2' "$POCKET_DS_CONF" 'Pocket DS lease connector retained'
require 'sudo -n /usr/libexec/armada/touchscreen-inhibit "$ARMADA_SECONDARY_TOUCHSCREEN" 0' "$ROOT/system_files/usr/libexec/armada/desktop-bootstrap" 'desktop lower touch re-enable'
require '%wheel ALL=(ALL) NOPASSWD: /usr/libexec/armada/touchscreen-inhibit *' "$ROOT/build_files/50-create-user.sh" 'touchscreen inhibit sudoers rule'
require '_armada_tweaks_config=' "$SESSION_FILE" 'gamescope realtime tweak block'

# Device metadata must still be emitted by device-env, otherwise the restored
# session assignments above silently become no-ops.
for var in \
    ARMADA_PANEL_NATIVE_WIDTH \
    ARMADA_PANEL_NATIVE_HEIGHT \
    ARMADA_PANEL_REFRESH_RATES \
    ARMADA_GAMESCOPE_FORCE_COMPOSITION_ROTATION \
    ARMADA_GAMESCOPE_FAKE_OUTPUT_MM \
    ARMADA_HDR_CAPABLE; do
    require "$var" "$DEVICE_ENV" "device-env $var"
done

require 'ARMADA_PANEL_NATIVE_WIDTH=1080' "$POCKET_DS_CONF" 'Pocket DS native width'
require 'ARMADA_PANEL_NATIVE_HEIGHT=1920' "$POCKET_DS_CONF" 'Pocket DS native height'
require 'ARMADA_PANEL_REFRESH_RATES=60,120' "$POCKET_DS_CONF" 'Pocket DS refresh rates'

printf 'Pocket DS game handoff policy test passed\n'
