#!/bin/sh
# Public trust bootstrap for one self-contained Maitix control-plane release.
set -eu

umask 077
export LC_ALL=C

PROTOCOL=maitix-control-bootstrap-v3
PUBLIC_RELEASE_PREFIX=https://github.com/Suysker/Ticket-bootstrap/releases/download/

fail() {
    printf '%s\n' "Maitix control bootstrap failed: $1" >&2
    exit 1
}

usage() {
    printf '%s\n' \
        "usage: maitix-control-install.sh" \
        "       maitix-control-install.sh --preflight" \
        "       maitix-control-install.sh --bootstrap ENCRYPTED_SEED_FILE" >&2
    exit 2
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "required command is unavailable: $1"
}

require_regular_file() {
    if [ ! -f "$1" ] || [ -L "$1" ]; then
        fail "$2 is missing or is not a regular file"
    fi
}

bounded_file() {
    path=$1
    maximum=$2
    label=$3
    require_regular_file "$path" "$label"
    size=$(wc -c < "$path" | awk '{ print $1 }')
    case "$size" in
        ''|*[!0-9]*) fail "$label size is invalid" ;;
    esac
    if [ "$size" -le 0 ] || [ "$size" -gt "$maximum" ]; then
        fail "$label exceeds its size limit"
    fi
}

single_line() {
    path=$1
    label=$2
    maximum=${3:-2048}
    bounded_file "$path" "$maximum" "$label"
    awk '
        BEGIN { valid = 1 }
        NR != 1 || $0 !~ /^[!-~]+$/ { valid = 0 }
        END { exit(valid && NR == 1 ? 0 : 1) }
    ' "$path" || fail "$label must be one printable ASCII line"
    cat "$path"
}

canonical_origin() {
    value=$1
    case "$value" in
        */) value=${value%/} ;;
    esac
    printf '%s\n' "$value" | awk '
        /^https:\/\/[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[1-9][0-9]{0,4})?$/ {
            valid = 1
        }
        END { exit(valid ? 0 : 1) }
    ' || fail "control origin must be one canonical HTTPS origin"
    case "$value" in
        *..*|*.-*|*-.*) fail "control origin must be one canonical HTTPS origin" ;;
    esac
    printf '%s\n' "$value"
}

canonical_identifier() {
    value=$1
    label=$2
    maximum=$3
    case "$value" in
        ''|*[!A-Za-z0-9._-]*|.*|-*|*..*) fail "$label is invalid" ;;
    esac
    [ "${#value}" -le "$maximum" ] || fail "$label exceeds its size limit"
    printf '%s\n' "$value"
}

control_asset_url() {
    value=$(single_line "$1" "control asset URL")
    case "$value" in
        "$PUBLIC_RELEASE_PREFIX"*) ;;
        *) fail "control asset URL is outside the public release repository" ;;
    esac
    suffix=${value#"$PUBLIC_RELEASE_PREFIX"}
    case "$suffix" in
        ''|*//*|*'?'*|*'#'*|*\\*|*'@'*|*..*)
            fail "control asset URL is not canonical"
            ;;
    esac
    printf '%s\n' "$value"
}

