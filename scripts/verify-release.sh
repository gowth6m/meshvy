#!/usr/bin/env bash
# Says what Apple makes of a build, and why.
#
#   ./scripts/verify-release.sh                        dist/ from the last build
#   ./scripts/verify-release.sh /Applications/Meshvy.app
#   ./scripts/verify-release.sh --require-notarised …  non-zero unless it would
#                                                      open with no warning
#
# Five things decide whether macOS opens a download without complaining, and
# only the last one is visible from the Finder:
#
#   1. the signature verifies at all
#   2. it is a Developer ID, not the ad-hoc signature a local build gets
#   3. the hardened runtime is on, which notarisation requires
#   4. the signature carries Apple's secure timestamp, which it also requires
#   5. a notarisation ticket is stapled to the bundle, so Gatekeeper can see
#      the build was scanned without going to the network
#
# A build can pass the first four and still be refused, which is the state
# worth catching before it ships rather than after.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REQUIRE_NOTARISED=0
TARGETS=()

for argument in "$@"; do
  case "$argument" in
    --require-notarised) REQUIRE_NOTARISED=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) TARGETS+=("$argument") ;;
  esac
done

if [ "${#TARGETS[@]}" -eq 0 ]; then
  for candidate in "$ROOT/dist/Meshvy.app" "$ROOT"/dist/*.dmg; do
    [ -e "$candidate" ] && TARGETS+=("$candidate")
  done
fi
[ "${#TARGETS[@]}" -gt 0 ] || { printf 'verify: nothing to check\n' >&2; exit 1; }

PROBLEMS=0
pass() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m•\033[0m %s\n' "$*"; }
fail() { printf '  \033[31m✗\033[0m %s\n' "$*"; PROBLEMS=$((PROBLEMS + 1)); }

# Everything below reads from these two, so they are gathered once per target.
describe() { codesign -dvvv "$1" 2>&1 || true; }
verdict() { spctl -a -vvv -t "$2" "$1" 2>&1 || true; }

check_app() {
  local app="$1" details authority team
  details="$(describe "$app")"

  if codesign --verify --strict --deep "$app" >/dev/null 2>&1; then
    pass "signature verifies"
  else
    fail "signature does not verify"
  fi

  authority="$(printf '%s' "$details" | sed -n 's/^Authority=//p' | head -1)"
  team="$(printf '%s' "$details" | sed -n 's/^TeamIdentifier=//p' | head -1)"
  if printf '%s' "$details" | grep -q 'flags=.*adhoc'; then
    # What every local build and every unsigned release has. Gatekeeper will
    # not open it from a download, whatever else is true.
    fail "ad-hoc signature — no Developer ID (this is what triggers the malware warning)"
  elif [ -n "$authority" ]; then
    pass "signed by: $authority"
    [ -n "$team" ] && [ "$team" != "not set" ] && pass "team: $team"
  else
    fail "not signed"
  fi

  if printf '%s' "$details" | grep -q 'flags=.*runtime'; then
    pass "hardened runtime"
  else
    fail "hardened runtime off — Apple will refuse to notarise it"
  fi

  if printf '%s' "$details" | grep -q '^Timestamp='; then
    pass "secure timestamp"
  else
    fail "no secure timestamp — sign with --timestamp or Apple will refuse it"
  fi

  if xcrun stapler validate "$app" >/dev/null 2>&1; then
    pass "notarisation ticket stapled"
  else
    fail "no notarisation ticket"
  fi

  if printf '%s' "$(verdict "$app" exec)" | grep -q 'accepted'; then
    pass "Gatekeeper accepts it"
  else
    fail "Gatekeeper rejects it — macOS will refuse the first launch"
  fi
}

check_dmg() {
  local dmg="$1"
  if xcrun stapler validate "$dmg" >/dev/null 2>&1; then
    pass "notarisation ticket stapled"
  else
    fail "no notarisation ticket"
  fi
  # `-t open` with the primary-signature context is how Gatekeeper judges a
  # disk image, rather than the `exec` it uses for an app.
  if printf '%s' "$(spctl -a -vvv -t open --context context:primary-signature "$dmg" 2>&1 || true)" \
      | grep -q 'accepted'; then
    pass "Gatekeeper accepts it"
  else
    fail "Gatekeeper rejects it"
  fi
}

for target in "${TARGETS[@]}"; do
  printf '\n%s\n' "$(basename "$target")"
  if [ ! -e "$target" ]; then
    fail "does not exist"
  elif [ -d "$target" ]; then
    check_app "$target"
  else
    check_dmg "$target"
  fi
done

printf '\n'
if [ "$PROBLEMS" -eq 0 ]; then
  printf 'verify: this build opens with no warning.\n'
  exit 0
fi

if [ "$REQUIRE_NOTARISED" -eq 1 ]; then
  printf 'verify: %s problem(s) — this build would be refused by Gatekeeper.\n' "$PROBLEMS" >&2
  exit 1
fi

printf 'verify: %s problem(s). Expected for an unsigned build — see README.\n' "$PROBLEMS"
printf 'verify: pass --require-notarised to make this an error.\n'
exit 0
