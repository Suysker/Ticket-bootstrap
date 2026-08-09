#!/bin/sh
set -eu

export DEBIAN_FRONTEND=noninteractive
apt-get update >/dev/null
apt-get install -y --no-install-recommends \
    age ca-certificates curl openssh-client openssl python3 util-linux >/dev/null

ROOT=$(mktemp -d /tmp/maitix-bootstrap-fixture.XXXXXXXX)
SERVER_PID=

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    case "$ROOT" in
        /tmp/maitix-bootstrap-fixture.*) rm -rf -- "$ROOT" ;;
        *) status=1 ;;
    esac
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

openssl req \
    -x509 \
    -newkey rsa:2048 \
    -nodes \
    -days 1 \
    -subj /CN=github.com \
    -addext 'subjectAltName=DNS:github.com,DNS:ticket.test' \
    -addext 'basicConstraints=critical,CA:TRUE' \
    -keyout "$ROOT/server.key" \
    -out "$ROOT/server.crt" >/dev/null 2>&1
cp "$ROOT/server.crt" /usr/local/share/ca-certificates/maitix-fixture.crt
update-ca-certificates >/dev/null
printf '%s\n' '127.0.0.1 github.com ticket.test' >> /etc/hosts

openssl genpkey -algorithm Ed25519 -out "$ROOT/control-release.key"
openssl pkey \
    -in "$ROOT/control-release.key" \
    -pubout \
    -out "$ROOT/control-release.pub"
cp "$ROOT/control-release.pub" "$ROOT/worker-release.pub"
age-keygen -o "$ROOT/control-distribution-identity.txt" >/dev/null 2>&1
DISTRIBUTION_RECIPIENT=$(age-keygen -y \
    "$ROOT/control-distribution-identity.txt" 2>/dev/null)
age-keygen -o "$ROOT/age-identity.txt" >/dev/null 2>&1
age-keygen -o "$ROOT/backup-identity.txt" >/dev/null 2>&1
BACKUP_RECIPIENT=$(age-keygen -y "$ROOT/backup-identity.txt" 2>/dev/null)
ssh-keygen -q -t ed25519 -N '' -f "$ROOT/github-read-key"
GITHUB_HOST_KEY=$(awk '{ print $2 }' "$ROOT/github-read-key.pub")
printf 'github.com ssh-ed25519 %s\n' "$GITHUB_HOST_KEY" > "$ROOT/github-known-hosts"

RELEASE=$ROOT/release
mkdir -p "$RELEASE/runtime" "$RELEASE/deployments/control-plane"
cat > "$RELEASE/runtime/maitix-control" <<'EOF'
#!/bin/sh
set -eu

if [ "$#" -ge 3 ] && [ "$1" = internal ] && [ "$2" = release ] && [ "$3" = verify ]; then
    shift 3
    archive=
    extract_to=
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --archive) archive=$2; shift 2 ;;
            --extract-to) extract_to=$2; shift 2 ;;
            *) shift 2 ;;
        esac
    done
    mkdir -p "$extract_to"
    tar -xzf "$archive" -C "$extract_to"
    exit 0
fi

if [ "$#" -eq 3 ] && [ "$1" = doctor ] && [ "$2" = --offline ] && [ "$3" = --json ]; then
    exit 0
fi

exit 2
EOF
cat > "$RELEASE/deployments/control-plane/install.sh" <<'EOF'
#!/bin/sh
set -eu

[ "${MAITIX_CLUSTER_ID:-}" = maitix-prod ]
[ "${MAITIX_CONTROL_INSTALL_MODE:-}" = fresh ]
[ "${MAITIX_CONTROL_RESTORE_REFERENCE:-}" = none ]
touch /tmp/maitix-control-installed
EOF
chmod 755 \
    "$RELEASE/runtime/maitix-control" \
    "$RELEASE/deployments/control-plane/install.sh"
tar \
    --create \
    --gzip \
    --file "$ROOT/control-release.tar.gz" \
    --directory "$RELEASE" \
    runtime \
    deployments
ARCHIVE_SHA=$(sha256sum "$ROOT/control-release.tar.gz" | awk '{ print $1 }')
ARCHIVE_SIZE=$(wc -c < "$ROOT/control-release.tar.gz" | awk '{ print $1 }')
printf '{"archive_sha256":"%s","archive_size":%s,"release_id":"test-release"}\n' \
    "$ARCHIVE_SHA" "$ARCHIVE_SIZE" > "$ROOT/control-release.manifest.json"
openssl pkeyutl \
    -sign \
    -inkey "$ROOT/control-release.key" \
    -rawin \
    -in "$ROOT/control-release.manifest.json" \
    -out "$ROOT/control-release.manifest.sig"
printf '%s\n' fixture-worker-distribution > "$ROOT/worker-distribution.zip"

