#!/usr/bin/env bash
# The fatal lines belonging to this app, out of a log that belongs to the whole phone.
#
# WHY: `adb logcat -d` is the device's log, not the app's. Every process on the emulator
# writes into it, and the patterns that say "something died" say nothing about who. The
# check that used them failed a run because Gmail crashed: "FATAL EXCEPTION ... Process:
# com.google.android.gm ... The com.google.android.gms.auth.accounts provider is not
# available". Daylo had started, stayed up and painted, and the exit records agreed with
# that. One line from a mail client nobody opened was enough to call it a failure.
#
# So the lines are matched as before and then kept only if they come from one of this
# app's processes. The pids are read out of the log itself, from three places that name
# the package rather than merely mention it:
#
#   - "ActivityManager: Start proc 2779:com.daylo.app/..." , which is the birth
#   - any line whose logcat TAG is the package, which is what the app's own runtime writes
#   - "Fatal signal 6 ... pid 2779 (com.daylo.app)", which libc writes on the way out
#
# Deliberately not "any line containing the package": ActivityManager and PackageManager
# say the name constantly, and their pid is the system's. That rule would put system_server
# in the set and let through anything it ever logged as fatal.
set -uo pipefail

pkg="${1:?the package whose processes matter}"
log="${2:?the logcat file to read}"

FATAL='beginning of crash|FATAL EXCEPTION|Fatal signal|FORTIFY|panicked at|RustStdoutStderr.*(panicked|Err)|^[0-9-]+ [0-9:.]+ +[0-9]+ +[0-9]+ F '

awk -v pkg="$pkg" -v fatal="$FATAL" '
  # First pass: who is this app.
  NR == FNR {
    if (match($0, "Start proc [0-9]+:" pkg "([/:]|$)"))
      mine[substr($0, RSTART + 11, index(substr($0, RSTART + 11, 20), ":") - 1)] = 1
    if ($6 == pkg ":") mine[$3] = 1
    if (match($0, /pid [0-9]+ \(/) && index($0, "(" pkg ")")) {
      n = substr($0, RSTART + 4); sub(/ .*/, "", n); mine[n] = 1
    }
    next
  }
  # Second pass: the fatal lines, from this app only. The bare "beginning of crash"
  # separator carries no pid, so it is dropped: it is a marker, not evidence.
  $0 ~ fatal && ($3 in mine) { print FNR ":" $0 }
' "$log" "$log"
