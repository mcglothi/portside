#!/bin/sh
# Stand up disposable SSH hosts with accounts in deliberately awkward states,
# so the integration suite stops depending on anybody's real accounts.
#
# Every state below exists because Portside was burned by it or has a guard for
# it. The two that matter most are 16 and 17: a key that installs correctly and
# still does not authenticate. That is the case the whole verify phase exists
# for, and it cannot be produced on a healthy host.
#
# Usage:
#   PORTSIDE_TESTHOST_SSH=truenas Scripts/testhost/provision.sh up
#   PORTSIDE_TESTHOST_SSH=truenas Scripts/testhost/provision.sh down
#   PORTSIDE_TESTHOST_SSH=truenas Scripts/testhost/provision.sh status
#
# `up` is a RESET, not a top-up: containers are destroyed and rebuilt, so a
# crashed run cannot poison the next one. State is never carried forward.
#
# ## Safety
#
# The docker host is shared with real services, so this script:
#   - only ever touches containers whose names begin with portside-testhost-
#   - never runs `docker prune` in any form
#   - publishes NO ports; the Mac reaches containers over the docker bridge
#     through a ProxyCommand, so nothing new listens on the host
#   - refuses to run unless PORTSIDE_TESTHOST_SSH names the docker host
set -eu

PREFIX=portside-testhost
IMAGE_PREFIX=portside-testhost
DISTROS="${PORTSIDE_TESTHOST_DISTROS:-debian alpine}"
OUT_DIR="${PORTSIDE_TESTHOST_DIR:-$HOME/.portside-testhost}"

if [ -z "${PORTSIDE_TESTHOST_SSH:-}" ]; then
    echo "PORTSIDE_TESTHOST_SSH must name the docker host (e.g. truenas)" >&2
    exit 2
fi
HOST=$PORTSIDE_TESTHOST_SSH

# Every docker call goes through here. `sudo -n` because the TrueNAS ssh user is
# not in the docker group; -n so a missing sudo rule fails instead of hanging.
d() {
    ssh -o BatchMode=yes "$HOST" "sudo -n docker $*"
}

# Runs a script inside a container, fed on stdin so quoting survives.
in_container() {
    ssh -o BatchMode=yes "$HOST" "sudo -n docker exec -i $1 /bin/sh -s"
}

container_name() { echo "$PREFIX-$1"; }

# ---------------------------------------------------------------- images

build_image() {
    distro=$1
    case "$distro" in
    debian)
        # /bin/sh is dash here, which is the portability target — far more
        # remote hosts run dash as /bin/sh than run bash.
        cat <<'DOCKERFILE'
FROM debian:12
RUN apt-get -qq update \
 && DEBIAN_FRONTEND=noninteractive apt-get -qq install -y openssh-server sudo \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /run/sshd && ssh-keygen -A
CMD ["/usr/sbin/sshd", "-D", "-e"]
DOCKERFILE
        ;;
    alpine)
        # busybox sh and busybox coreutils — the harshest portability check we
        # have, and the closest thing to an appliance or a container host.
        cat <<'DOCKERFILE'
FROM alpine:3.20
RUN apk add --no-cache openssh-server sudo shadow \
 && ssh-keygen -A
CMD ["/usr/sbin/sshd", "-D", "-e"]
DOCKERFILE
        ;;
    rocky)
        cat <<'DOCKERFILE'
FROM rockylinux:9
RUN dnf -y -q install openssh-server sudo shadow-utils \
 && ssh-keygen -A
CMD ["/usr/sbin/sshd", "-D", "-e"]
DOCKERFILE
        ;;
    *)
        echo "unknown distro: $distro" >&2
        exit 2
        ;;
    esac
}

# ---------------------------------------------------------------- accounts
#
# Each account is one state. The name says what is wrong with it, because a
# failing test naming pstest_root_owned_ssh explains itself.

