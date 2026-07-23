#!/bin/bash

# Builds the CI image and drops you into it with the project and any drives
# referenced by .env mounted, so ci/scripts/*.sh can be run in a Linux shell.

# Load .env file, stripping quotes from values
if [ -f .env ]; then
    while IFS='=' read -r key value; do
        [[ "$key" =~ ^#.*$ ]] && continue
        [[ -z "$key" ]] && continue
        value="${value%\"}"
        value="${value#\"}"
        export "$key=$value"
    done < .env
else
    echo "Error: .env file not found."
    exit 1
fi

image_name=${1:-cooldownmanagerclassic-ci}
dockerfile_path="./ci/build/Dockerfile"
project_dir=$(pwd)
container_workdir="/app/"

echo "Building Docker image: $image_name"
docker buildx build -t "$image_name" -f "$dockerfile_path" .

if [[ $? -ne 0 ]]; then
    echo "Docker build failed."
    exit 1
fi

# Extract unique drive letters from all paths
declare -A drives
extract_drive() {
    if [[ "$1" =~ ^/([a-zA-Z])/ ]]; then
        drives["${BASH_REMATCH[1]^^}"]=1
    fi
}

extract_drive "$wow_addons_dir_era"
extract_drive "$wow_addons_dir_anniversary"
extract_drive "$wow_addons_dir_ptr"

# Build volume arguments for each unique drive
volume_args=""
for drive in "${!drives[@]}"; do
    volume_args="$volume_args -v /${drive}:/${drive}"
done

echo "Running Docker container and mounting project directory.."
echo "Mounting drives: ${!drives[*]}"

docker run --rm -ti \
    -v "$project_dir:$container_workdir" \
    $volume_args \
    "$image_name" bash

if [[ $? -ne 0 ]]; then
    echo "Error: Failed to start Docker container."
    exit 1
fi
