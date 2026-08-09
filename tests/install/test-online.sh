#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

docker run --rm \
    --platform linux/amd64 \
    --tmpfs /run:rw,nosuid,nodev,noexec,mode=755 \
    --mount "type=bind,src=$ROOT,dst=/src,readonly" \
    debian:12-slim \
    /bin/sh -eu /src/tests/install/test-online-in-container.sh
