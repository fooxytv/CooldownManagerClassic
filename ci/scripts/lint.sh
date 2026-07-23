#!/bin/bash

# Automatically detect the addon directory by finding the .toc file in the root
ADDON_DIR=$(dirname "$(find . -maxdepth 1 -name "*.toc" | head -n 1)")

if [ -z "$ADDON_DIR" ]; then
    echo -e "\033[31mError: Could not find a .toc file. Please make sure you're in the root of your addon project.\033[0m"
    exit 1
fi

if ! command -v luacheck &> /dev/null
then
    echo -e "\033[31mError: luacheck is not installed. Please install luacheck manually.\033[0m"
    echo "Install with: luarocks install luacheck"
    exit 1
fi

echo "Running Lua lint checks on directory: $(pwd)"

# The 11x undefined-global diagnostics are deliberately NOT ignored.
#
# Ignoring them made the globals list in .luacheckrc decorative and let a
# mistyped API name -- GetSepllInfo -- through CI to surface as an in-game
# error instead. Every global the addon touches is enumerated there, so these
# now catch typos for free. If a legitimate new API trips this, add it to
# .luacheckrc rather than restoring the ignore.
#
# Still ignored, because they are noise in a WoW addon:
# 211 - unused local variable
# 212 - unused argument
# 432 - shadowing upvalue argument
# 631 - line is too long
luacheck "$ADDON_DIR" \
    --std max \
    --codes \
    --ignore 211 \
    --ignore 212 \
    --ignore 432 \
    --ignore 631 \
    --exclude-files "ci/**"
