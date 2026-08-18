# Test hosts

Disposable SSH containers with accounts in deliberately awkward states, so the
integration suite stops depending on anyone's real accounts.

```sh
PORTSIDE_TESTHOST_SSH=truenas Scripts/testhost/provision.sh up
export PORTSIDE_TESTHOST_ID=$(cat ~/.portside-testhost/fixture_id)
ssh -F ~/.portside-testhost/ssh_config pstest-debian
PORTSIDE_TESTHOST_SSH=truenas Scripts/testhost/provision.sh down
```

`up` is a **reset**: containers are destroyed and rebuilt, so a crashed run
cannot poison the next one. It also creates a new random fixture ID; export it
as shown above before connecting.

## Why containers on a shared docker host

They are rebuilt per run, so state never drifts; several distros cost nothing,
which is what makes "sh-portable" a claim we can check rather than hope for; and
there is nothing real inside to damage. The host runs production services, so
the script only ever touches containers named `portside-testhost-*`, never runs
any form of `docker prune`, and **publishes no ports** — the Mac reaches the
containers over the docker bridge through a `ProxyCommand`, so nothing new
listens on that machine. It refuses to run at all unless `PORTSIDE_TESTHOST_SSH`
names the host.

Every connection then fails closed unless all three interlocks agree:

- `PORTSIDE_TESTHOST_ID` matches the ID from this local `up`;
- the container holds that same ID in a root-owned, mode-0400 marker; and
- the container's freshly generated Ed25519 host key matches `known_hosts`.

This makes a stale config, a reused container name, or a missing environment
opt-in an error before an integration test can authenticate.

`ProxyJump` is not used because that host sets `AllowTcpForwarding no`, which is
deliberate hardening and not ours to change. `ProxyCommand ... nc` runs a
command instead of requesting a forward, so it needs no such concession.

## The states, and why each exists

| Account | State | Guards |
|---|---|---|
| `pstest_nohome` | passwd entry, home missing | must be *reported*, never created — Portside stopped creating homes in 0.23.2 |
| `pstest_nossh` | home, no `~/.ssh` | the account creates it |
| `pstest_normal` | ordinary | idempotency, retire |
| `pstest_othergroup` | `.ssh` in a non-default group | an unconditional `chown u:u` would move it — found on a real host |
| `pstest_rootssh` | `.ssh` owned by root | must be refused, never chowned |
| `pstest_symlinkssh` | `.ssh` is a symlink | the old root-era escalation route; now harmless, kept as a regression state |
| `pstest_symlinkkeys` | `authorized_keys` is a symlink | follow, don't replace |
| `pstest_nonewline` | no trailing newline | appending welds onto the last entry |
| `pstest_crlf` | CRLF endings | the line-ending class |
| `pstest_keyincomment` | a key inside a comment *and* an option | reporting these as installed is a silent no-op; deleting them removes real access |
| `pstest_readonly` | `.ssh` read-only | failure path |
| `pstest_nologin` | `/sbin/nologin` shell | the key-only service account |
| `pstest_oddhome` | home outside `/home` | `sudo -H` must resolve it; no `/home/<user>` assumption anywhere |
| `pstest_unsafeparent` | home parent world-writable | historical: the case that proved shell-only bootstrap unsound |
| `pstest_manykeys` | 501 keys | volume |
| **`pstest_strictmodes`** | **key installed, `.ssh` is 0777** | **sshd refuses it — StrictModes** |
| **`pstest_elsewherekeys`** | **key installed, `AuthorizedKeysFile` points elsewhere** | **sshd never reads it** |

The last two are the point. In both, the key is genuinely in `authorized_keys`
and authentication still fails — which is exactly why "the push reported
success" is not proof, and why key rotation has a verify phase at all. Neither
can be produced on a healthy host.

`pstest_nologin` is a third variant worth knowing: the key authenticates and the
session still cannot run, which is the "accepted but no session" branch.

## Login shells are a separate portability boundary

`ssh host '<command>'` is parsed by the **SSH login account's shell**, not by
`sh` — and not by the *target* account's shell either. Copy-to-account involves
two users, and saying "the target user's shell" hides which one decides. That is a different question from "which `/bin/sh` does this host have",
and nothing exercised it until `pstest_zsh`, `pstest_tcsh` and `pstest_fish`
existed.

Sending the real key-push script the way ssh sends it:

| login shell | result |
|---|---|
| dash / sh | installs |
| zsh | installs |
| **tcsh** | `else: endif not found.` |
| **fish** | parse error |

So the push path does not work when the **login** account's shell is tcsh or
fish. Both forms are affected: the raw script above, and the cross-account
wrapper, which fails earlier still — tcsh answers `Illegal variable name` and
fish `Unsupported use of '='` at the `__pk=` assignment, before `sudo` is ever
reached. Pre-existing in 0.23.0 and 0.23.1, and it fails *before* the result
marker, so it reports failure rather than falsely claiming a key was installed.

Measurements toward a fix, so the next attempt starts from evidence:

- `echo <base64>|base64 -d|sh` parses correctly in **all four** shells. Base64's
  alphabet contains no shell metacharacters, and every shell here understands a
  pipeline, so this is a viable delivery form.
- Adding `2>/dev/null` breaks it: tcsh answers `Ambiguous output redirect`. So
  the usual `base64 -d 2>/dev/null || base64 -D` fallback for BSD cannot live in
  the outer command.
- A pipeline gives the final `sh` its stdin **from the pipe**, and that is
  exactly where `sudo -S` currently reads the password. So the pipeline form
  works for the login-user path and breaks the cross-account path, which needs a
  different answer for password delivery.
- `sh -c "$(...)"` is not an option: `$(...)` is not portable to csh, and fish
  spells command substitution differently again.

The shape that does work, tested by Codex through real tcsh, fish and zsh login
accounts on the Debian fixture, keeps the outer command fixed and passes the
payload as an argument:

```sh
/bin/sh -c '{ printf %s "$1" | base64 -d 2>/dev/null || printf %s "$1" | base64 -D 2>/dev/null; } | /bin/sh' portside BASE64
```

The account form puts the same fixed decoder *after* `sudo`, which resolves the
stdin conflict: `sudo -S` keeps ssh's stdin for the password while the inner
pipeline supplies the script's stdin. Before landing it: password-required and
NOPASSWD sudo, hostile account and key data, Debian/Alpine/macOS `base64`
variants, and all four login shells.

## Cross-distro findings so far

- **debian** gives real `dash` as `/bin/sh` and `mawk`; **alpine** gives busybox
  for both. Far more remote hosts run dash than bash, and busybox is the
  harshest check available.
- **Alpine's sshd refuses an account whose shadow field is `!`** — "not allowed
  because account is locked" — even for public-key auth, where Debian's PAM
  stack does not care. A fresh `useradd` writes exactly that. Provisioning
  unsets it; without that the whole host authenticates nothing and it looks like
  a key problem.
