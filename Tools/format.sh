#!/usr/bin/env bash
# Formatting, via the `swift format` that ships with the toolchain — no extra
# tool to install, and it reads .swift-format at the repository root.
#
#   ./Tools/format.sh          what is not formatted (exits non-zero if any)
#   ./Tools/format.sh --write  reformat in place
#
# Note before you run --write: the repository is NOT formatted yet. The config
# is calibrated to the existing style (4 spaces, 120 columns) but the
# pretty-printer still wants to rewrite about 1,500 lines of layout, and one of
# the things it rewrites is the indentation of embedded JavaScript in
# BrowserKit/BrowserScripts.swift and of the prompt text in
# AgentKit/AgentCommand.swift. Reformatting is worth doing — as its own commit,
# reviewed on its own, with the self-tests run afterwards. Mixing it into a
# change that also moves code makes both unreviewable.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ "${1:-}" = "--write" ]; then
  swift format --recursive --parallel --in-place Packages Apps
  echo "formatted"
else
  if swift format lint --recursive --parallel Packages Apps 2>&1 | grep -q 'warning:'; then
    swift format lint --recursive --parallel Packages Apps 2>&1 | head -40
    echo
    echo "not formatted. ./Tools/format.sh --write — but read the note at the top first."
    exit 1
  fi
  echo "formatted"
fi
