#!/usr/bin/env nu

# Load the production marker helpers; do not reproduce their serialization or
# parsing logic in this regression test.
use std assert
const production = (path self | path dirname | path join ".." "booted" "composefs-bridge-markers.nu")
use $production *

let tmp = (^mktemp -d | str trim)
let marker_file = ($tmp | path join "checkpoint-markers")

write-checkpoint-marker $marker_file "legacy-dir-created"
assert equal (checkpoint-markers $marker_file) ["legacy-dir-created"]
assert (checkpoint-marker-present $marker_file "legacy-dir-created")

# Reopen the file between every append, matching the reboot/checkpoint
# boundary that exposed the missing newline in the bridge test.
append-checkpoint-marker $marker_file "payload-proven"
assert equal (checkpoint-markers $marker_file) ["legacy-dir-created", "payload-proven"]
append-checkpoint-marker $marker_file "reopened-after-payload"
assert equal (checkpoint-markers $marker_file) [
    "legacy-dir-created"
    "payload-proven"
    "reopened-after-payload"
]

assert (checkpoint-marker-present $marker_file "legacy-dir-created")
assert (checkpoint-marker-present $marker_file "payload-proven")
assert (not (checkpoint-marker-present $marker_file "payload-provenreopened-after-payload"))

^rm -rf $tmp
