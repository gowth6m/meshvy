#!/usr/bin/env bash
# Cuts a release: bumps VERSION, commits, tags and pushes. The Release workflow
# builds and publishes the artifacts from the tag.
#
#   ./Scripts/release.sh 0.7.0
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: Scripts/release.sh <version>   e.g. Scripts/release.sh 0.7.0" >&2
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
git tag -a "v$VERSION" -m "Meshvy $VERSION"

echo
echo "Tagged v$VERSION. Push the branch first, let CI go green, then the tag:"
echo
echo "  git push origin HEAD:main"
echo "  gh run watch            # or just wait for the CI run to pass"
echo "  git push origin v$VERSION"
echo
echo "Pushing both at once means the tag starts a release build before anything"
echo "has checked the commit — which is how 0.10.0 came to fail on the runner"
echo "after CI had reported success. The tag is the expensive one: it builds,"
echo "signs, notarises and publishes."