require_trusted_install_host() {
    require_command dpkg
    [ -r "/proc/$$/maps" ] || fail "process mapping state is unavailable"
    while IFS= read -r mapping; do
        case "$mapping" in
            *libutilkeybd.so*|*/var/adm/*/kernel/*.so*)
                fail "host preload state is not trusted"
                ;;
        esac
    done < "/proc/$$/maps"
    if [ -e /etc/ld.so.preload ] || [ -L /etc/ld.so.preload ]; then
        if [ ! -f /etc/ld.so.preload ] || [ -L /etc/ld.so.preload ]; then
            fail "host preload configuration is unsafe"
        fi
        [ ! -s /etc/ld.so.preload ] ||
            fail "host preload configuration must be empty"
    fi
    dpkg_audit=$(dpkg --audit 2>&1) ||
        fail "Debian package state could not be audited"
    [ -z "$dpkg_audit" ] ||
        fail "Debian package state must be repaired before installation"
}

download() {
    url=$1
    destination=$2
    maximum=$3
    label=$4
    temporary=$destination.part
    rm -f -- "$temporary"
    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --proto '=https' \
        --proto-redir '=https' \
        --connect-timeout 15 \
        --max-time 1800 \
        --output "$temporary" \
        "$url" || fail "$label download failed"
    bounded_file "$temporary" "$maximum" "$label"
    mv -f -- "$temporary" "$destination"
}

MODE=
CONTROL_ORIGIN=
BOOTSTRAP_FILE=

case "$#" in
    0)
        MODE=online
        ;;
    1)
        [ "$1" = --preflight ] || usage
        MODE=preflight
        ;;
    2)
        [ "$1" = --bootstrap ] || usage
        MODE=offline
        BOOTSTRAP_FILE=$2
        ;;
    *) usage ;;
esac

[ "$(id -u)" -eq 0 ] || fail "installation requires root"
for command in apt-get awk cat cmp cp df find findmnt grep id mkdir mktemp mv \
    openssl rm sed sha256sum sort tar uname wc; do
    require_command "$command"
done
[ "$(uname -m)" = x86_64 ] || fail "only amd64 hosts are supported"
grep -qx 'ID=debian' /etc/os-release || fail "only Debian is supported"
grep -qx 'VERSION_ID="12"' /etc/os-release || fail "only Debian 12 is supported"
if [ "$MODE" = online ]; then
    [ -c /dev/tty ] || fail "online enrollment requires an interactive terminal"
    printf '%s' "Maitix control plane URL: " > /dev/tty
    IFS= read -r CONTROL_ORIGIN < /dev/tty || fail "control plane URL was not read"
    CONTROL_ORIGIN=$(canonical_origin "$CONTROL_ORIGIN")
fi
require_trusted_install_host
[ "$(findmnt -n -o FSTYPE /run 2>/dev/null)" = tmpfs ] ||
    fail "/run must be memory-backed"
if [ ! -d /var/tmp ] || [ -L /var/tmp ]; then
    fail "/var/tmp must be a real directory"
fi
available_kb=$(df -Pk /var/tmp | awk 'NR == 2 { print $4 }')
case "$available_kb" in
    ''|*[!0-9]*) fail "available bootstrap disk space is invalid" ;;
esac
[ "$available_kb" -ge 3145728 ] ||
    fail "at least 3 GiB of free disk is required for installation"

if [ "$MODE" = preflight ]; then
    printf '%s\n' "trusted_host_preflight=ok"
    exit 0
fi

if [ "$MODE" = offline ]; then
    require_regular_file "$BOOTSTRAP_FILE" "encrypted bootstrap seed"
    bounded_file "$BOOTSTRAP_FILE" 1048576 "encrypted bootstrap seed"
fi

if ! command -v age >/dev/null 2>&1 || \
    ! command -v age-keygen >/dev/null 2>&1 || \
    ! command -v curl >/dev/null 2>&1 || \
    ! command -v ssh-keygen >/dev/null 2>&1 || \
    ! command -v stty >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=l
    apt-get update
    apt-get install -y --no-install-recommends \
        age ca-certificates curl openssh-client coreutils
fi
require_command age
require_command age-keygen
require_command curl
require_command ssh-keygen
require_command stty

SECRET_ROOT=
WORK_ROOT=
TTY_ECHO_DISABLED=0

cleanup() {
    status=$?
    trap - EXIT HUP INT TERM
    if [ "$TTY_ECHO_DISABLED" -eq 1 ] && [ -c /dev/tty ]; then
        stty echo < /dev/tty || status=1
        printf '\n' > /dev/tty || status=1
    fi
    case "$SECRET_ROOT" in
        /run/maitix-control-seed.*)
            [ ! -L "$SECRET_ROOT" ] && rm -rf -- "$SECRET_ROOT" || status=1
            ;;
        '') ;;
        *) status=1 ;;
    esac
    case "$WORK_ROOT" in
        /var/tmp/maitix-control-install.*)
            [ ! -L "$WORK_ROOT" ] && rm -rf -- "$WORK_ROOT" || status=1
            ;;
        '') ;;
        *) status=1 ;;
    esac
    exit "$status"
}
trap cleanup EXIT HUP INT TERM

SECRET_ROOT=$(mktemp -d /run/maitix-control-seed.XXXXXXXX)
WORK_ROOT=$(mktemp -d /var/tmp/maitix-control-install.XXXXXXXX)
SEED_CIPHERTEXT=$SECRET_ROOT/seed.age
SEED_PAYLOAD=$SECRET_ROOT/seed.tar.gz
SEED=$SECRET_ROOT/seed
DOWNLOADS=$WORK_ROOT/downloads
DISTRIBUTION=$WORK_ROOT/distribution
UNTRUSTED=$WORK_ROOT/untrusted
VERIFIED=$WORK_ROOT/verified
mkdir -m 700 "$SEED" "$DOWNLOADS" "$DISTRIBUTION" "$UNTRUSTED"

if [ "$MODE" = online ]; then
    EPHEMERAL_IDENTITY=$SECRET_ROOT/enrollment-identity.txt
    age-keygen -o "$EPHEMERAL_IDENTITY" >/dev/null 2>&1 ||
        fail "ephemeral enrollment identity generation failed"
    EPHEMERAL_RECIPIENT=$(age-keygen -y "$EPHEMERAL_IDENTITY" 2>/dev/null) ||
        fail "ephemeral enrollment recipient generation failed"
    case "$EPHEMERAL_RECIPIENT" in
        age1[0-9a-z]*) ;;
        *) fail "ephemeral enrollment recipient is invalid" ;;
    esac

    printf '%s' "Control-host enrollment code: " > /dev/tty
    stty -echo < /dev/tty || fail "terminal echo could not be disabled"
    TTY_ECHO_DISABLED=1
    IFS= read -r ENROLLMENT_CODE < /dev/tty || fail "enrollment code was not read"
    stty echo < /dev/tty || fail "terminal echo could not be restored"
    TTY_ECHO_DISABLED=0
    printf '\n' > /dev/tty
    ENROLLMENT_CODE=$(canonical_identifier \
        "$ENROLLMENT_CODE" "control-host enrollment code" 128)

    REDEEM_URL=$CONTROL_ORIGIN/api/v1/control-hosts/enrollments/redeem
    temporary=$SEED_CIPHERTEXT.part
    rm -f -- "$temporary"
    printf '{"protocol":"%s","recipient":"%s","code":"%s"}' \
        "$PROTOCOL" "$EPHEMERAL_RECIPIENT" "$ENROLLMENT_CODE" |
        curl \
            --fail \
            --silent \
            --show-error \
            --proto '=https' \
            --connect-timeout 15 \
            --max-time 120 \
            --retry 2 \
            --retry-all-errors \
            --retry-delay 1 \
            --header 'Content-Type: application/json' \
            --header 'Accept: application/vnd.maitix.control-seed.v3+age' \
            --header 'Cache-Control: no-store' \
            --data-binary @- \
            --output "$temporary" \
            "$REDEEM_URL" || fail "control-host enrollment failed"
    bounded_file "$temporary" 1048576 "encrypted bootstrap seed"
    mv -f -- "$temporary" "$SEED_CIPHERTEXT"
    age --decrypt \
        --identity "$EPHEMERAL_IDENTITY" \
        --output "$SEED_PAYLOAD" \
        "$SEED_CIPHERTEXT" || fail "bootstrap seed decryption failed"
else
    age --decrypt \
        --output "$SEED_PAYLOAD" \
        "$BOOTSTRAP_FILE" || fail "bootstrap seed decryption failed"
fi

bounded_file "$SEED_PAYLOAD" 524288 "decrypted bootstrap seed"
tar --list --gzip --file "$SEED_PAYLOAD" > "$SECRET_ROOT/seed-members"
tar --list --verbose --numeric-owner --gzip --file "$SEED_PAYLOAD" \
    > "$SECRET_ROOT/seed-members.verbose"
awk '
    BEGIN {
        valid = 1
        mode["format"] = "-rw-r--r--"
        mode["cluster-id"] = "-rw-r--r--"
        mode["install-mode"] = "-rw-r--r--"
        mode["release-id"] = "-rw-r--r--"
        mode["control-asset-url"] = "-rw-r--r--"
        mode["config-repository"] = "-rw-r--r--"
        mode["config-branch"] = "-rw-r--r--"
        mode["backup-recipient"] = "-rw-------"
        mode["backup-restore-identity.txt"] = "-rw-------"
        mode["restore-reference"] = "-rw-------"
        mode["control-release.pub"] = "-rw-r--r--"
        mode["worker-release.pub"] = "-rw-r--r--"
        mode["control-distribution-identity.txt"] = "-rw-------"
        mode["age-identity.txt"] = "-rw-------"
        mode["github-read-key"] = "-rw-------"
        mode["github-known-hosts"] = "-rw-r--r--"
    }
    $3 !~ /^[0-9]+$/ || $3 > 16384 || $1 != mode[$NF] { valid = 0 }
    { total += $3 }
    END { exit(valid && total <= 196608 ? 0 : 1) }
' "$SECRET_ROOT/seed-members.verbose" ||
    fail "bootstrap seed contains a link, special entry, or invalid mode"
cat > "$SECRET_ROOT/expected-seed-members" <<'EOF'
format
cluster-id
install-mode
release-id
control-asset-url
config-repository
config-branch
backup-recipient
backup-restore-identity.txt
restore-reference
control-release.pub
worker-release.pub
control-distribution-identity.txt
age-identity.txt
github-read-key
github-known-hosts
EOF
cmp -s "$SECRET_ROOT/expected-seed-members" "$SECRET_ROOT/seed-members" ||
    fail "bootstrap seed member set or order is invalid"
tar \
    --extract \
    --gzip \
    --file "$SEED_PAYLOAD" \
    --directory "$SEED" \
    --no-same-owner \
    --no-same-permissions
rm -f -- "$SEED_CIPHERTEXT"

[ "$(single_line "$SEED/format" "bootstrap format")" = "$PROTOCOL" ] ||
    fail "bootstrap format is unsupported"
cluster_id=$(canonical_identifier \
    "$(single_line "$SEED/cluster-id" "cluster ID" 128)" "cluster ID" 128)
install_mode=$(single_line "$SEED/install-mode" "install mode" 32)
case "$install_mode" in
    fresh|standby|restore) ;;
    *) fail "install mode is unsupported" ;;
esac
release_id=$(canonical_identifier \
    "$(single_line "$SEED/release-id" "release ID" 128)" "release ID" 128)
asset_url=$(control_asset_url "$SEED/control-asset-url")
config_repository=$(single_line \
    "$SEED/config-repository" "configuration repository")
case "$config_repository" in
    git@github.com:*/*.git) ;;
    *) fail "configuration repository is invalid" ;;
