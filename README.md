# Ticket Bootstrap

`Suysker/Ticket-bootstrap` is the public, auditable bootstrap entrypoint for a
Maitix **control-plane server**. It publishes a versioned installer and carries
only opaque, age-encrypted control-plane release assets.

This repository does not install Worker clients. After a control plane is
running, a Super Admin enrolls Windows, Linux, and macOS Workers from the `/nodes`
panel using its short-lived, one-time join commands.

## One-command control-plane installation

The normal command is always the same:

```sh
curl -fLO https://github.com/Suysker/Ticket-bootstrap/releases/download/control-bootstrap-v4.0.0/maitix-control-install.sh && sudo sh ./maitix-control-install.sh
```

1. In the control panel, create the required fresh-host or migration grant and
   copy its one-time enrollment code.
2. Run the command above on the target Debian amd64 server.
3. Enter the authorizing control plane's HTTPS URL when prompted.
4. Enter the one-time enrollment code when prompted; terminal echo is disabled.

The command contains no operator domain, port, grant ID, enrollment code,
private control-release selection, digest, or database setting. State source,
activation mode and the exact private release are bound to the short-lived grant. The
same command is shown under **Settings > Control host installation**. The
installer is downloaded completely before root executes it; do not replace this
flow with `curl | sh`.

Migration grants install the new host in standby. After the full install and
grant acknowledgement succeed, the installer prints one fixed
`activate_command=...`. Run that command on the new host and switch your
external ingress only after it returns `status=ready-for-ingress-switch`.

## Trust boundary

- This repository owns `install.sh`, the Control Bootstrap protocol, public
  tests, and public release assets.
- The private `Suysker/Ticket` repository owns the core source, the internal
  installer, signing policy, configuration, accounts, and database schema.
- A public control release is ciphertext. The installer can open it only after
  receiving an encrypted host seed from an authenticated control plane or an
  offline disaster-recovery bundle.
- The installer does not manage DNS, TLS certificates, firewalls or any
  operator-owned public gateway.

## Operator entrypoints

Offline root bootstrap and disaster recovery use:

```sh
sudo ./maitix-control-install.sh --bootstrap /root/maitix-control-seed.age
```

Run host admission without secrets or persistent changes:

```sh
sudo ./maitix-control-install.sh --preflight
```

The current protocol is documented in
[`protocol/control-bootstrap-v4.md`](protocol/control-bootstrap-v4.md).

## Development

```sh
sh -n install.sh
python3 -m unittest discover -s tests/install -p 'test_*.py'
```

CI additionally runs ShellCheck and the Debian host-admission fixture.
