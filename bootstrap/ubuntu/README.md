# Ubuntu bootstrap

Abstract: Verify a reachable Ubuntu host before k0sctl provisions Kubernetes.
OrbStack is one provider; an existing Ubuntu host is equally valid.

## Run

Set the SSH target explicitly and run the readiness task:

```sh
FIRMAMENT_SSH_TARGET=tensor@firmament@orb mise run bootstrap:ubuntu
```

OrbStack's built-in SSH uses the `user@machine@orb` target form. Other
developers provide their own SSH host or alias. Optional connection settings
are `FIRMAMENT_SSH_PORT` and `FIRMAMENT_SSH_IDENTITY_FILE`.

The task uses non-interactive SSH with a connection timeout. It does not bypass
host-key verification, install packages, initialize OpenTofu, or change the
host. A failure stops before k0sctl.

## Readiness contract

The selected host must report:

- Ubuntu 26.04;
- arm64/aarch64 or x86_64 architecture;
- systemd as PID 1;
- cgroup v2;
- kernel BTF;
- passwordless sudo;
- `curl` and `systemctl`.

The checks are intentionally read-only. OpenTofu is introduced only in a later
change when a real host gap is observed and its smallest remediation is known.

Tests use the fixture SSH command under `tests/fixtures/`; they do not connect
to a host or mutate a VM.
