#!/usr/bin/env bash
#
# Start Daylo many times, some of them on a machine that is deliberately busy, and keep
# every log.
#
# Two arms and not one. "It failed with the machine loaded" says nothing on its own: the
# smoke job has failed without anybody loading anything, so a rate under load is only a
# finding next to a rate without it. The arms are interleaved rather than run in blocks,
# because a runner that gets slower as it goes would otherwise hand all its bad luck to
# whichever arm came last, and that would look exactly like a finding.
#
# The smoke script is what decides whether a start went well. This one only arranges the
# conditions, runs it again, and counts.
set -uo pipefail

LOADED="${LOADED_RUNS:-8}"
PLAIN="${PLAIN_RUNS:-4}"
PKG=com.daylo.app

# Busy, not full. The point is to make the first seconds of the app compete for the
# processor the way a cheap phone does when it has just been turned on, not to run the
# machine out of memory, which would be a different failure and not the one being chased.
busy() {
  local workers
  workers=$(( $(nproc) * 2 ))
  echo "keeping $workers workers busy while the app starts"
  for _ in $(seq 1 "$workers"); do
    ( timeout 25 sh -c 'while :; do :; done' ) &
  done
}

total=$(( LOADED + PLAIN ))
if [ "$total" -eq 0 ]; then
  echo "::error::Nothing to run: both arms are zero."
  exit 0
fi

loaded_done=0
plain_done=0
loaded_failed=0
plain_failed=0

for run in $(seq 1 "$total"); do
  # Whichever arm is furthest behind its share of the runs so far. With 8 and 4 that
  # gives two loaded starts for every plain one, spread across the whole session.
  if [ "$loaded_done" -lt "$LOADED" ] &&
     { [ "$plain_done" -ge "$PLAIN" ] ||
       [ $(( loaded_done * PLAIN )) -le $(( plain_done * LOADED )) ]; }; then
    arm=loaded
  else
    arm=plain
  fi

  echo "::group::Run $run of $total ($arm)"
  # A fresh start every time: the question is about starting, and an app already warm in
  # memory is not starting.
  adb shell am force-stop "$PKG" || true
  adb shell pm clear "$PKG" >/dev/null 2>&1 || true

  [ "$arm" = loaded ] && busy

  if SMOKE_LOG="slow-start-$run-$arm.txt" SMOKE_SHOT="slow-start-$run-$arm.png" \
       bash .github/scripts/android-smoke.sh; then
    echo "run $run ($arm): it stayed up"
  else
    echo "::warning::Run $run ($arm) did not stay up. Its log is slow-start-$run-$arm.txt."
    [ "$arm" = loaded ] && loaded_failed=$((loaded_failed + 1)) || plain_failed=$((plain_failed + 1))
  fi
  [ "$arm" = loaded ] && loaded_done=$((loaded_done + 1)) || plain_done=$((plain_done + 1))

  # The busy workers end by themselves; this waits for them so the next run starts on a
  # quiet machine whichever arm it belongs to.
  wait
  echo "::endgroup::"
done

echo "::notice::loaded: $loaded_failed of $loaded_done did not stay up. plain: $plain_failed of $plain_done did not stay up."
echo "--- what each run left ---"
for f in slow-start-*.txt; do
  [ -e "$f" ] || continue
  printf '%-28s %7s lines  %s fatal\n' "$f" "$(wc -l < "$f")" \
    "$(grep -cE 'beginning of crash|FATAL EXCEPTION|Fatal signal|FORTIFY|panicked at' "$f" 2>/dev/null || echo 0)"
done

# Never red. This job exists to produce evidence, and a job that fails is a job somebody
# has to interpret before they can read what it collected.
exit 0
