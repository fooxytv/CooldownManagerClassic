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

# Ignore the diagnostics that are noise in a WoW addon:
# 111 - setting an undefined global variable
# 112 - mutating an undefined global variable
# 113 - accessing an undefined global variable
# 211 - unused local variable
# 212 - unused argument
# 432 - shadowing upvalue argument
# 631 - line is too long
luacheck "$ADDON_DIR" \
    --std max \
    --codes \
    --ignore 111 \
    --ignore 112 \
    --ignore 113 \
    --ignore 211 \
    --ignore 212 \
    --ignore 432 \
    --ignore 631 \
    --exclude-files "ci/**"