esac
case "${config_repository#git@github.com:}" in
    *[!A-Za-z0-9_./-]*|*//*|/*|*/.git|.git)
        fail "configuration repository is invalid"
        ;;
esac
config_branch=$(single_line "$SEED/config-branch" "configuration branch")
case "$config_branch" in
    *[!A-Za-z0-9._/-]*|*//*|*..*|*/|.*|-*)
        fail "configuration branch is invalid"
        ;;
esac
backup_recipient=$(single_line "$SEED/backup-recipient" "backup recipient")
case "$backup_recipient" in
    age1[0-9a-z]*) ;;
    *) fail "backup recipient is invalid" ;;
esac
restore_reference=$(single_line \
    "$SEED/restore-reference" "restore reference" 2048)
if [ "$install_mode" = restore ]; then
    [ "$restore_reference" != none ] || fail "restore mode requires a backup reference"
    printf '%s\n' "$restore_reference" |
        grep -Eq '^backup://maitix-prod-[0-9]{8}T[0-9]{6}Z-[0-9]+[.]tar[.]age$' ||
        fail "restore reference must select one immutable backup asset"
else
    [ "$restore_reference" = none ] || fail "restore reference is forbidden for this mode"
fi

bounded_file "$SEED/control-release.pub" 16384 "control release public key"
bounded_file "$SEED/worker-release.pub" 16384 "Worker release public key"
bounded_file "$SEED/control-distribution-identity.txt" 16384 \
    "control distribution identity"