provision_accounts() {
    cat <<'PROVISION'
set -eu
PUB=$(cat /tmp/portside-testhost.pub)

mk() {  # mk <user> [shell]
    if command -v useradd >/dev/null 2>&1; then
        useradd -m -s "${2:-/bin/sh}" "$1" 2>/dev/null || true
    else
        adduser -D -s "${2:-/bin/sh}" "$1" 2>/dev/null || true
    fi
    # Leave the account passwordless-but-not-LOCKED. A fresh useradd writes `!`
    # into the shadow field, and Alpine's sshd refuses a locked account even for
    # public-key auth ("not allowed because account is locked") where Debian's
    # PAM stack does not care. Without this the whole Alpine host authenticates
    # nothing, which looks like a key problem and is not.
    usermod -p '*' "$1" 2>/dev/null || true
}

authorize() {  # authorize <user> — the ordinary, correct arrangement
    u=$1; h=$(getent passwd "$u" | cut -d: -f6)
    mkdir -p "$h/.ssh"; chmod 700 "$h/.ssh"
    printf '%s\n' "$PUB" > "$h/.ssh/authorized_keys"
    chmod 600 "$h/.ssh/authorized_keys"
    chown -R "$u" "$h/.ssh"
}

# 1. passwd entry, home does NOT exist — the bootstrap path.
mk pstest_nohome
rm -rf /home/pstest_nohome

# 2. home exists, no ~/.ssh — the account must create it itself.
mk pstest_nossh

# 3. the ordinary case: home, .ssh, a populated authorized_keys.
mk pstest_normal
authorize pstest_normal

# 4. ~/.ssh owned with a NON-DEFAULT group. Found on a real host; an
#    unconditional `chown u:u` would silently move it.
mk pstest_othergroup
groupadd -f pstest_agents 2>/dev/null || addgroup pstest_agents 2>/dev/null || true
authorize pstest_othergroup
chown -R pstest_othergroup:pstest_agents /home/pstest_othergroup/.ssh

# 5. ~/.ssh owned by ROOT — must be refused, never chowned out from under.
mk pstest_rootssh
mkdir -p /home/pstest_rootssh/.ssh
chmod 700 /home/pstest_rootssh/.ssh
chown root:root /home/pstest_rootssh/.ssh

# 6. ~/.ssh is a SYMLINK the account controls — the escalation route.
mk pstest_symlinkssh
rm -rf /home/pstest_symlinkssh/.ssh
mkdir -p /tmp/pstest_elsewhere
ln -s /tmp/pstest_elsewhere /home/pstest_symlinkssh/.ssh

# 7. authorized_keys is a symlink to a real file — follow it, don't replace it.
mk pstest_symlinkkeys
h=/home/pstest_symlinkkeys
mkdir -p "$h/.ssh" "$h/real"
printf '%s\n' "$PUB" > "$h/real/keys"
ln -s "$h/real/keys" "$h/.ssh/authorized_keys"
chmod 700 "$h/.ssh"; chown -R pstest_symlinkkeys "$h/.ssh" "$h/real"

# 8. authorized_keys with NO trailing newline — appending welds onto the last
#    entry and breaks the host's existing access.
mk pstest_nonewline
h=/home/pstest_nonewline
mkdir -p "$h/.ssh"; chmod 700 "$h/.ssh"
printf 'ssh-rsa AAAAEXISTINGKEYNONEWLINE existing@host' > "$h/.ssh/authorized_keys"
chmod 600 "$h/.ssh/authorized_keys"; chown -R pstest_nonewline "$h/.ssh"

# 9. CRLF line endings.
mk pstest_crlf
h=/home/pstest_crlf
mkdir -p "$h/.ssh"; chmod 700 "$h/.ssh"
printf 'ssh-rsa AAAAEXISTINGCRLF existing@host\r\n' > "$h/.ssh/authorized_keys"
chmod 600 "$h/.ssh/authorized_keys"; chown -R pstest_crlf "$h/.ssh"

# 10. A key quoted inside another key's COMMENT and inside an OPTION. Reporting
#     these as installed is a silent no-op; deleting them removes real access.
mk pstest_keyincomment
h=/home/pstest_keyincomment
mkdir -p "$h/.ssh"; chmod 700 "$h/.ssh"
{
  printf 'ssh-rsa AAAAREALKEYHERE note %s\n' "$PUB"
  printf 'command="echo %s",no-pty ssh-rsa AAAAANOTHERREAL real\n' "$PUB"
} > "$h/.ssh/authorized_keys"
chmod 600 "$h/.ssh/authorized_keys"; chown -R pstest_keyincomment "$h/.ssh"

# 11. ~/.ssh read-only — the account cannot write its own file.
mk pstest_readonly
h=/home/pstest_readonly
mkdir -p "$h/.ssh"
chown -R pstest_readonly "$h/.ssh"
chmod 500 "$h/.ssh"

# 12. nologin shell — the key-only service account this feature exists for.
mk pstest_nologin /sbin/nologin
authorize pstest_nologin

# 13. home on a NON-STANDARD path — passwd resolution, and the ancestor walk.
mkdir -p /srv/apps
mk pstest_oddhome
usermod -d /srv/apps/oddhome pstest_oddhome 2>/dev/null || true
mkdir -p /srv/apps/oddhome
chown pstest_oddhome /srv/apps/oddhome

# 14. home whose PARENT is group/world-writable — bootstrap must refuse rather
#     than create through a directory an unprivileged account can swap.
mkdir -p /srv/unsafe
chmod 777 /srv/unsafe
mk pstest_unsafeparent
usermod -d /srv/unsafe/pstest_unsafeparent pstest_unsafeparent 2>/dev/null || true
rm -rf /srv/unsafe/pstest_unsafeparent

# 15. a large authorized_keys.
mk pstest_manykeys
h=/home/pstest_manykeys
mkdir -p "$h/.ssh"; chmod 700 "$h/.ssh"
i=0
: > "$h/.ssh/authorized_keys"
while [ $i -lt 500 ]; do
  printf 'ssh-ed25519 AAAAFILLER%s filler%s@host\n' "$i" "$i" >> "$h/.ssh/authorized_keys"
  i=$((i + 1))
done
printf '%s\n' "$PUB" >> "$h/.ssh/authorized_keys"
chmod 600 "$h/.ssh/authorized_keys"; chown -R pstest_manykeys "$h/.ssh"

# 16. THE ONE THAT MATTERS. The key is installed correctly and sshd still
#     refuses it, because StrictModes rejects a group-writable ~/.ssh. "The
#     push reported success" is not proof, and this is what proves that.
mk pstest_strictmodes
authorize pstest_strictmodes
chmod 777 /home/pstest_strictmodes/.ssh

# 17. AuthorizedKeysFile points somewhere else entirely, so a key written to
#     ~/.ssh/authorized_keys is never consulted.
mk pstest_elsewherekeys
authorize pstest_elsewherekeys
mkdir -p /etc/ssh/authorized
: > /etc/ssh/authorized/pstest_elsewherekeys
chmod 600 /etc/ssh/authorized/pstest_elsewherekeys
if ! grep -q "pstest_elsewherekeys" /etc/ssh/sshd_config; then
  printf '\nMatch User pstest_elsewherekeys\n    AuthorizedKeysFile /etc/ssh/authorized/%%u\n' \
      >> /etc/ssh/sshd_config
fi

# A login account the harness itself uses, with passwordless sudo, standing in
# for the operator's own account.
mk pstest_operator /bin/sh
authorize pstest_operator
echo 'pstest_operator ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/pstest_operator
chmod 440 /etc/sudoers.d/pstest_operator

# Restart sshd so the Match block above takes effect.
kill -HUP 1 2>/dev/null || true
echo PROVISIONED
PROVISION
}

