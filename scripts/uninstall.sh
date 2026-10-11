#!/usr/bin/env bash
# Removes Meshvy and everything it created.
#
#   ./scripts/uninstall.sh              ask first, keep anything unsaved
#   ./scripts/uninstall.sh --dry-run    say what would go, change nothing
#   ./scripts/uninstall.sh --keep-worktrees
#   ./scripts/uninstall.sh --force      also remove checkouts with unsaved work
#   ./scripts/uninstall.sh --yes        skip the confirmation
#
# The careful part is ~/.meshvy. Those are not ordinary folders: each one is a
# git worktree registered inside your real repository. Deleting them with rm
# would leave every source repo pointing at a checkout that no longer exists,
# so each is handed back with `git worktree remove` and the origin pruned. A
# checkout holding uncommitted or unpushed work is left alone unless you pass
# --force.
set -euo pipefail

APP_SUPPORT="$HOME/Library/Application Support/Meshvy"
ROOT="$HOME/.meshvy"
WORKSPACES="$APP_SUPPORT/workspaces.json"
KEYCHAIN_SERVICE="dev.gowtham.meshvy"

DRY=0; FORCE=0; KEEP_WORKTREES=0; ASSUME_YES=0; DEV_BUILD=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --force) FORCE=1 ;;
    --keep-worktrees) KEEP_WORKTREES=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "uninstall: unknown option $arg" >&2; exit 2 ;;
  esac
done

say()  { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
run()  { if [ "$DRY" = "1" ]; then printf '    would: %s\n' "$*"; else eval "$@"; fi; }

KEPT=0

# --- 1. Locate the app -------------------------------------------------------
APP=""
for candidate in "/Applications/Meshvy.app" "$HOME/Applications/Meshvy.app"; do
  [ -d "$candidate" ] && APP="$candidate" && break
done
if [ -z "$APP" ]; then
  FOUND="$(mdfind "kMDItemCFBundleIdentifier == 'dev.gowtham.meshvy'" 2>/dev/null | head -1 || true)"
  # Spotlight also finds build output sitting in a checkout. Deleting someone's
  # dist/ from under them is not what "uninstall the app" means.
  if [ -n "$FOUND" ] && git -C "$(dirname "$FOUND")" rev-parse --git-dir >/dev/null 2>&1; then
    DEV_BUILD="$FOUND"
  elif [ -n "$FOUND" ]; then
    APP="$FOUND"
  fi
fi

# --- 2. Show the plan --------------------------------------------------------
say "Meshvy uninstall"
[ -n "$APP" ] && note "app:              $APP" || note "app:              not found"
[ -n "${DEV_BUILD:-}" ] && note "dev build:        ${DEV_BUILD} (left alone)"
[ -d "$APP_SUPPORT" ] && note "settings:         $APP_SUPPORT" || note "settings:         none"
[ -d "$ROOT" ] && note "workspaces:       $ROOT" || note "workspaces:       none"
note "keychain:         $KEYCHAIN_SERVICE (API key, if you saved one)"
echo

if [ "$DRY" = "0" ] && [ "$ASSUME_YES" = "0" ]; then
  printf 'Remove these? Checkouts with unsaved work are kept. [y/N] '
  read -r reply </dev/tty || reply=""
  case "$reply" in [yY]*) ;; *) echo "nothing removed."; exit 0 ;; esac
fi

# --- 3. Stop anything running ------------------------------------------------
if pgrep -f "Meshvy.app/Contents/MacOS/Meshvy" >/dev/null 2>&1; then
  say "quitting Meshvy"
  run "osascript -e 'quit app \"Meshvy\"' >/dev/null 2>&1 || true"
  for _ in $(seq 1 40); do
    pgrep -f "Meshvy.app/Contents/MacOS/Meshvy" >/dev/null 2>&1 || break
    sleep 0.25
  done
fi

# Agents Meshvy started live under the workspace root; close them so nothing
# is writing while the checkouts are handed back.
if [ -d "$ROOT" ] && pgrep -f "$ROOT" >/dev/null 2>&1; then
  say "closing agents still running in workspaces"
  run "pkill -f '$ROOT' 2>/dev/null || true"
  sleep 1
fi

# --- 4. Hand the worktrees back ---------------------------------------------
if [ "$KEEP_WORKTREES" = "1" ]; then
  say "keeping worktrees ($ROOT left in place)"
elif [ -f "$WORKSPACES" ]; then
  say "returning worktrees to their repositories"
  # origin<TAB>worktree, one per line, straight from Meshvy's own record.
  PAIRS="$(python3 - "$WORKSPACES" <<'PY'
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(0)
for workspace in doc.get("workspaces", []):
    for repo in workspace.get("repos", []):
        origin, tree = repo.get("originPath"), repo.get("worktreePath")
        if origin and tree:
            print("%s\t%s" % (origin, tree))