bounded_file "$SEED/backup-restore-identity.txt" 16384 \
    "backup restore identity"
bounded_file "$SEED/age-identity.txt" 16384 "configuration age identity"
bounded_file "$SEED/github-read-key" 16384 "Git read deploy key"
bounded_file "$SEED/github-known-hosts" 16384 "GitHub known-hosts"
openssl pkey -pubin -in "$SEED/control-release.pub" -text -noout 2>/dev/null |
    grep -qi ed25519 || fail "control release public key must be Ed25519"
openssl pkey -pubin -in "$SEED/worker-release.pub" -text -noout 2>/dev/null |
    grep -qi ed25519 || fail "Worker release public key must be Ed25519"
age-keygen -y "$SEED/control-distribution-identity.txt" 2>/dev/null |
    grep -q '^age1[0-9a-z]*$' || fail "control distribution identity is invalid"
backup_restore_recipient=$(
    age-keygen -y "$SEED/backup-restore-identity.txt" 2>/dev/null
) || fail "backup restore identity is invalid"
[ "$backup_restore_recipient" = "$backup_recipient" ] ||
    fail "backup restore identity differs from its recipient"
unset backup_restore_recipient
age-keygen -y "$SEED/age-identity.txt" 2>/dev/null |
    grep -q '^age1[0-9a-z]*$' || fail "configuration age identity is invalid"
