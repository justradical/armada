#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH="$ROOT/packages/kernel/patches/0505-arm64-emulate-unaligned-atomics.patch"

python3 - "$PATCH" <<'PY'
import pathlib
import re
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
match = re.search(
    r"static struct fault_info Load128\(.*?\n\+}\n",
    text,
    flags=re.DOTALL,
)
assert match, "Load128 is missing from the unaligned-atomic patch"
body = match.group(0)

# Load128 uses a store-exclusive to complete its atomic 128-bit read. Both
# memory instructions can fault on a user mapping, so each needs a uaccess
# exception-table entry; otherwise a read-only mapping causes a kernel Oops.
assert '3: stlxp %w[Tmp]' in body, "Load128 stlxp has no fault label"
assert '_ASM_EXTABLE_UACCESS_ERR(1b, 2b, %w[ret])' in body
assert '_ASM_EXTABLE_UACCESS_ERR(3b, 2b, %w[ret])' in body
print("kernel unaligned atomic: Load128 load/store faults are recoverable")
PY
