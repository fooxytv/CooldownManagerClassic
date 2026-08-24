#!/bin/bash

# Packages the addon and unzips it into a local WoW AddOns folder.
#
#   ./ci/scripts/deploy.sh era           # Classic Era (and Season of Discovery)
#   ./ci/scripts/deploy.sh anniversary   # Anniversary realms (TBC 2.5.6)
#   ./ci/scripts/deploy.sh mop           # Mists of Pandaria Classic (5.5.x)
#   ./ci/scripts/deploy.sh ptr

# Load .env file for all environments
if [ -f .env ]; then
    # Strip quotes and carriage returns from values when exporting
    while IFS='=' read -r key value || [ -n "$key" ]; do
        # Skip comments and empty lines
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        # Remove carriage returns, surrounding quotes
        key=$(echo "$key" | tr -d '\r')
        value=$(echo "$value" | tr -d '\r')
        value="${value%\"}"
        value="${value#\"}"
        # Validate key is a valid shell identifier before exporting
        if [[ "$key" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]]; then
            export "$key=$value"
        fi
    done < .env
else
    echo "Error: .env file not found."
    exit 1
fi

# Locate .toc file in the project root only
toc_file=$(find "$(pwd)" -maxdepth 1 -name "*.toc" | head -n 1)
if [ -z "$toc_file" ]; then
    echo "Error: No .toc file found in project root."
    exit 1
fi

# The AddOns folder name must match the .toc basename, so that is what we use
# for both the zip and the destination directory. ## Title is display-only.
addon_name=$(basename "$toc_file" .toc | sed -E 's/_(Vanilla|TBC|Wrath|Cata|Mists|Mainline)$//')
# awk rather than `grep -oP`: PCRE mode is unavailable in some Git Bash locales
# ("-P supports only unibyte and UTF-8 locales") and silently yields nothing.
title=$(awk -F': ' '/^## Title:/{print $2}' "$toc_file" | tr -d '\r')
version=$(awk -F': ' '/^## Version:/{print $2}' "$toc_file" | tr -d '\r')

echo "Detected TOC file: $toc_file"
echo "Addon folder: '$addon_name'"
echo "Title: '$title'"
echo "Version: '$version'"

if [ -z "$addon_name" ] || [ -z "$version" ]; then
    echo "Error: Addon name or version not found in .toc file."
    exit 1
fi

./ci/scripts/package.sh

zip_file="ci/dist/${addon_name}-${version}.zip"
echo "Zip file will be: '$zip_file'"

deploy_to() {
    local target_dir="$1"
    local label="$2"

    if [ -z "$target_dir" ]; then
        echo "Error: no AddOns directory configured in .env for '$label'."
        exit 1
    fi

    echo "Copying $zip_file to \"$target_dir/$addon_name\"..."
    # Clear the previous install first so a renamed or deleted Lua file cannot
    # linger in the AddOns folder and keep getting loaded from the .toc.
    rm -rf "${target_dir:?}/${addon_name:?}"
    unzip -o "$zip_file" -d "$target_dir/$addon_name"
    echo "Done. Type /reload in game."
}

case "$1" in
    era|local|lcl)
        deploy_to "$wow_addons_dir_era" "era"
        ;;
    anniversary|anniv|tbc)
        deploy_to "$wow_addons_dir_anniversary" "anniversary"
        ;;
    mop|mists|classic)
        deploy_to "$wow_addons_dir_mop" "mop"
        ;;
    ptr)
        deploy_to "$wow_addons_dir_ptr" "ptr"
        ;;
    *)
        echo "Error: Invalid argument. Use 'era' (or 'local'), 'anniversary', 'mop', or 'ptr'."
        exit 1
        ;;
esac
