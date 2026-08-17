# Test hosts

Disposable SSH containers with accounts in deliberately awkward states, so the
integration suite stops depending on anyone's real accounts.

```sh
PORTSIDE_TESTHOST_SSH=truenas Scripts/testhost/provision.sh up
ssh -F ~/.portside-testhost/ssh_config pstest-debian
PORTSIDE_TESTHOST_SSH=truenas Scripts/testhost/provision.sh down
```

`up` is a **reset**: containers are destroyed and rebuilt, so a crashed run
cannot poison the next one.

## Why containers on a shared docker host

They are rebuilt per run, so state never drifts; several distros cost nothing,
which is what makes "sh-portable" a claim we can check rather than hope for; and
there is nothing real inside to damage. The host runs production services, so
the script only ever touches containers named `portside-testhost-*`, never runs
any form of `docker prune`, and **publishes no ports** — the Mac reaches the
containers over the docker bridge through a `ProxyCommand`, so nothing new
listens on that machine. It refuses to run at all unless `PORTSIDE_TESTHOST_SSH`
names the host.

`ProxyJump` is not used because that host sets `AllowTcpForwarding no`, which is
deliberate hardening and not ours to change. `ProxyCommand ... nc` runs a
command instead of requesting a forward, so it needs no such concession.

## The states, and why each exists

| Account | State | Guards |
|---|---|---|
| `pstest_nohome` | passwd entry, home missing | the bootstrap path |
| `pstest_nossh` | home, no `~/.ssh` | the account creates it |
| `pstest_normal` | ordinary | idempotency, retire |
| `pstest_othergroup` | `.ssh` in a non-default group | an unconditional `chown u:u` would move it — found on a real host |
| `pstest_rootssh` | `.ssh` owned by root | must be refused, never chowned |
| `pstest_symlinkssh` | `.ssh` is a symlink | the escalation route |
| `pstest_symlinkkeys` | `authorized_keys` is a symlink | follow, don't replace |
| `pstest_nonewline` | no trailing newline | appending welds onto the last entry |
| `pstest_crlf` | CRLF endings | the line-ending class |
| `pstest_keyincomment` | a key inside a comment *and* an option | reporting these as installed is a silent no-op; deleting them removes real access |
| `pstest_readonly` | `.ssh` read-only | failure path |
| `pstest_nologin` | `/sbin/nologin` shell | the key-only service account |
| `pstest_oddhome` | home outside `/home` | passwd resolution, ancestor walk |
| `pstest_unsafeparent` | home parent world-writable | bootstrap must refuse |
| `pstest_manykeys` | 501 keys | volume |
| **`pstest_strictmodes`** | **key installed, `.ssh` is 0777** | **sshd refuses it — StrictModes** |
| **`pstest_elsewherekeys`** | **key installed, `AuthorizedKeysFile` points elsewhere** | **sshd never reads it** |

The last two are the point. In both, the key is genuinely in `authorized_keys`
and authentication still fails — which is exactly why "the push reported
success" is not proof, and why key rotation has a verify phase at all. Neither
can be produced on a healthy host.

`pstest_nologin` is a third variant worth knowing: the key authenticates and the
session still cannot run, which is the "accepted but no session" branch.

## Cross-distro findings so far

- **debian** gives real `dash` as `/bin/sh` and `mawk`; **alpine** gives busybox
  for both. Far more remote hosts run dash than bash, and busybox is the
  harshest check available.
- **Alpine's sshd refuses an account whose shadow field is `!`** — "not allowed
  because account is locked" — even for public-key auth, where Debian's PAM
  stack does not care. A fresh `useradd` writes exactly that. Provisioning
  unsets it; without that the whole host authenticates nothing and it looks like
  a key problem.
