#!/usr/bin/env bash
# Offline drift and dispatch checks, with private adapters and checkouts.
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
python3 "$ROOT/tests/input-lock.py"
