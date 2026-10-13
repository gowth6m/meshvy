#!/usr/bin/env bash
# Rebuilds every screenshot in Docs/ against a demo board.
#
# The shots used to be taken against whatever happened to be on the author's
# own machine, which meant client repositories in a public README and a hero
# that could not be reproduced. This builds the board instead: three throwaway
# repositories from Docs/demo/, one workspace cut across them, a dev server for
# the web one, and a real orchestrator run that delegates to an agent in each.
#
#   ./Scripts/make-shots.sh                  # all of them
#   ./Scripts/make-shots.sh board changes    # board · changes · browser ·
#                                            # palette · empty
#
# Everything it creates it removes again: the worktrees, the scratch repos and
# its own entry in your board. Your own workspaces are left alone.
#
# It drives the real `claude` CLI, so the agents cost what the agents cost.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Meshvy.app/Contents/MacOS/Meshvy"
SCRATCH="${SCRATCH:-${TMPDIR:-/tmp}/meshvy-shots}"
SUPPORT="$HOME/Library/Application Support/Meshvy"
NAME="Payments revamp"
BRANCH="payments-revamp"
WORKSPACE="$HOME/.meshvy/$BRANCH"
PORT="${PORT:-5173}"
REPOS=(api web worker)

# No arguments means all of them.
shots=("$@")
wanted() {
  [ ${#shots[@]} -eq 0 ] && return 0
  for shot in "${shots[@]}"; do [ "$shot" = "$1" ] && return 0; done
  return 1
}

[ -x "$APP" ] || { echo "build it first: ./Scripts/build-app.sh" >&2; exit 1; }

# ---------------------------------------------------------------- the demo

echo "==> demo repositories in $SCRATCH"
rm -rf "$SCRATCH"
mkdir -p "$SCRATCH"
for repo in "${REPOS[@]}"; do
  cp -R "$ROOT/Docs/demo/$repo" "$SCRATCH/$repo"
  git -C "$SCRATCH/$repo" init -q -b main
  git -C "$SCRATCH/$repo" add -A
  git -C "$SCRATCH/$repo" -c user.name="Meshvy" -c user.email="shots@meshvy.local" \
      commit -qm "feat: the $repo"
done

echo "==> backing up the board"
mkdir -p "$SUPPORT"
cp "$SUPPORT/workspaces.json" "$SCRATCH/workspaces.backup.json" 2>/dev/null || true
cp "$SUPPORT/layout.json" "$SCRATCH/layout.backup.json" 2>/dev/null || true

cleanup() {
  echo "==> putting it all back"
  [ -n "${SERVER:-}" ] && kill "$SERVER" 2>/dev/null || true
  for repo in "${REPOS[@]}"; do
    git -C "$SCRATCH/$repo" worktree remove --force "$WORKSPACE/$repo" 2>/dev/null || true
  done
  rm -rf "$WORKSPACE"
  cp "$SCRATCH/workspaces.backup.json" "$SUPPORT/workspaces.json" 2>/dev/null || true
  cp "$SCRATCH/layout.backup.json" "$SUPPORT/layout.json" 2>/dev/null || true
  rm -rf "$SCRATCH"
}
trap cleanup EXIT

# Transcripts this script's own agents left behind last time. Without this the
# board shows a sub-agent card per run, all of them for the same task.
rm -rf "$HOME/.claude/projects/"*"-meshvy-$BRANCH"*

echo "==> workspace"
"$APP" --selftest "${REPOS[@]/#/$SCRATCH/}" --keep --name "$NAME" --branch "$BRANCH" >/dev/null

echo "==> dev server on :$PORT"
(cd "$WORKSPACE/web/public" && exec python3 -m http.server "$PORT") >/dev/null 2>&1 &
SERVER=$!
sleep 1

# ---------------------------------------------------------------- the shots

DELEGATE="Delegate this straight away, no investigation of your own: spawn an \
agent on api to add the missing GET /v1/refunds route in the style of \
charges.js, and one on web to add a Refunds panel to public/index.html in the \
existing style. Neither should start a server or open a browser. Then wait for \
both and summarise what changed."

READ_CONSOLE="Look at the dashboard on the board with the browser tools: read \
its console and tell me in one line what is still failing. Change no files."

# The hero is taken during the delegated run — three terminals in flight and
# the app they are changing is the thing worth a picture — and the changes shot
# reads what that run left in the checkouts, so it has to happen either way.
# `--tidy` because an agent lands in whatever gap it finds, and the board has to
# frame the same way every time this is run.
if wanted board || wanted changes; then
  echo "==> the delegated run"
  "$APP" --snapshot "$SCRATCH/board.png" --browser "localhost:$PORT" \
         --width 2400 --height 1140 --tidy --orchestrator "$DELEGATE"
  # Rendered at 2x for the type, then halved again for the repository.
  wanted board && sips -Z 3200 "$SCRATCH/board.png" --out "$ROOT/Docs/board.png" >/dev/null
fi

if wanted changes; then
  echo "==> Docs/changes.png"
  "$APP" --snapshot "$ROOT/Docs/changes.png" --width 1700 --height 1020 \
         --select repo --zoom 0.8
fi

if wanted browser; then
  echo "==> Docs/browser.png"
  "$APP" --snapshot "$ROOT/Docs/browser.png" --browser "localhost:$PORT" \
         --width 1800 --height 920 --select browser --zoom 0.78 --tidy \
         --orchestrator "$READ_CONSOLE"
fi

if wanted palette; then
  echo "==> Docs/palette.png"
  "$APP" --snapshot "$ROOT/Docs/palette.png" --width 1700 --height 1020 \
         --palette --zoom 0.8
fi

# No workspace at all, so the board has to be out of the way for this one.
if wanted empty; then
  echo "==> Docs/empty.png"
  echo '{"version":1,"workspaces":[]}' > "$SUPPORT/workspaces.json"
  "$APP" --snapshot "$ROOT/Docs/empty.png" --width 1500 --height 940
fi

echo "==> done"
