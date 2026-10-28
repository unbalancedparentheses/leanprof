#!/bin/sh
# ab.sh FIRST LAST: suite pairs FIRST..LAST, before (main) and after (the
# branch) alternating which goes first, each run its own load-gated batch.
export PATH=$HOME/.elan/bin:$PATH
B=$HOME/leanprof-bench/linux
R=$B/results
i=$1
while [ "$i" -le "$2" ]; do
  if [ $((i % 2)) -eq 1 ]; then order="leanprof after"; else order="after leanprof"; fi
  for d in $order; do
    tag=$([ $d = leanprof ] && echo before || echo after)-p$i
    cd $B/$d
    $B/batch.sh suite-$tag python3 bench/run.py --no-build --noisy --md $R/suite-$tag.md --json $R/suite-$tag.json > $R/suite-$tag.log 2>&1
  done
  i=$((i + 1))
done
