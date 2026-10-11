#!/usr/bin/env bash
# Cuts a release: bumps VERSION, commits, tags and pushes. The Release workflow
# builds and publishes the artifacts from the tag.
#
#   ./scripts/release.sh 0.7.0
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: scripts/release.sh <version>   e.g. scripts/release.sh 0.7.0" >&2
  exit 1
fi
if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "version must look like 1.2.3" >&2
  exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is dirty — commit or stash first" >&2
  exit 1
fi
if git rev-parse "v$VERSION" >/dev/null 2>&1; then
  echo "tag v$VERSION already exists" >&2
  exit 1
fi
if ! grep -q "^## \[$VERSION\]" CHANGELOG.md; then
  echo "CHANGELOG.md has no '## [$VERSION]' section — write the notes first" >&2
  exit 1
fi

echo "$VERSION" > VERSION
git add VERSION
git commit -m "release: $VERSION"
git tag -a "v$VERSION" -m "Arcforge $VERSION"

echo
echo "Tagged v$VERSION. Push to publish:"
echo "  git push origin HEAD && git push origin v$VERSION"
