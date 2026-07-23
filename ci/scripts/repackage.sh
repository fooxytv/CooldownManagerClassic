#!/bin/bash

# CurseForge expects the zip to contain a single top-level folder named after
# the addon. package.sh zips the working directory contents flat, so this step
# unpacks and rewraps the archive with that folder in place.

# Exit immediately if a command exits with a non-zero status
set -e

# Define paths
dist_dir="./ci/dist"
temp_dir="./ci/temp"

toc_file=$(find "$(pwd)" -maxdepth 1 -name "*.toc" | head -n 1)
if [ -z "$toc_file" ]; then
    echo -e "\033[31mError: No .toc file found in project root.\033[0m"
    exit 1
fi
addon_name=$(basename "$toc_file" .toc)

existing_zip=$(find "$dist_dir" -type f -name "${addon_name}-*.zip" | head -n 1)

if [ -z "$existing_zip" ]; then
    echo -e "\033[31mError: No ZIP file found in $dist_dir.\033[0m"
    exit 1
fi

base_name=$(basename "$existing_zip" .zip)
version_build=$(echo "$base_name" | sed "s/^$addon_name-//")

if [ -z "$version_build" ]; then
    echo -e "\033[31mError: Could not extract version and build number from the ZIP file name.\033[0m"
    exit 1
fi

echo "Setting up temporary directory..."
rm -rf "$temp_dir"
mkdir -p "$temp_dir/$addon_name"

echo "Extracting $existing_zip to $temp_dir/$addon_name..."
unzip -q "$existing_zip" -d "$temp_dir/$addon_name"

output_zip="$(pwd)/$dist_dir/${addon_name}-${version_build}.zip"
# Build alongside the original and swap at the end, so a failure here cannot
# leave the dist directory with no artifact at all.
staging_zip="${output_zip}.new"
rm -f "$staging_zip"

echo "Creating new ZIP file: $output_zip"
cd "$temp_dir"

# Git Bash on Windows ships unzip but not zip; fall back to Python there.
if command -v zip &> /dev/null; then
    zip -r "$staging_zip" "$addon_name"
elif command -v python &> /dev/null; then
    echo "(zip not found; using Python zipfile)"
    python - "$staging_zip" "$addon_name" <<'PYTHON'
import os, sys, zipfile

zip_path, root_folder = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
    for root, _, files in os.walk(root_folder):
        for name in files:
            path = os.path.join(root, name)
            archive.write(path, path.replace(os.sep, "/"))
PYTHON
else
    echo -e "\033[31mError: neither zip nor python is available to build the archive.\033[0m"
    exit 1
fi

cd - > /dev/null

mv -f "$staging_zip" "$output_zip"

echo "Cleaning up temporary files..."
rm -rf "$temp_dir"

if [ -f "$output_zip" ]; then
    echo -e "\033[32mSuccessfully created new ZIP file: $output_zip\033[0m"
else
    echo -e "\033[31mError: Failed to create new ZIP file.\033[0m"
    exit 1
fi
