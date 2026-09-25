#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

python3 - "$ROOT" "$WORK" <<'PYEOF'
import importlib.machinery
import importlib.util
import os
import pathlib
import sys

root, work = map(pathlib.Path, sys.argv[1:])
path = root / "system_files/usr/libexec/armada/steam-client-affinity"
loader = importlib.machinery.SourceFileLoader("steam_client_affinity", str(path))
spec = importlib.util.spec_from_loader("steam_client_affinity", loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)

assert module.parse_cpulist("0-2,6,7") == {0, 1, 2, 6, 7}
for invalid in ("", "4-2", "-1"):
    try:
        module.parse_cpulist(invalid)
    except ValueError:
        pass
    else:
        raise AssertionError(f"accepted invalid cpulist {invalid!r}")

proc = work / "proc"


def fake_process(pid, name, uid, allowed, tids):
    base = proc / str(pid)
    (base / "task").mkdir(parents=True)
    (base / "status").write_text(
        f"Name:\t{name}\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n"
        f"Cpus_allowed_list:\t{allowed}\n",
        encoding="utf-8",
    )
    for tid in tids:
        (base / "task" / str(tid)).mkdir()


uid = os.getuid()
fake_process(100, "steamwebhelper", uid, "2-6", [100, 101, 102])
fake_process(200, "steamwebhelper", uid, "0-7", [200])
fake_process(300, "steamwebhelper", uid + 1, "2-6", [300])
fake_process(400, "game", uid, "2-6", [400])
calls = []
changed = module.normalize_once(proc, uid, set(range(8)), lambda tid, cpus: calls.append((tid, set(cpus))))
assert changed == [100], changed
assert calls == [(100, set(range(8))), (101, set(range(8))), (102, set(range(8)))], calls
PYEOF

# The launcher starts the watcher only when a device profile opts in.
steam_root="$WORK/Steam"
mkdir -p "$steam_root/steamrtarm64"
cat >"$steam_root/steamrtarm64/steam" <<'STUB'
#!/usr/bin/env bash
sleep 0.1
STUB
chmod 0755 "$steam_root/steamrtarm64/steam"

helper="$WORK/affinity-helper"
cat >"$helper" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$AFFINITY_LOG"
STUB
chmod 0755 "$helper"

launcher="$ROOT/system_files/usr/libexec/armada/launch-steam"
AFFINITY_LOG="$WORK/calls" STEAM_ROOT="$steam_root" \
    ARMADA_STEAM_AFFINITY_HELPER="$helper" ARMADA_STEAM_WEBHELPER_CORES= \
    "$launcher"
[[ ! -e "$WORK/calls" ]] || { echo "blank device policy started affinity helper" >&2; exit 1; }

AFFINITY_LOG="$WORK/calls" STEAM_ROOT="$steam_root" \
    ARMADA_STEAM_AFFINITY_HELPER="$helper" ARMADA_STEAM_WEBHELPER_CORES=0-5 \
    "$launcher"
grep -Eq '^[0-9]+ 0-5$' "$WORK/calls"

echo "steam affinity: exact process filter and device opt-in verified"
