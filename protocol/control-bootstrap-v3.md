# Maitix Control Bootstrap v3

Status: implementation contract

Protocol identifier: `maitix-control-bootstrap-v3`

## Scope

This protocol installs, restores, or stages one long-lived Maitix control-plane
host. It never enrolls a Worker. Worker installation remains owned by the
running control plane's `/nodes` flow, Worker join-code API, certificate
enrollment, and mTLS Agent channel.

## Public installer modes

The installer has exactly three operator modes:

```text
maitix-control-install.sh --preflight
maitix-control-install.sh --origin HTTPS_ORIGIN --grant GRANT_ID
maitix-control-install.sh --bootstrap ENCRYPTED_SEED_FILE
```

`--preflight` performs host admission without secrets or persistent Maitix
state. The online mode reads the enrollment code from `/dev/tty`. The offline
mode lets `age` read the seed passphrase from the terminal. Unknown arguments
and mixed modes fail closed.

## Online redemption

The installer creates an ephemeral age X25519 identity under root-only `/run`,
then sends one HTTPS request:

```http
POST /api/v1/control-hosts/enrollments/{grant_id}/redeem
Content-Type: application/json
Accept: application/vnd.maitix.control-seed.v3+age
Cache-Control: no-store

{
  "protocol": "maitix-control-bootstrap-v3",
  "recipient": "age1...",
  "code": "..."
}
```

The code is transported only in the request body through curl stdin. It must
not appear in argv, URL, environment, files, response bodies, proxy logs, or
application logs. A successful response is the host seed encrypted directly to
the ephemeral recipient:

```http
HTTP/1.1 200 OK
Content-Type: application/vnd.maitix.control-seed.v3+age
Cache-Control: no-store
```

The grant is bound to cluster, install mode, exact release, exact installer
lock, and one ephemeral recipient. The same recipient may repeat a bounded
network retry until completion; another recipient, an expired/revoked grant,
or a completed grant is rejected. The response contains no bearer token or
plaintext secret.

After decrypting and fully validating the host seed, the installer confirms
the redemption with the same body:

```http
POST /api/v1/control-hosts/enrollments/{grant_id}/complete
Content-Type: application/json
Cache-Control: no-store
```

Completion is idempotent for the bound recipient and returns `204 No Content`.
Only this confirmation moves the grant from `claimed` to `redeemed`, closing
the response-loss ambiguity without making seed redemption replayable after
completion. The enrollment code is cleared immediately after confirmation.

## Host seed

The decrypted seed is a deterministic gzip tar with this exact ordered member
set and no links, directories, devices, or extra members:

```text
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
```

`format` is `maitix-control-bootstrap-v3`. `install-mode` is `fresh`,
`standby`, or `restore`. `restore-reference` is `none` except in restore mode.
Restore mode requires the immutable form
`backup://maitix-prod-YYYYMMDDTHHMMSSZ-PID.tar.age`; mutable aliases such as
`latest` and path-like references are rejected.
The control asset URL is an immutable Release asset under
`https://github.com/Suysker/Ticket-bootstrap/releases/download/`.

The seed contains only material that an empty trusted control host cannot
derive: distribution decryption identity, SOPS age identity, backup restore
identity and matching recipient, read-only Git deploy key, pinned GitHub host
keys, release verification roots, and the exact public release/config
references. It does not contain ticket-account plaintext, Bark plaintext,
database state, a GitHub PAT, or a release signing private key.

## Encrypted control distribution

The public `maitix-control-<release-id>.age` asset decrypts to a deterministic
gzip tar with exactly:

```text
format
release-id
control-release.tar.gz
control-release.manifest.json
control-release.manifest.sig
worker-distribution.zip
```

`format` is `maitix-control-distribution-v1`. The outer age envelope provides
authenticated encryption. The existing Ed25519-signed control manifest remains
the only product release identity and tree manifest; the public layer does not
create a second checksum sidecar or signing format.

## Canonical install handoff

Online and offline seed transports normalize to the same seed directory. The
online path confirms redemption only after the complete seed schema and all
embedded keys have been validated. The public installer then:

1. downloads the immutable encrypted control asset;
2. decrypts it with the seed's distribution identity;
3. verifies the signed control manifest and its one archive digest claim;
4. invokes the verified frozen runtime's complete release verifier;
5. invokes the verified private `deployments/control-plane/install.sh` once.

The internal installer encrypts the complete seed template to the installed
Broker identity and persists the distribution identity separately as a
root-owned, Broker-readable host credential. Only the derived age recipient is
public. This retained identity is the control host's capability to decrypt
later immutable control distributions; the public installer's `/run` copy is
still removed on exit.

The internal installer remains the sole owner of native PostgreSQL, migration,
Git configuration, Worker public distribution import, systemd, backup,
readiness, activation, rollback, and recovery. The public installer does not
duplicate those responsibilities.

## Failure and cleanup

All stages fail closed with a stable non-secret message. Installer-owned secret
state is confined to `/run/maitix-control-seed.*`; downloaded and decrypted
release stages are confined to `/var/tmp/maitix-control-install.*`. One exit
trap removes both allowlisted roots on success, failure, interruption, or
network truncation. No wildcard cleanup may target an unknown path.
