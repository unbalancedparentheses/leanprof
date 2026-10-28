#!/bin/sh
# batch.sh NAME CMD...: wait until the 1-minute load is under 2, run CMD
# pinned to logical CPUs 0-7 (physical cores 0-7, the V-cache CCD), sample
# the load every 5 s, and write results/NAME.load (start, max, end). The
# batch is rejected (exit 3) when the load rose above 4 while it ran.
name=$1; shift
dir=$HOME/leanprof-bench/linux/results
mkdir -p "$dir"
# one timing run at a time (the verdict protocol holds the same lock)
if [ -z "$BATCH_LOCKED" ]; then
  BATCH_LOCKED=1 exec flock "$HOME/.leanprof-bench.lock" "$0" "$name" "$@"
fi
l1() { cut -d" " -f1 /proc/loadavg; }
while awk -v l="$(l1)" 'BEGIN{exit !(l>=2)}'; do sleep 15; done
start=$(l1); t0=$(date -Is)
( while :; do l1; sleep 5; done ) > "$dir/$name.loadlog" &
sp=$!
taskset -c 0-7 "$@"; rc=$?
kill $sp
end=$(l1); max=$(sort -g "$dir/$name.loadlog" | tail -1)
verdict=ok; awk -v m="$max" 'BEGIN{exit !(m>4)}' && verdict=rejected
printf 'name=%s start_time=%s end_time=%s load_start=%s load_max=%s load_end=%s verdict=%s rc=%s\n' \
  "$name" "$t0" "$(date -Is)" "$start" "$max" "$end" "$verdict" "$rc" | tee "$dir/$name.load"
[ $verdict = ok ] || exit 3
exit $rc
