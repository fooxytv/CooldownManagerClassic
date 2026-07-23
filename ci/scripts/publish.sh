#!/bin/bash

set -euo pipefail

# Usage examples:
#   ./publish.sh           # defaults to patch
#   ./publish.sh patch     # explicit patch
#   ./publish.sh none      # skip bump, just publish
#
#   or with pre-release types:
#   ./publish.sh minor alpha
#
# Pushing the tag is what triggers .github/workflows/main.yaml, which packages
# the addon and uploads it to CurseForge.

bump_type="${1:-patch}"
pre_release_type="${2:-}"
branch="${3:-main}"

echo "Bumping (or reading) version ($bump_type) [prerelease: $pre_release_type]..."
raw_version="$(./ci/scripts/version.sh "$bump_type" "$pre_release_type")"
new_version="$(echo "$raw_version" | tr -d '[:cntrl:]')"

echo "Version to publish: [$new_version]"

echo "Committing version bump (if any changes)..."
git add .
git commit -m "Bump version to $new_version" || {
    echo "No changes to commit (or commit failed)."
}

new_tag="v${new_version}"
echo "Creating new tag: $new_tag"
git tag -a "$new_tag" -m "Release $new_version"

echo
echo "Tag created locally. To publish, push the branch and tag:"
echo "  git push origin $branch"
echo "  git push origin $new_tag"