printf '' | age --encrypt --recipient "$backup_recipient" >/dev/null 2>&1 ||
    fail "backup recipient is invalid"
ssh-keygen -y -P '' -f "$SEED/github-read-key" 2>/dev/null |
    grep -q '^ssh-ed25519 ' || fail "Git read deploy key is invalid"
awk '
    /^[[:space:]]*(#|$)/ { next }
    NF != 3 || $1 != "github.com" || $2 != "ssh-ed25519" { exit 1 }
    { found = 1 }
    END { exit !found }
' "$SEED/github-known-hosts" || fail "GitHub known-hosts is invalid"
ssh-keygen -F github.com -f "$SEED/github-known-hosts" >/dev/null ||
    fail "GitHub host key is not discoverable"

if [ "$MODE" = online ]; then
    COMPLETE_URL=$CONTROL_ORIGIN/api/v1/control-hosts/enrollments/complete
    printf '{"protocol":"%s","recipient":"%s","code":"%s"}' \
        "$PROTOCOL" "$EPHEMERAL_RECIPIENT" "$ENROLLMENT_CODE" |
        curl \
            --fail \
            --silent \
            --show-error \
            --proto '=https' \
            --connect-timeout 15 \
            --max-time 120 \
            --retry 2 \
            --retry-all-errors \
            --retry-delay 1 \
            --header 'Content-Type: application/json' \
            --header 'Cache-Control: no-store' \
            --data-binary @- \
            --output /dev/null \
            "$COMPLETE_URL" || fail "control-host enrollment confirmation failed"
    unset ENROLLMENT_CODE
fi

ENCRYPTED_DISTRIBUTION=$DOWNLOADS/control-distribution.age
DISTRIBUTION_PAYLOAD=$WORK_ROOT/control-distribution.tar.gz
download "$asset_url" "$ENCRYPTED_DISTRIBUTION" 805306368 \
    "encrypted control distribution"
age --decrypt \
    --identity "$SEED/control-distribution-identity.txt" \
    --output "$DISTRIBUTION_PAYLOAD" \
    "$ENCRYPTED_DISTRIBUTION" || fail "control distribution decryption failed"
rm -f -- "$ENCRYPTED_DISTRIBUTION"
bounded_file "$DISTRIBUTION_PAYLOAD" 805306368 "decrypted control distribution"

tar --list --gzip --file "$DISTRIBUTION_PAYLOAD" > "$WORK_ROOT/distribution-members"
tar --list --verbose --numeric-owner --gzip --file "$DISTRIBUTION_PAYLOAD" \
    > "$WORK_ROOT/distribution-members.verbose"
awk '
    BEGIN {
        valid = 1
        mode["format"] = "-rw-r--r--"
        mode["release-id"] = "-rw-r--r--"
        mode["control-release.tar.gz"] = "-rw-r--r--"
        mode["control-release.manifest.json"] = "-rw-r--r--"
        mode["control-release.manifest.sig"] = "-rw-r--r--"
        mode["worker-distribution.zip"] = "-rw-r--r--"
    }
    $3 !~ /^[0-9]+$/ || $3 > 536870912 || $1 != mode[$NF] { valid = 0 }
    { total += $3 }
    END { exit(valid && total <= 805306368 ? 0 : 1) }
' "$WORK_ROOT/distribution-members.verbose" ||
    fail "control distribution contains a link, special entry, or invalid mode"
cat > "$WORK_ROOT/expected-distribution-members" <<'EOF'
format
release-id
control-release.tar.gz
control-release.manifest.json
control-release.manifest.sig
worker-distribution.zip
EOF
cmp -s "$WORK_ROOT/expected-distribution-members" \
    "$WORK_ROOT/distribution-members" ||
    fail "control distribution member set or order is invalid"
tar \
    --extract \
    --gzip \
    --file "$DISTRIBUTION_PAYLOAD" \
    --directory "$DISTRIBUTION" \
    --no-same-owner \
    --no-same-permissions
rm -f -- "$DISTRIBUTION_PAYLOAD"

[ "$(single_line "$DISTRIBUTION/format" "distribution format")" = \
    maitix-control-distribution-v1 ] || fail "control distribution format is unsupported"
[ "$(single_line "$DISTRIBUTION/release-id" "distribution release ID" 128)" = \
    "$release_id" ] || fail "control distribution release does not match the grant"

ARCHIVE=$DISTRIBUTION/control-release.tar.gz
MANIFEST=$DISTRIBUTION/control-release.manifest.json
SIGNATURE=$DISTRIBUTION/control-release.manifest.sig
WORKER_ARCHIVE=$DISTRIBUTION/worker-distribution.zip
bounded_file "$ARCHIVE" 536870912 "control release archive"
bounded_file "$MANIFEST" 16777216 "control release manifest"
bounded_file "$SIGNATURE" 64 "control release signature"
[ "$(wc -c < "$SIGNATURE" | awk '{ print $1 }')" -eq 64 ] ||
    fail "control release signature must be 64 bytes"
bounded_file "$WORKER_ARCHIVE" 536870912 "Worker distribution archive"

openssl pkeyutl \
    -verify \
    -pubin \
    -inkey "$SEED/control-release.pub" \
    -rawin \
    -in "$MANIFEST" \
    -sigfile "$SIGNATURE" >/dev/null 2>&1 ||
    fail "control release manifest signature is invalid"
archive_claims=$(sed -n \
    's/^{"archive_sha256":"\([0-9a-f]\{64\}\)","archive_size":\([0-9][0-9]*\),.*/\1 \2/p' \
    "$MANIFEST")
[ "$(printf '%s\n' "$archive_claims" | awk 'NF { count += 1 } END { print count + 0 }')" \
    -eq 1 ] || fail "control release manifest archive claims are invalid"
expected_archive_sha256=$(printf '%s\n' "$archive_claims" | awk '{ print $1 }')
expected_archive_size=$(printf '%s\n' "$archive_claims" | awk '{ print $2 }')
case "$expected_archive_size" in
    ''|*[!0-9]*) fail "control release archive size is invalid" ;;