DIST=$ROOT/distribution
mkdir "$DIST"
printf '%s\n' maitix-control-distribution-v1 > "$DIST/format"
printf '%s\n' test-release > "$DIST/release-id"
cp "$ROOT/control-release.tar.gz" "$DIST/control-release.tar.gz"
cp "$ROOT/control-release.manifest.json" "$DIST/control-release.manifest.json"
cp "$ROOT/control-release.manifest.sig" "$DIST/control-release.manifest.sig"
cp "$ROOT/worker-distribution.zip" "$DIST/worker-distribution.zip"
chmod 644 "$DIST"/*
tar \
    --create \
    --gzip \
    --file "$ROOT/control-distribution.tar.gz" \
    --directory "$DIST" \
    format \
    release-id \
    control-release.tar.gz \
    control-release.manifest.json \
    control-release.manifest.sig \
    worker-distribution.zip
age \
    --encrypt \
    --recipient "$DISTRIBUTION_RECIPIENT" \
    --output "$ROOT/control.age" \
    "$ROOT/control-distribution.tar.gz"
printf '%s' truncated > "$ROOT/truncated.age"

build_seed() {
    grant=$1
    asset=$2
    seed=$ROOT/seed-$grant
    mkdir "$seed"
    printf '%s\n' maitix-control-bootstrap-v3 > "$seed/format"
    printf '%s\n' maitix-prod > "$seed/cluster-id"
    printf '%s\n' fresh > "$seed/install-mode"
    printf '%s\n' test-release > "$seed/release-id"
    printf '%s\n' \
        "https://github.com/Suysker/Ticket-bootstrap/releases/download/control-test/$asset" \
        > "$seed/control-asset-url"
    printf '%s\n' git@github.com:Suysker/Ticket.git > "$seed/config-repository"
    printf '%s\n' main > "$seed/config-branch"
    printf '%s\n' "$BACKUP_RECIPIENT" > "$seed/backup-recipient"
    printf '%s\n' none > "$seed/restore-reference"
    cp "$ROOT/control-release.pub" "$seed/control-release.pub"
    cp "$ROOT/worker-release.pub" "$seed/worker-release.pub"
    cp "$ROOT/control-distribution-identity.txt" \
        "$seed/control-distribution-identity.txt"
    cp "$ROOT/age-identity.txt" "$seed/age-identity.txt"
    cp "$ROOT/github-read-key" "$seed/github-read-key"
    cp "$ROOT/github-known-hosts" "$seed/github-known-hosts"
    chmod 644 \
        "$seed/format" \
        "$seed/cluster-id" \
        "$seed/install-mode" \
        "$seed/release-id" \
        "$seed/control-asset-url" \
        "$seed/config-repository" \
        "$seed/config-branch" \
        "$seed/control-release.pub" \
        "$seed/worker-release.pub" \
        "$seed/github-known-hosts"
    chmod 600 \
        "$seed/backup-recipient" \
        "$seed/restore-reference" \
        "$seed/control-distribution-identity.txt" \
        "$seed/age-identity.txt" \
        "$seed/github-read-key"
    tar \
        --create \
        --gzip \
        --file "$ROOT/seed-$grant.tar.gz" \
        --directory "$seed" \
        format \
        cluster-id \
        install-mode \
        release-id \
        control-asset-url \
        config-repository \
        config-branch \
        backup-recipient \
        restore-reference \
        control-release.pub \
        worker-release.pub \
        control-distribution-identity.txt \
        age-identity.txt \
        github-read-key \
        github-known-hosts
}

build_seed ok control.age
build_seed truncated truncated.age

MAITIX_FIXTURE_ROOT=$ROOT python3 /src/tests/install/fixture_server.py &
SERVER_PID=$!
ready=0
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
    if curl --fail --silent --show-error https://ticket.test/health >/dev/null; then
        ready=1
        break
    fi
    sleep 1
done
[ "$ready" -eq 1 ]

printf 'TEST-CODE\n' |
    script -qec \
        '/bin/sh /src/install.sh --origin https://ticket.test --grant ok' \
        /dev/null >/tmp/online-success.log
[ -f /tmp/maitix-control-installed ]

if printf 'TEST-CODE\n' |
    script -qec \
        '/bin/sh /src/install.sh --origin https://ticket.test --grant ok' \
        /dev/null >/tmp/replay.log 2>&1; then
    printf '%s\n' 'cross-process grant replay unexpectedly succeeded' >&2
    exit 1
fi
grep -q 'control-host enrollment failed' /tmp/replay.log

if printf 'TEST-CODE\n' |
    script -qec \
        '/bin/sh /src/install.sh --origin https://ticket.test --grant truncated' \
        /dev/null >/tmp/truncated.log 2>&1; then
    printf '%s\n' 'truncated encrypted distribution unexpectedly succeeded' >&2
    exit 1
fi
grep -q 'control distribution decryption failed' /tmp/truncated.log

[ -z "$(find /run -maxdepth 1 -name 'maitix-control-seed.*' -print -quit)" ]
[ -z "$(find /var/tmp -maxdepth 1 -name 'maitix-control-install.*' -print -quit)" ]
