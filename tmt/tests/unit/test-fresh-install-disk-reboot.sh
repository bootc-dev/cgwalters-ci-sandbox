#!/usr/bin/env bash
# Synthetic-only coverage for the fresh-install reboot helper. No host virsh,
# libvirt daemon, VM, or resource is contacted.
set -euo pipefail

helper=${1:?path to fresh-install-disk-reboot.sh}
tmp=$(mktemp -d)
cleanup() {
    local rc=$?
    if test -n "${socket_pid:-}"; then
        kill "$socket_pid" 2>/dev/null || true
        wait "$socket_pid" 2>/dev/null || true
    fi
    if test "$rc" != 0 && test "${KEEP_TEST_TMP:-0}" = 1; then
        printf 'retained test fixture: %s\n' "$tmp" >&2
    else
        rm -rf "$tmp"
    fi
    return "$rc"
}
trap cleanup EXIT
mkdir -p "$tmp/bin"
initial="$tmp/initial.raw"
volume="$tmp/volume.raw"
virsh="$tmp/bin/virsh-fake"
socket="$tmp/libvirt.sock"
other_socket="$tmp/other-libvirt.sock"
touch "$initial" "$volume"
uuid=00000000-0000-0000-0000-000000000000
pool_uuid=11111111-1111-1111-1111-111111111111
uri="qemu+unix:///session?socket=$socket"

cat >"$virsh" <<'EOF'
#!/bin/bash
set -euo pipefail
raw_args=$*
printf '%s\n' "$raw_args" >>"$VIRSH_CALLS"
if test "$1" != --connect || test "$2" != "$MOCK_URI"; then
    exit 98
fi
shift 2
case "$1" in
    domuuid) printf '%s\n' "$MOCK_DOMAIN_UUID" ;;
    pool-uuid) printf '%s\n' "$MOCK_POOL_UUID" ;;
    vol-path) printf '%s\n' "$MOCK_VOLUME" ;;
    vol-key) printf '%s\n' "$MOCK_VOLUME" ;;
    domblklist)
        printf 'file disk vda %s\n' "$MOCK_INITIAL"
        if test "${MOCK_MISSING_VDB:-false}" != true; then
            printf 'file disk vdb %s\n' "$MOCK_VOLUME"
        fi
        ;;
    domid) printf '%s\n' "$MOCK_DOMAIN_ID" ;;
    domstate)
        if test -e "$MOCK_SHUTDOWN_MARKER"; then
            printf '%s\n' 'shut off'
        else
            printf '%s\n' "$MOCK_STATE"
        fi
        ;;
    shutdown) touch "$MOCK_SHUTDOWN_MARKER" ;;
    detach-disk|start) printf 'MUTATING %s\n' "$raw_args" >>"$VIRSH_MUTATIONS" ;;
    *) exit 99 ;;
esac
EOF
chmod 755 "$virsh"

python3 - "$socket" "$other_socket" <<'PY' &
import socket
import sys
import time

for path in sys.argv[1:]:
    listener = socket.socket(socket.AF_UNIX)
    listener.bind(path)
    listener.listen(1)
    # Keep descriptors and listeners alive until this short fixture exits.
    globals().setdefault("listeners", []).append(listener)
time.sleep(3600)
PY
socket_pid=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do
    test -S "$socket" && test -S "$other_socket" && break
    sleep 0.01
done
test -S "$socket" && test -S "$other_socket"

socket_dev=$(/usr/bin/stat -Lc '%d' "$socket")
socket_ino=$(/usr/bin/stat -Lc '%i' "$socket")
other_dev=$(/usr/bin/stat -Lc '%d' "$other_socket")
other_ino=$(/usr/bin/stat -Lc '%i' "$other_socket")
socket_path=$socket
record="$tmp/record.json"
write_record() {
    printf '{"domain_name":"bootc-tmt-unit","domain_uuid":"%s","initial_disk":"%s","volume_name":"bootc-tmt-unit-fresh-install.raw","pool_uuid":"%s","volume_key":"%s","volume_path":"%s","connection_uri":"%s","socket_path":"%s","socket_dev":"%s","socket_ino":"%s","virsh_path":"%s","active_domain_id":"42"}\n' \
        "$uuid" "$initial" "$pool_uuid" "$volume" "$volume" "$uri" "$socket_path" "$socket_dev" "$socket_ino" "$virsh" >"$record"
}
run_helper() {
    : >"$tmp/virsh.calls"
    : >"$tmp/virsh.mutations"
    rm -f "$tmp/shutdown"
    env -i \
        VIRSH_CALLS="$tmp/virsh.calls" VIRSH_MUTATIONS="$tmp/virsh.mutations" \
        MOCK_URI="$uri" MOCK_DOMAIN_UUID="${MOCK_DOMAIN_UUID:-$uuid}" MOCK_POOL_UUID="$pool_uuid" \
        MOCK_INITIAL="$initial" MOCK_VOLUME="$volume" MOCK_DOMAIN_ID="${MOCK_DOMAIN_ID:-42}" \
        MOCK_SHUTDOWN_MARKER="$tmp/shutdown" MOCK_STATE="${MOCK_STATE:-shut off}" \
        MOCK_MISSING_VDB="${MOCK_MISSING_VDB:-false}" \
        /bin/bash "$helper" "$record"
}

write_record
MOCK_STATE=running run_helper
while read -r command; do
    case "$command" in
        --connect\ "$uri"\ *) ;;
        *) exit 1 ;;
    esac
done <"$tmp/virsh.calls"
grep -F -- "--connect $uri shutdown $uuid" "$tmp/virsh.calls" >/dev/null
grep -F -- "MUTATING --connect $uri detach-disk $uuid $initial --config" "$tmp/virsh.mutations" >/dev/null
grep -F -- "MUTATING --connect $uri start $uuid" "$tmp/virsh.mutations" >/dev/null

# An initial shutoff domain is an invariant failure, not a successful shortcut.
if MOCK_STATE='shut off' run_helper; then
    exit 1
fi

# Paused/crashed states are also rejected before mutation.
for state in paused crashed; do
    if MOCK_STATE="$state" run_helper; then
        exit 1
    fi
    test ! -s "$tmp/virsh.mutations"
done

# Socket replacement and an inactive/mismatched recorded ID fail before action.
socket_path=$other_socket
socket_dev=$other_dev
socket_ino=$((other_ino + 1))
uri="qemu+unix:///session?socket=$socket_path"
write_record
if MOCK_STATE=running run_helper; then
    exit 1
fi
test ! -s "$tmp/virsh.mutations"

socket_path=$socket
socket_dev=$(/usr/bin/stat -Lc '%d' "$socket")
socket_ino=$(/usr/bin/stat -Lc '%i' "$socket")
uri="qemu+unix:///session?socket=$socket"
MOCK_DOMAIN_ID=99
write_record
if MOCK_STATE=running run_helper; then
    exit 1
fi
test ! -s "$tmp/virsh.mutations"

# Unrelated UUID still fails before any mutating command.
MOCK_DOMAIN_UUID=22222222-2222-2222-2222-222222222222
if run_helper; then
    exit 1
fi
test ! -s "$tmp/virsh.mutations"