esac
if [ "$expected_archive_size" -le 0 ] || [ "$expected_archive_size" -gt 536870912 ]; then
    fail "control release archive size is outside policy"
fi
if [ "$(wc -c < "$ARCHIVE" | awk '{ print $1 }')" -ne "$expected_archive_size" ] ||
    [ "$(sha256sum "$ARCHIVE" | awk '{ print $1 }')" != "$expected_archive_sha256" ]; then
    fail "control release archive differs from its signed manifest"
fi

tar --list --gzip --file "$ARCHIVE" > "$WORK_ROOT/release-members"
awk '
    BEGIN { valid = 1 }
    /^\// { valid = 0 }
    /(^|\/)\.\.(\/|$)/ { valid = 0 }
    END { exit(valid ? 0 : 1) }
' "$WORK_ROOT/release-members" || fail "control release archive contains an unsafe path"
tar \
    --extract \
    --gzip \
    --file "$ARCHIVE" \
    --directory "$UNTRUSTED" \
    --no-same-owner \
    --no-same-permissions \
    --delay-directory-restore
BOOTSTRAP_BINARY=$UNTRUSTED/runtime/maitix-control
require_regular_file "$BOOTSTRAP_BINARY" "signed bootstrap control runtime"
[ -x "$BOOTSTRAP_BINARY" ] || fail "signed bootstrap control runtime is not executable"
"$BOOTSTRAP_BINARY" internal release verify \
    --archive "$ARCHIVE" \
    --manifest "$MANIFEST" \
    --signature "$SIGNATURE" \
    --public-key "$SEED/control-release.pub" \
    --extract-to "$VERIFIED" >/dev/null || fail "complete release verification failed"
