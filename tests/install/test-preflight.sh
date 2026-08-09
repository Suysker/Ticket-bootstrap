#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

docker run --rm \
    --platform linux/amd64 \
    --tmpfs /run:rw,nosuid,nodev,noexec,mode=755 \
    --mount "type=bind,src=$ROOT,dst=/src,readonly" \
    debian:12-slim \
    /bin/sh -eu -c '
        apt-get update >/dev/null
        apt-get install -y --no-install-recommends util-linux openssl >/dev/null
        output=$(/bin/sh /src/install.sh --preflight)
        test "$output" = "trusted_host_preflight=ok"
        if /bin/sh /src/install.sh --unknown >/tmp/unexpected 2>&1; then
            exit 1
        fi
        grep -q "usage: maitix-control-install.sh" /tmp/unexpected
    '
