#!/usr/bin/env bash
#
# Install Daylo on the emulator and find out whether it is still there a moment later.
#
# This exists because compiling is not starting. Two APKs that compiled everywhere and
# passed every check died before drawing a frame — one to R8 stripping a constructor the
# notification plugin looks up by reflection, one to a `plugins` block in tauri.conf.json
# that the plugin's Rust half refuses. Both times the person who found out was holding
# the phone.
#
# What it claims: the process is alive, its own activity is the one in front, Android
# recorded no crash for it, and the webview painted something other than one flat colour.
# What it does not claim: that any of the app works. That is still a person's job.

set -euo pipefail

PKG=com.daylo.app
ACTIVITY="$PKG/.MainActivity"
APK="${SMOKE_APK:?SMOKE_APK is not set: the signing step should have put it in GITHUB_ENV}"

# Kept next to the screenshot so a failure can be read without re-running anything.
LOG=smoke-logcat.txt
SHOT=smoke-screenshot.png

# Anything that ends this script without going through fail() is a bug in the script, not
# a verdict on the app, and it has to say so out loud. One run suspended with Daylo alive
# and painting because `[ -n "$x" ] && echo` returned non-zero on an empty string and
# set -e took the whole script with it; all the runner could say was "failed with exit
# code 1", and the app wore the blame for a shell mistake. exit does not raise ERR, so
# this fires only on the unplanned kind.
trap 'echo "::error::The smoke script itself failed at line $LINENO. That is a bug in this script, not a finding about the app."' ERR

# The lines that say what went wrong, wherever they are in the log, and only then the
# end of it.
#
# It used to print the last 200 lines and nothing else, which is the part of a crash log
# least likely to contain the crash: the process dies, Android goes on logging, and by
# the time the job reads the file the abort is thousands of lines back. One run cost us
# an evening for exactly that. The panic and the signal were in the artifact all along,
# 964 lines from the end, while the job's own output began after the app was already
# dead and said nothing about why.
# One pattern, used by the check that decides and by the message that explains, because
# two of them drift and the drift is invisible: the deciding one would fire and the
# explaining one would print nothing, which is how the first version of this read a log
# full of FORTIFY aborts and showed only "beginning of crash".
#
# The level letter is what makes it general. logcat marks fatal lines with F in the column
# after the pids, and that catches what libc writes on an abort, what DEBUG writes for a
# tombstone, and whatever Android marks fatal next year without anybody adding it here.
# The named ones stay because a Rust panic is logged at I by wry's stdout bridge, which no
# level filter would ever find.
FATAL='beginning of crash|FATAL EXCEPTION|Fatal signal|FORTIFY|panicked at|RustStdoutStderr.*(panicked|Err)|^[0-9-]+ [0-9:.]+ +[0-9]+ +[0-9]+ F '

fatal_lines() {
  grep -nE "$FATAL" "$LOG" 2>/dev/null | head -40
}

fail() {
  echo "::error::$*"
  local fatal
  fatal=$(fatal_lines)
  if [ -n "$fatal" ]; then
    echo "--- what logcat calls fatal, by line number ---"
    printf '%s\n' "$fatal"
  else
    echo "--- nothing in logcat is marked fatal; here is the end of it ---"
    tail -n 200 "$LOG" 2>/dev/null || echo "(no logcat captured)"
  fi
  echo "--- the whole log is in the android-smoke-evidence artifact ---"
  exit 1
}

# No network for the emulator, before the app is ever started.
#
# Since 1.3 a fresh profile is a new installation: the app turns the check-in on and sends
# one, and this job installs a fresh profile every time it runs. The server counted a
# runner as a person more than once before anybody noticed. The desktop jobs set
# DAYLO_DISABLE_CHECKIN, which an Android app cannot read: it is started by the zygote and
# inherits nothing from this shell. Cutting the radio is the lever that does exist here.
#
# It also buys something the job did not have: the app is now shown to start with no
# network at all, which is how a phone opens it in a lift.
echo "::group::Cut the network"
adb shell cmd connectivity airplane-mode enable || true
adb shell svc wifi disable || true
adb shell svc data disable || true
echo "airplane_mode_on=$(adb shell settings get global airplane_mode_on | tr -d '\r')"
echo "::endgroup::"

echo "::group::Install"
adb install -r "$APK"
echo "::endgroup::"

# From here on, everything in the log belongs to this run.
adb logcat -c
adb shell am start -W -n "$ACTIVITY"

# Thirty seconds to reach the foreground. A Tauri app on a cold emulator takes a few
# seconds; a crash loop takes none, and the checks below are what tell them apart.
resumed=""
for _ in $(seq 1 30); do
  sleep 1
  if adb shell dumpsys activity activities 2>/dev/null \
      | grep -E "mResumedActivity|topResumedActivity" | grep -q "$PKG"; then
    resumed=yes
    break
  fi
done

# Ten seconds more before looking. A process that aborts on its first frame can still be
# caught mid-start by the loop above, and a panic inside run() takes a moment to land.
sleep 10
# The default buffer set already includes crash on these images, and the abort that cost
# us an evening was in this file. It is named anyway, so that the file does not depend on
# a default: a log without the crash buffer would look exactly like an app that died
# quietly.
adb logcat -d -b main,system,crash > "$LOG" || true