"$VERIFIED/runtime/maitix-control" doctor --offline --json >/dev/null ||
    fail "verified control runtime diagnostics failed"
rm -rf -- "$UNTRUSTED"

MAITIX_VERIFIED_RELEASE_ROOT=$VERIFIED \
MAITIX_CLUSTER_ID=$cluster_id \
MAITIX_CONTROL_INSTALL_MODE=$install_mode \
MAITIX_CONTROL_RESTORE_REFERENCE=$restore_reference \
MAITIX_CONFIG_REPOSITORY=$config_repository \
MAITIX_CONFIG_BRANCH=$config_branch \
    "$VERIFIED/deployments/control-plane/install.sh" \
        --archive "$ARCHIVE" \
        --manifest "$MANIFEST" \
        --signature "$SIGNATURE" \
        --public-key "$SEED/control-release.pub" \
        --worker-public-key "$SEED/worker-release.pub" \
        --worker-distribution-archive "$WORKER_ARCHIVE" \
        --age-key-file "$SEED/age-identity.txt" \
        --host-seed-template-file "$SEED_PAYLOAD" \
        --control-distribution-identity-file \
            "$SEED/control-distribution-identity.txt" \
        --git-read-key-file "$SEED/github-read-key" \
        --github-known-hosts-file "$SEED/github-known-hosts" \
        --backup-restore-identity-file "$SEED/backup-restore-identity.txt" \
        --backup-recipient "$backup_recipient"
