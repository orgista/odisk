# Security policy

## Supported versions

Only the latest release and the `main` branch get security fixes.

## Reporting a vulnerability

Please don't report vulnerabilities in public issues. Report them privately through
[private vulnerability reporting](https://github.com/orgista/odisk/security/advisories/new), or email **support@orgista.com**.

Include the affected version or file, steps to reproduce, and the impact. You should get a reply within 7 days.
Fixes ship within 7 days of a confirmed report, and the advisory is published with credit unless you'd rather
stay anonymous.

## Verifying a release

Every file on the [Releases](https://github.com/orgista/odisk/releases) page comes with a `SHA256SUMS` file and a
GitHub build attestation. To check a download:

```sh
shasum -a 256 -c SHA256SUMS --ignore-missing
gh attestation verify oDisk-1.2.3.dmg --repo orgista/odisk
```

The attestation proves the file is the one published in this repository's release. Builds are made and signed
on the maintainer's build Mac, not on GitHub's runners.
