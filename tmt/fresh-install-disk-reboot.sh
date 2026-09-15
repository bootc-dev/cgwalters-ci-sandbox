#!/usr/bin/env bash
# Runner-side connect-provisioner soft-reboot command for test-50. This only
# operates on the explicitly recorded domain, connection, and disks.
set -Eeuo pipefail

record=${1:?missing fresh-install resource record}
log="${record%.json}.reboot.log"
exec >>"$log" 2>&1

phase=record
on_error() {
    local rc=$?
    trap - ERR
    printf 'ERROR phase=%s line=%s command=%q status=%s\n' \
        "$phase" "${BASH_LINENO[0]:-$LINENO}" "$BASH_COMMAND" "$rc" >&2
    exit "$rc"
}
trap on_error ERR

run() {
    printf 'command:' >&2
    printf ' %q' /usr/bin/timeout --kill-after=10s 120s "$@" >&2
    printf '\n' >&2
    /usr/bin/timeout --kill-after=10s 120s "$@"
}

die() {
    printf 'ERROR phase=%s %s\n' "$phase" "$*" >&2
    exit 1
}

verify_socket() {
    local kind dev ino
    read -r kind dev ino < <(/usr/bin/stat -Lc '%F %d %i' "$socket_path")
    test "$kind" = socket || die "connection socket is no longer a Unix socket"
    test "$dev" = "$socket_dev" || die "connection socket device changed"
    test "$ino" = "$socket_ino" || die "connection socket inode changed"
}

disk_source() {
    local type device target source
    while read -r type device target source; do
        if [[ $type == file && $device == disk && $target == "$1" ]]; then
            printf '%s\n' "$source"
            return 0
        fi
    done < <(run "$virsh_path" --connect "$connection_uri" domblklist "$domain_uuid" --details)
    return 1
}

phase=guards
test -r "$record"
domain_name=$(/usr/bin/jq -er '.domain_name | strings' "$record")
domain_uuid=$(/usr/bin/jq -er '.domain_uuid | strings' "$record")
initial_disk=$(/usr/bin/jq -er '.initial_disk | strings' "$record")
volume_name=$(/usr/bin/jq -er '.volume_name | strings' "$record")
pool_uuid=$(/usr/bin/jq -er '.pool_uuid | strings' "$record")
volume_key=$(/usr/bin/jq -er '.volume_key | strings' "$record")
volume_path=$(/usr/bin/jq -er '.volume_path | strings' "$record")
connection_uri=$(/usr/bin/jq -er '.connection_uri | strings' "$record")
socket_path=$(/usr/bin/jq -er '.socket_path | strings' "$record")
socket_dev=$(/usr/bin/jq -er '.socket_dev | strings' "$record")
socket_ino=$(/usr/bin/jq -er '.socket_ino | strings' "$record")
virsh_path=$(/usr/bin/jq -er '.virsh_path | strings' "$record")
active_domain_id=$(/usr/bin/jq -er '.active_domain_id | strings' "$record")

[[ $domain_name =~ ^bootc-tmt-[[:alnum:]-]+$ ]]
[[ $domain_uuid =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]
[[ $pool_uuid =~ ^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$ ]]
[[ $volume_name == "$domain_name"-fresh-install.raw ]]
test -n "$volume_key"
[[ $initial_disk == /* ]]
test -e "$initial_disk"
[[ $volume_path == /* ]]
test -e "$volume_path"
[[ $virsh_path == /* ]]
test -x "$virsh_path"
test -n "$active_domain_id"
test "$active_domain_id" != "-"

case "$connection_uri" in
    qemu+unix:///session\?socket=*) ;;
    *) die "connection URI is not a local qemu+unix socket URI" ;;
esac
uri_socket=${connection_uri#*\?socket=}
[[ $connection_uri != *'&'* ]] || die "connection URI has ambiguous query parameters"
test "$uri_socket" = "$socket_path" || die "connection URI socket does not match recorded socket"
[[ $socket_path == /* ]]
verify_socket

test "$(run "$virsh_path" --connect "$connection_uri" domuuid "$domain_name" | /usr/bin/tr -d '[:space:]')" = "$domain_uuid"
test "$(run "$virsh_path" --connect "$connection_uri" pool-uuid default | /usr/bin/tr -d '[:space:]')" = "$pool_uuid"
test "$(run "$virsh_path" --connect "$connection_uri" vol-path --pool default "$volume_name" | /usr/bin/tr -d '[:space:]')" = "$volume_path"
test "$(run "$virsh_path" --connect "$connection_uri" vol-key --pool default "$volume_name" | /usr/bin/tr -d '[:space:]')" = "$volume_key"
test "$(run "$virsh_path" --connect "$connection_uri" domid "$domain_uuid" | /usr/bin/tr -d '[:space:]')" = "$active_domain_id"
test "$(disk_source vda)" = "$initial_disk"
test "$(disk_source vdb)" = "$volume_path"
printf 'guards-passed domain=%s domain_uuid=%s active_domain_id=%s volume=%s\n' \
    "$domain_name" "$domain_uuid" "$active_domain_id" "$volume_name"

phase=state
state=$(run "$virsh_path" --connect "$connection_uri" domstate "$domain_uuid" | /usr/bin/tr -d '[:space:]')
printf 'state domain_uuid=%s state=%s\n' "$domain_uuid" "$state"
test "$state" = running || die "initial domain state=$state; expected running"

phase=shutdown
run "$virsh_path" --connect "$connection_uri" shutdown "$domain_uuid"
for _ in $(/usr/bin/seq 1 60); do
    state=$(run "$virsh_path" --connect "$connection_uri" domstate "$domain_uuid" | /usr/bin/tr -d '[:space:]')
    printf 'state domain_uuid=%s state=%s\n' "$domain_uuid" "$state"
    test "$state" = shutoff && break
    /usr/bin/sleep 2
done
test "$state" = shutoff || die "domain did not reach shutoff (state=$state)"

phase=socket-recheck
verify_socket
phase=detach
run "$virsh_path" --connect "$connection_uri" detach-disk "$domain_uuid" "$initial_disk" --config
phase=start
run "$virsh_path" --connect "$connection_uri" start "$domain_uuid"
printf 'complete domain_uuid=%s\n' "$domain_uuid"
