#!/usr/bin/env bash
# The exit records from this start, and not the ones the phone still remembers.
#
# WHY: `dumpsys activity exit-info <pkg>` answers "how has this package ended, lately",
# keeping about sixteen records and counting the app's WebView helper processes as the
# app's own. A check that greps the whole answer for CRASH is asking whether the package
# has EVER crashed on this device, which is a different question and keeps saying yes long
# after the run that crashed.
#
# That is measured, not feared. The slow start job restarts the app twelve times on one
# emulator: the first run really did abort, and the eight runs after it were reported as
# crashes too, each quoting an unrelated reason from a newer record. They stopped at run
# ten, when the real record fell off the end of the ring buffer. Nine of twelve results
# were about one crash that had already happened.
#
# Takes the cutoff as the device's own clock reading, taken just before the app is
# started, in the same format the records use. Entries are kept whole, since the reason is
# on a different line from the timestamp.
set -uo pipefail

since="${1:?the device clock reading to start from, as 'YYYY-MM-DD HH:MM:SS'}"

awk -v since="$since" '
  /ApplicationExitInfo #/ {
    if (keep) printf "%s", block
    block = ""; keep = 0
  }
  {
    block = block $0 "\n"
    # Zero padded and most significant first, so a string comparison is a time
    # comparison. Compared on the same number of characters, because the records carry
    # milliseconds and the cutoff does not.
    if (match($0, /timestamp=[0-9-]+ [0-9:]+/))
      keep = (substr($0, RSTART + 10, length(since)) >= since)
  }
  END { if (keep) printf "%s", block }
'
