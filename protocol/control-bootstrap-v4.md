# Maitix Control Bootstrap v4

Status: implementation contract

Protocol identifier: `maitix-control-bootstrap-v4`

## Scope

This protocol installs, restores, or stages one long-lived Maitix control-plane
host. It never enrolls a Worker. Worker installation remains owned by the
running control plane's `/nodes` flow, Worker join-code API, certificate
enrollment, and mTLS Agent channel.

## Public installer modes

The installer has exactly three operator modes:

```text
maitix-control-install.sh
maitix-control-install.sh --preflight
maitix-control-install.sh --bootstrap ENCRYPTED_SEED_FILE
```

`--preflight` performs host admission without secrets or persistent Maitix
state. The no-argument online mode reads the authorizing control plane's
canonical HTTPS origin and then the enrollment code from `/dev/tty`; code echo
is disabled. The offline mode lets `age` read the seed passphrase from the
terminal. Unknown arguments and mixed modes fail closed. Normal installation
never receives origin, port, grant ID, state source, activation mode, release,
digest, or database settings through argv.

## Online redemption

The installer creates an ephemeral age X25519 identity under root-only `/run`,
then sends one HTTPS request:

```http
POST /api/v1/control-hosts/enrollments/redeem
Content-Type: application/json
Accept: application/vnd.maitix.control-seed.v4+age
Cache-Control: no-store

{
  "protocol": "maitix-control-bootstrap-v4",
  "recipient": "age1...",
  "code": "..."
}
```

The service computes the code's keyed HMAC digest and locks the matching grant.
The code is transported only in the request body through curl stdin and never
appears in argv, URL, environment, files, response bodies, proxy logs, or
application logs. A successful response is the host seed encrypted directly to
the ephemeral recipient:

```http
HTTP/1.1 200 OK
Content-Type: application/vnd.maitix.control-seed.v4+age
Cache-Control: no-store
```

The grant is bound to cluster, state source, activation mode, exact release,
exact installer lock, and one ephemeral recipient. The same recipient may
repeat a bounded network retry until completion; another recipient, an
expired/revoked grant, or a completed grant is rejected.

Only after the signed private install transaction returns success does the
installer confirm redemption with the same body at
`POST /api/v1/control-hosts/enrollments/complete`. Completion is idempotent for
the bound recipient and returns `204 No Content`.

For `backup + standby`, successful completion prints exactly one fixed local
activation command. The command is not printed before the online completion
acknowledgement succeeds. It starts only the installed Maitix units, verifies
that every process uses the current signed release, waits for loopback
readiness, runs the canonical installation verifier, and atomically promotes
the local lifecycle state. Any failed first activation returns all Maitix units
to standby. Only a terminal `status=ready-for-ingress-switch` from that command
permits the operator to switch their external ingress; this public installer
does not manage DNS, TLS, or gateway configuration.

## Host seed

The decrypted seed is a deterministic gzip tar with this exact ordered member
set and no links, directories, devices, or extra members:

```text
format
cluster-id
state-source
activation-mode
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

`format` is `maitix-control-bootstrap-v4`. `state-source` is `fresh` or
`backup`; `activation-mode` is independently `active` or `standby`.
`restore-reference` is `none` for a fresh source and is an immutable
`backup://maitix-prod-YYYYMMDDTHHMMSSZ-PID.tar.age` reference for a backup
source. Mutable aliases and path-like references are rejected. A control-plane
migration is always `backup + standby`; disaster recovery may use
`backup + active`.

The control asset URL is an immutable Release asset under
`https://github.com/Suysker/Ticket-bootstrap/releases/download/`. The seed
contains only material an empty trusted control host cannot derive. It does not
contain ticket-account plaintext, Bark plaintext, database state, a GitHub PAT,
or a release signing private key.

## Encrypted control distribution

The public `maitix-control-<release-id>.age` asset decrypts to a deterministic
gzip tar containing exactly `format`, `release-id`,
`control-release.tar.gz`, `control-release.manifest.json`,
`control-release.manifest.sig`, and `worker-distribution.zip`.
`format` remains `maitix-control-distribution-v1`; the signed control manifest
is the only product release identity.

## Canonical install handoff

Online and offline seed transports normalize to the same seed directory. The
public installer validates the complete seed, decrypts the immutable control
asset, verifies the signed release, invokes the verified private
`deployments/control-plane/install.sh` exactly once, and confirms online
redemption only after that transaction succeeds. The
private installer remains the sole owner of PostgreSQL, Git configuration,
systemd, backup, activation, rollback, and recovery.

## Failure and cleanup

All stages fail closed with a stable non-secret message. Installer-owned secret
state is confined to `/run/maitix-control-seed.*`; downloaded and decrypted
release stages are confined to `/var/tmp/maitix-control-install.*`. One exit
trap removes both allowlisted roots on success, failure, interruption, or
network truncation. No wildcard cleanup may target an unknown path.
