# Ticket Bootstrap

`Suysker/Ticket-bootstrap` is the public, auditable bootstrap entrypoint for a
Maitix **control-plane server**. It publishes a versioned installer and carries
only opaque, age-encrypted control-plane release assets.

This repository does not install Worker clients. After a control plane is
running, a Super Admin enrolls Windows and Linux Workers from the `/nodes`
panel using its short-lived, one-time join commands.

## One-command control-plane installation

The install command is created under **Settings > Control host installation**
in an already-running Maitix control panel:

**[Create a control-host install command](https://ticket.suysker.xyz:18443/settings)**

1. Select `fresh`, `standby`, or `restore` and create a short-lived grant.
2. Copy the one-line install command and the enrollment code separately.
3. Run the command on the target Debian amd64 server, then enter the enrollment
   code when the terminal prompts for it.

The generated command has this form. This example is deliberately not
executable; the panel replaces every uppercase placeholder with an immutable
release tag, its approved digest, and this installation's grant ID:

```sh
sudo sh -c 'set -eu; umask 077; p=/var/tmp/.maitix-control-install-GRANT_ID_FROM_CONTROL_PANEL.sh; trap "rm -f -- $p" EXIT HUP INT TERM; curl --fail --silent --show-error --location https://github.com/Suysker/Ticket-bootstrap/releases/download/PINNED_BOOTSTRAP_TAG/maitix-control-install.sh -o "$p"; printf "%s  %s\n" PINNED_INSTALLER_SHA256 "$p" | sha256sum -c -; sh "$p" --origin https://ticket.suysker.xyz:18443 --grant GRANT_ID_FROM_CONTROL_PANEL'
```

There is intentionally no permanent, universally valid install command in this
README. Each real command is bound to one audited grant and expires with it.
The enrollment code is never put in the command line, URL, or environment, and
the installer is downloaded completely and verified before root executes it.
Do not replace this flow with `curl | sh`.

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
[`protocol/control-bootstrap-v3.md`](protocol/control-bootstrap-v3.md).

## Development

```sh
sh -n install.sh
python3 -m unittest discover -s tests/install -p 'test_*.py'
```

CI additionally runs ShellCheck and the Debian host-admission fixture.