# ---------------------------------------------------------------- commands

cmd_up() {
    keyfile="$OUT_DIR/id_testhost"
    mkdir -p "$OUT_DIR"
    if [ ! -f "$keyfile" ]; then
        ssh-keygen -t ed25519 -f "$keyfile" -N '' -q -C portside-testhost
    fi

    for distro in $DISTROS; do
        name=$(container_name "$distro")
        echo "==> $name"

        build_image "$distro" | ssh -o BatchMode=yes "$HOST" \
            "sudo -n docker build -q -t $IMAGE_PREFIX:$distro -f - . >/dev/null" || {
            echo "    image build failed" >&2; exit 1; }

        # Destroy and rebuild: `up` is a reset.
        d rm -f "$name" >/dev/null 2>&1 || true
        d run -d --name "$name" --memory 512m --cpus 1 --restart no \
            "$IMAGE_PREFIX:$distro" >/dev/null

        ssh -o BatchMode=yes "$HOST" \
            "sudo -n docker exec -i $name /bin/sh -c 'cat > /tmp/portside-testhost.pub'" \
            < "$keyfile.pub"
        provision_accounts | in_container "$name" | tail -1

        ip=$(d inspect -f "'{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'" "$name")
        echo "    $(echo "$ip" | tr -d '\r')"
    done

    write_ssh_config "$keyfile"
    echo
    echo "ssh config: $OUT_DIR/ssh_config"
    echo "try: ssh -F $OUT_DIR/ssh_config pstest-debian"
}

# Written from the containers that are actually up, not from $DISTROS —
# otherwise `up` with a subset silently drops entries for the others and their
# host aliases stop resolving.
write_ssh_config() {
    keyfile=$1
    : > "$OUT_DIR/ssh_config"
    running=$(d ps --filter "name=$PREFIX" --format "'{{.Names}}'" | tr -d '\r')
    for name in $running; do
        distro=${name#"$PREFIX-"}
        ip=$(d inspect -f "'{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'" "$name" | tr -d '\r')
        [ -n "$ip" ] || continue
        # No published ports: reach the bridge through a command on the docker
        # host. ProxyJump would need AllowTcpForwarding, which that host
        # deliberately disables.
        cat >> "$OUT_DIR/ssh_config" <<EOF
Host pstest-$distro
    HostName $ip
    User pstest_operator
    IdentityFile $keyfile
    IdentitiesOnly yes
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
    ProxyCommand ssh -o BatchMode=yes $HOST nc %h %p

EOF
    done
}

cmd_down() {
    for distro in $DISTROS; do
        name=$(container_name "$distro")
        d rm -f "$name" >/dev/null 2>&1 && echo "removed $name" || echo "$name not running"
    done
}

cmd_status() {
    # Deliberately filtered to our own prefix — this host runs real services.
    d ps -a --filter "name=$PREFIX" --format "'{{.Names}}\t{{.Status}}'" || true
}

case "${1:-}" in
up) cmd_up ;;
down) cmd_down ;;
status) cmd_status ;;
*)
    echo "usage: PORTSIDE_TESTHOST_SSH=<host> $0 {up|down|status}" >&2
    exit 2
    ;;
esac
