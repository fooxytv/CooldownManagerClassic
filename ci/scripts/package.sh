#!/bin/bash

# Packages the addon into ci/dist/<AddonFolder>-<version>.zip.
#
# The archive is named after the .toc *filename*, not the ## Title, because the
# folder WoW loads the addon from has to match the .toc basename and our title
# ("Cooldown Manager Classic") contains spaces. The flavour suffix is stripped:
# CooldownManagerClassic_TBC.toc still installs to CooldownManagerClassic.

toc_file=$(find "$(pwd)" -maxdepth 1 -name "*.toc" | head -n 1)

if [ -z "$toc_file" ]; then
    echo -e "\033[31mError: Could not find a .toc file in the project root.\033[0m"
    exit 1
fi

addon_name=$(basename "$toc_file" .toc | sed -E 's/_(Vanilla|TBC|Wrath|Cata|Mists|Mainline)$//')
version=$(awk -F': ' '/^## Version:/{print $2}' "$toc_file" | tr -d '\r')

if [ -z "$addon_name" ] || [ -z "$version" ]; then
    echo -e "\033[31mError: Could not find the addon name or version in the .toc file.\033[0m"
    exit 1
fi

if [ -d "./ci/dist" ]; then
    echo "Removing existing dist directory.."
    rm -r ./ci/dist
fi

echo "Creating 'dist' directory.."
mkdir ./ci/dist

zip_file="ci/dist/${addon_name}-${version}.zip"
echo "Packaging addon into $zip_file.."

# Git Bash on Windows ships unzip but not zip, so fall back to Python's
# zipfile there. Both paths must honour the same exclusion list.
if command -v zip &> /dev/null; then
    zip -r "$zip_file" . \
        -x "*.git*" \
           "dist/*" \
           "ci/*" \
           "README.md" \
           "docs/*" \
           ".vscode/*" \
           ".env*" \
           "code/*" \
           ".claude/*" \
           "CLAUDE.md" \
           ".luacheckrc"
elif command -v python &> /dev/null; then
    echo "(zip not found; using Python zipfile)"
    python - "$zip_file" <<'PYTHON'
import fnmatch, os, sys, zipfile

EXCLUDE = [
    "*.git*", "dist/*", "ci/*", "README.md", "docs/*", ".vscode/*",
    ".env*", "code/*", ".claude/*", "CLAUDE.md", ".luacheckrc",
]

def excluded(rel):
    return any(fnmatch.fnmatch(rel, pat) or rel.startswith(pat.rstrip("*"))
               for pat in EXCLUDE)

zip_path = sys.argv[1]
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
    for root, dirs, files in os.walk("."):
        dirs[:] = [d for d in dirs
                   if not excluded(os.path.relpath(os.path.join(root, d), ".").replace(os.sep, "/") + "/")]
        for name in files:
            rel = os.path.relpath(os.path.join(root, name), ".").replace(os.sep, "/")
            if not excluded(rel):
                archive.write(rel, rel)
                print("  adding:", rel)
PYTHON
else
    echo -e "\033[31mError: neither zip nor python is available to build the archive.\033[0m"
    exit 1
fi

if [ $? -eq 0 ]; then
    echo -e "\033[32mSuccessfully packaged addon.\033[0m"
else
    echo -e "\033[31mError: Failed to package addon.\033[0m"
    exit 1
fi
