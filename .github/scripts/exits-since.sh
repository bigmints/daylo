#!/usr/bin/env bash
# The exit records of this app, from this start. Not the ones the phone still remembers,
# and not the ones belonging to processes the app merely rents.
#
# WHY: `dumpsys activity exit-info <pkg>` answers "how has anything under this package
# ended, lately". Two things get mixed into that answer, and each one has already made
# this job say something false.
#
# TIME. It keeps about sixteen records. A check that greps the whole answer for CRASH is
# asking whether the package has EVER crashed on this device. In the slow start job, one
# real abort in the first run was re-reported in the eight runs after it, and stopped only
# when the record fell off the end of the buffer: nine of twelve results were about one
# crash that had already happened. Run 2 was failed for a crash stamped three seconds
# before it started.
#
# PROCESS. The app's WebView runs in an isolated process, and its records are filed under
# the app. Android reclaims it right after the app goes, so the NEWEST record is routinely
# the helper's. The abort that this whole investigation is about was reported as
# "reason=13 (OTHER KILLS BY SYSTEM)", which was the helper being tidied up 82ms later;
# the app's own record, one line down, said reason=1 (EXIT_SELF). The headline named the
# wrong process for as long as that question has been open.
#
# Takes the cutoff as the device's own clock reading, taken just before the app is
# started, and the process name to keep. Records are kept whole, since the reason, the
# process and the timestamp are on three different lines.
set -uo pipefail

since="${1:?the device clock reading to start from, as 'YYYY-MM-DD HH:MM:SS'}"
want="${2:?the process name to keep, normally the package}"

awk -v since="$since" -v want="$want" '
  function flush() { if (fresh && mine) printf "%s", block; block = ""; fresh = 0; mine = 0 }
  /ApplicationExitInfo #/ { flush() }
  {
    block = block $0 "\n"
    # Zero padded and most significant first, so a string comparison is a time
    # comparison. Compared on the same number of characters, because the records carry
    # milliseconds and the cutoff does not.
    if (match($0, /timestamp=[0-9-]+ [0-9:]+/))
      fresh = (substr($0, RSTART + 10, length(since)) >= since)
    # The whole name and nothing less: the helper processes are the package name with a
    # colon and more after it, so a prefix match would keep exactly what this excludes.
    if (match($0, /process=[^ ]+/))
      mine = (substr($0, RSTART + 8, RLENGTH - 8) == want)
  }
  END { flush() }
'