# The picture first, before anything can fail. It is the cheapest evidence there is and a
# failing run is exactly when it is wanted: the first time this job suspended, it did so
# before this line and the artifact arrived with a log and no screen. If the process is
# already gone this captures whatever is behind it, which is itself worth seeing.
adb shell screencap -p /data/local/tmp/smoke.png || true
adb pull /data/local/tmp/smoke.png "$SHOT" || true

echo "::group::Android's own account of why anything died"
exits=""
if exits=$(adb shell dumpsys activity exit-info "$PKG" 2>&1); then
  echo "${exits:-(nothing recorded)}"
else
  # Said out loud rather than swallowed: without this one of the checks below would be
  # skipped and the job would still go green.
  echo "::warning::dumpsys activity exit-info is not available on this image."
  echo "::warning::Falling back on the process and logcat checks alone."
fi
echo "::endgroup::"

# What Android calls the exit and what actually happened are not always the same word. A
# process that aborts inside libc during teardown has been recorded here as EXIT_SELF,
# with the abort itself only in logcat — so this reports the reason rather than deciding
# on it, and the logcat check below is what rules.
#
# Taken from the start of the field to the next one rather than by shape: the name has
# parentheses of its own — "APP CRASH(NATIVE)" — and a pattern that stopped at the first
# closing bracket read the subreason instead and reported an exit as UNKNOWN while Android
# was calling it a native crash.
exit_reason=$(sed -n 's/.* \(reason=[0-9]\+ .*\) subreason=.*/\1/p' <<< "${exits:-}" | head -1)
if [ -n "$exit_reason" ]; then
  echo "Android's word for the last exit: $exit_reason"
fi

if grep -q "CRASH" <<< "${exits:-}"; then
  # Android's own record says a crash, and `fail` now digs the lines out of logcat rather
  # than printing the end of it. Those lines are the whole difference between "it died"
  # and knowing what killed it: exit-info records `trace=null` for a native abort, so
  # without them this check reports a crash and no cause.
  fail "Android recorded a crash for $PKG ($exit_reason). Its own words are in the group above."
fi

# A native abort is not a Java exception and not a Rust panic, and until a run produced
# one this looked only for those two. libc writes its own epitaph and logcat marks the
# spot: "--------- beginning of crash", then an F line. FORTIFY aborts land here, and so
# does any signal.
if grep -qE "$FATAL" "$LOG"; then
  echo "::group::What logcat says went wrong"
  fatal_lines
  echo "::endgroup::"
  fail "The app logged a fatal error. The lines are in the group above and the whole log is in the artifact."
fi

if [ -z "$resumed" ]; then
  fail "$ACTIVITY never reached the foreground: 30 seconds of dumpsys and it was never the resumed activity."
fi

if pid=$(adb shell pidof "$PKG" 2>/dev/null) && [ -n "$pid" ]; then
  echo "still running as pid $pid"
else
  fail "$PKG started and was gone again: pidof returned nothing. Android's word for the last exit was ${exit_reason:-(nothing recorded)}."
fi

# But first, whose browser is this? An emulator image carries a WebView baked in and has
# no Play Store to update it, so the image decides the engine — and on a real phone
# WebView comes from the Play Store and is current. The first run of this job was on an
# image with WebView 83, from 2020, and Daylo's stylesheet opens with `@layer`, which
# Chromium learned in 99: every rule was skipped and the app painted an unstyled page
# that sailed through the check below. So: if the engine is older than the stylesheet
# needs, the screenshot is not evidence about anything and this says so instead of
# scoring it. The floor is 111, which is where oklch() and color-mix() arrived; the
# stylesheet uses both, and @layer at 99 is already covered by it.
MIN_CHROMIUM=111
webview=$(adb shell dumpsys webviewupdate 2>/dev/null \
  | grep -m1 "Current WebView package" || true)
engine=$(grep -oE "[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" <<< "$webview" | head -1)
echo "WebView: ${webview:-(could not be read)}"

if [ -z "$engine" ]; then
  # The check below still runs: a blank screen is a blank screen on any engine. What is
  # lost is knowing whether a screen that is not blank was drawn by a browser anyone has.
  echo "::warning::Could not read the emulator's WebView version. The screenshot check"
  echo "::warning::below still runs, but it cannot tell an unstyled page from a styled one."
elif [ "${engine%%.*}" -lt "$MIN_CHROMIUM" ]; then
  echo "::warning::This image ships Chromium ${engine%%.*}, older than the $MIN_CHROMIUM"
  echo "::warning::Daylo's stylesheet needs, so it renders unstyled here and the"
  echo "::warning::screenshot says nothing about the app. No phone runs this engine."
  echo "::warning::Raise api-level in the workflow rather than trusting this."
  echo "Skipping the screenshot check. The app started, stayed up, and did not crash."
  exit 0
fi

# The screenshot is scored by a script rather than here, because what it has to tell
# apart — a page with Daylo's stylesheet and a page without it — cannot be read off a
# colour count, and the script is the part that can be run against known-good and
# known-bad images on a laptop. Its own message says which of the two failed.
if ! python3 .github/scripts/screen-check.py "$SHOT"; then
  echo "::error::The screenshot is in the android-smoke-evidence artifact. Look at it."
  exit 1
fi

echo "Daylo installed, started, stayed up, and painted its own colours."
