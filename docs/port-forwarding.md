# Port forwarding — what it does, and what it doesn't

Portside's saved port forwards are **best-effort**. They start a tunnel, watch
the process, and tell you when it exits. They do not supervise it.

This page says plainly what that means, because the gap between "the status
says running" and "the tunnel works" is not obvious and is the one that costs
you an afternoon.

## What a forward actually is

One `ssh -N` process per saved forward — no shell, forwarding only — launched
through whichever host in your library the forward is attached to, with that
host's own credentials and `~/.ssh/config` settings.

```
ssh -N -o ExitOnForwardFailure=yes -o ConnectTimeout=15 \
    -L 8080:internal:80  jump-host
```

`ExitOnForwardFailure=yes` matters: if the local bind fails — the port is
already taken — ssh exits immediately rather than sitting there connected but
forwarding nothing.

## What the status means

| Status | What it actually tells you |
|---|---|
| **Connecting** | the process has been launched |
| **Running** | the process was still alive two seconds later |
| **Failed** | the process exited; the message is ssh's own last words |
| **Stopped** | you stopped it |

**"Running" means the ssh process is alive. It does not mean traffic flows.**

That distinction is the whole point of this page. Two seconds of survival is
good evidence the bind succeeded, because a bad bind exits well inside that
window. It is no evidence at all about anything that happens afterwards.

## What is not supervised

### The tunnel is not health-checked

Nothing connects to the local port to confirm it still reaches the far side.
If the remote service dies, the route changes, or a firewall starts dropping
the flow, the status stays **Running**.

### There is no keepalive unless you configure one

Portside does not set `ServerAliveInterval`. Without it, ssh has no reason to
notice a connection that has gone away silently — a laptop that slept, a NAT
table that expired, a VPN that dropped. The TCP connection is half-open, the
process is alive, the status says Running, and connections to the local port
hang instead of failing.

If you rely on tunnels, put this in `~/.ssh/config` for the hosts you forward
through:

```
Host jump-host
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

That makes ssh notice within about 90 seconds and exit, which Portside *will*
report as Failed. Portside deliberately doesn't impose these — they're your
connection settings, and the whole design leans on your existing OpenSSH
configuration rather than second-guessing it.

### Sleep and network changes are not recovered from

Close the lid, move between networks, come back: any tunnel that died stays
dead, and any tunnel that half-died still shows Running. Nothing restarts, and
nothing re-checks. Check the status — and preferably the port — before relying
on a tunnel you started before lunch.

### Nothing restarts automatically

A tunnel that exits stays exited until you start it again. This is deliberate
rather than merely unbuilt: automatic retry against a host requiring a password
or MFA means repeated failed authentications, and enough of those lock the
account. A tunnel that gives up loudly is better than one that quietly locks
you out of the estate.

**Launch at startup** is not an exception — it starts a forward once when
Portside launches. It doesn't keep it up.

## What *is* handled properly

- **Stopping actually stops.** A tunnel that ignores `SIGTERM` — wedged
  mid-handshake, or blocked on a stuck `ProxyCommand` — is killed by process
  group shortly after, which also takes any `ProxyCommand` child with it.
  Without that the local port stays bound by something Portside believes it
  stopped, and the next start fails with "address already in use".
- **Quitting stops them all**, synchronously, so no tunnel outlives Portside
  still holding a port.
- **Credentials resolve exactly as a session's would** — including a host that
  gets its password from a credential profile, which matters most for
  launch-at-startup forwards, since those run before any session exists.
- **Output is drained continuously**, so a chatty `ProxyCommand` or a relayed
  banner can't fill the pipe buffer and wedge the tunnel.

## Binding beyond loopback

A forward's bind address is yours to choose, and Portside does not warn about
it. Two cases are worth knowing:

- **`0.0.0.0` or a LAN address on a `-L` forward** exposes that port to
  everything that can reach your Mac. On an office or hotel network, that is
  more than you think.
- **A `-R` forward** opens a listening port **on the remote host**, subject to
  its `GatewayPorts` setting. You are punching a hole in something you may not
  own.

Neither is wrong — they're both legitimate and occasionally exactly what you
want. They are simply not flagged, so the decision is entirely yours.

## If this isn't good enough for what you're doing

For a tunnel that genuinely has to stay up, use a supervisor built for it —
`autossh`, a `launchd` job, or `systemd` on the far side. Portside's forwards
are a convenience for the ones you bring up alongside a session and take down
when you're done with it.

---

*Status: this describes 0.20. Supervision — health checks, sleep/wake recovery,
restart with backoff, a non-loopback warning — is [tracked as a 1.0
gate](road-to-1.0.md) and is not built. If you use tunnels heavily, what you
expect after a lid closes is genuinely useful to know; it is the missing input,
not the missing code.*
