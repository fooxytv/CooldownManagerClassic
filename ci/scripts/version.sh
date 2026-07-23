#!/usr/bin/env bash

set -euo pipefail

# Find all .toc files in the project root
mapfile -t toc_files < <(find "$(pwd)" -maxdepth 1 -name "*.toc")

if [[ ${#toc_files[@]} -eq 0 ]]; then
    echo "No .toc files found."
    exit 1
fi

# Use the main .toc file (without a flavour suffix) for reading the current
# version. Flavour-specific .toc files are kept in step with it.
main_toc_file=""
for f in "${toc_files[@]}"; do
    if [[ "$(basename "$f")" == "CooldownManagerClassic.toc" ]]; then
        main_toc_file="$f"
        break
    fi
done

# Fallback to first file if main not found
if [[ -z "$main_toc_file" ]]; then
    main_toc_file="${toc_files[0]}"
fi

bump_type="${1:-none}"
pre_release_type="${2:-}"
commit_hash=$(git rev-parse --short HEAD)

increment_version() {
    local version=$1
    local part=$2

    IFS='.' read -r major minor patch <<< "$version"

    case $part in
        major)
            ((major++))
            minor=0
            patch=0
            ;;
        minor)
            ((minor++))
            patch=0
            ;;
        patch)
            ((patch++))
            ;;
    esac

    echo "$major.$minor.$patch"
}

get_version_from_toc() {
    local file=$1
    awk -F': ' '/^## Version:/ {print $2}' "$file" | tr -d '\r'
}

update_toc_version() {
    local new_version=$1
    local file=$2
    sed -i.bak "s/^## Version:.*/## Version: $new_version/" "$file"
    rm -f "${file}.bak"
    echo "Updated $file with new version: $new_version" >&2
}

update_all_toc_files() {
    local new_version=$1
    for toc_file in "${toc_files[@]}"; do
        update_toc_version "$new_version" "$toc_file"
    done
}

current_version=$(get_version_from_toc "$main_toc_file")
if [[ -z "$current_version" ]]; then
    echo "No version found in .toc file."
    exit 1
fi

base_version=$(echo "$current_version" | sed 's/-.*//')

# bump_type "none" keeps the current X.Y.Z but still strips any prerelease suffix
# (e.g. promoting 1.6.0-alpha.abc123 -> 1.6.0) and writes it back to the .toc files.
# increment_version is a no-op for "none", so this falls through the normal path.
if [[ "$bump_type" == "none" ]]; then
    >&2 echo "No version bump; normalizing to release version: $base_version"
fi

new_version=$(increment_version "$base_version" "$bump_type")

if [[ "$pre_release_type" == "alpha" || "$pre_release_type" == "beta" ]]; then
    new_version="$new_version-$pre_release_type.$commit_hash"
fi

update_all_toc_files "$new_version"
echo "$new_version"
