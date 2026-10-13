#!/usr/bin/env bash
#
# Start Daylo several times on a machine that is deliberately busy, and keep every log.
#
# The smoke script is what decides whether a start went well; this one only arranges for
# it to be hard and runs it again. Each run writes its own log and screenshot, so a
# failure that happens once in six leaves evidence next to five runs that did not.
set -uo pipefail

RUNS="${RUNS:-5}"
LOAD="${LOAD:-true}"
PKG=com.daylo.app

# Busy, not full. The point is to make the first seconds of the app compete for the
# processor the way a cheap phone does when it has just been turned on, not to run the
# machine out of memory, which would be a different failure and not the one being chased.
busy() {
  [ "$LOAD" = "true" ] || return 0
  local workers
  workers=$(( $(nproc) * 2 ))
  echo "keeping $workers workers busy while the app starts"
  for _ in $(seq 1 "$workers"); do
    ( timeout 25 sh -c 'while :; do :; done' ) &
  done
}

failures=0
for run in $(seq 1 "$RUNS"); do
  echo "::group::Run $run of $RUNS"
  # A fresh start every time: the question is about starting, and an app already warm in
  # memory is not starting.
  adb shell am force-stop "$PKG" || true
  adb shell pm clear "$PKG" >/dev/null 2>&1 || true

  busy
  if SMOKE_LOG="slow-start-$run.txt" SMOKE_SHOT="slow-start-$run.png" \
       bash .github/scripts/android-smoke.sh; then
    echo "run $run: it stayed up"
  else
    failures=$((failures + 1))
    echo "::warning::Run $run did not stay up. Its log is slow-start-$run.txt in the artifact."
  fi
  wait
  echo "::endgroup::"
done

echo "::notice::$failures of $RUNS runs did not stay up."
# Never red. This job exists to produce evidence, and a job that fails is a job somebody
# has to interpret before they can read what it collected.
exit 0
