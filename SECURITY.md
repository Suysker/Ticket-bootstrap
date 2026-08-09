# Security Policy

Report vulnerabilities privately through GitHub Security Advisories for this
repository. Do not open a public issue containing credentials, enrollment
codes, private release material, host seeds, or installation logs with secrets.

## Supported surface

Only immutable `control-bootstrap-v*` release tags are supported. Commands
generated from a branch, a moving tag, or an unverified installer digest are
outside the production trust boundary.

The public repository is not a Worker enrollment authority. A control-host
grant cannot be used as a Worker join code, and a Worker join code cannot be
redeemed by this installer.

## Expected disclosure content

Include the installer tag, protocol version, stable failure phase, target OS
and architecture, and a minimal reproduction. Remove tokens, seed ciphertext,
private keys, configuration, account data, and database URLs.