PY
)"
  if [ -z "$PAIRS" ]; then
    note "no worktrees recorded"
  else
    while IFS=$'\t' read -r ORIGIN TREE; do
      [ -n "$TREE" ] || continue
      if [ ! -d "$TREE" ]; then
        note "gone already: $TREE"
        continue
      fi

      DIRTY="$(git -C "$TREE" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
      UNPUSHED=0
      if git -C "$TREE" rev-parse '@{upstream}' >/dev/null 2>&1; then
        UNPUSHED="$(git -C "$TREE" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)"
      else
        # No upstream: every commit that is not in the origin repo is unpushed.
        UNPUSHED="$(git -C "$TREE" rev-list --count HEAD 2>/dev/null || echo 0)"
        BASE="$(git -C "$TREE" rev-list --count HEAD ^"$(git -C "$ORIGIN" rev-parse HEAD 2>/dev/null)" 2>/dev/null || echo 0)"
        UNPUSHED="$BASE"
      fi

      if [ "$FORCE" = "0" ] && { [ "$DIRTY" != "0" ] || [ "$UNPUSHED" != "0" ]; }; then
        note "KEPT $TREE"
        note "     $DIRTY uncommitted file(s), $UNPUSHED commit(s) not in the origin repo"
        KEPT=$((KEPT + 1))
        continue
      fi

      if [ "$FORCE" = "1" ]; then
        run "git -C '$ORIGIN' worktree remove --force '$TREE' >/dev/null 2>&1 || rm -rf '$TREE'"
      else
        run "git -C '$ORIGIN' worktree remove '$TREE' >/dev/null 2>&1 || true"
      fi
      [ "$DRY" = "1" ] || { [ -d "$TREE" ] && note "could not remove $TREE" && KEPT=$((KEPT + 1)) || note "removed $TREE"; }
    done <<< "$PAIRS"

    # Clear any registration left pointing at a checkout that is now gone.
    say "pruning stale worktree registrations"
    while IFS=$'\t' read -r ORIGIN _; do
      [ -d "$ORIGIN" ] && run "git -C '$ORIGIN' worktree prune 2>/dev/null || true"
    done <<< "$(printf '%s\n' "$PAIRS" | sort -u)"
  fi
fi

# --- 5. Remove what is left --------------------------------------------------
if [ "$KEEP_WORKTREES" = "0" ] && [ -d "$ROOT" ]; then
  if [ "$KEPT" != "0" ]; then
    say "leaving $ROOT in place — $KEPT checkout(s) still hold unsaved work"
  else
    # Only ever remove the root once it is empty. A blanket rm -rf here would
    # take out any workspace that is not in workspaces.json — one created by an
    # older version, or left behind when settings were reset — and those are
    # real git worktrees that must be handed back, not deleted.
    LEFTOVER="$(find "$ROOT" -mindepth 1 -maxdepth 1 ! -name '.*' 2>/dev/null | wc -l | tr -d ' ')"
    if [ "$LEFTOVER" = "0" ]; then
      say "removing $ROOT"
      run "rm -rf '$ROOT'"
    else
      say "leaving $ROOT in place"
      note "it holds $LEFTOVER folder(s) Meshvy has no record of:"
      find "$ROOT" -mindepth 1 -maxdepth 1 ! -name '.*' 2>/dev/null | while read -r extra; do
        note "  $extra"
      done
      note "these are git worktrees — remove them with 'git worktree remove', not rm"
    fi
  fi
fi

if [ -d "$APP_SUPPORT" ]; then
  say "removing settings and caches"
  run "rm -rf '$APP_SUPPORT'"
fi

say "removing the keychain entry"
run "security delete-generic-password -s '$KEYCHAIN_SERVICE' >/dev/null 2>&1 || true"

if [ -n "$APP" ] && [ -d "$APP" ]; then
  say "removing $APP"
  if [ "$DRY" = "0" ] && ! rm -rf "$APP" 2>/dev/null; then
    note "could not remove it — try: sudo rm -rf '$APP'"
  elif [ "$DRY" = "1" ]; then
    note "would: rm -rf '$APP'"
  fi
fi

echo
if [ "$DRY" = "1" ]; then
  say "dry run — nothing was changed"
elif [ "$KEPT" != "0" ]; then
  say "done, but $KEPT checkout(s) were kept because they hold unsaved work"
  note "commit or push them, then re-run; or re-run with --force to discard"
else
  say "Meshvy removed"
fi
note "your own repositories were not touched"
