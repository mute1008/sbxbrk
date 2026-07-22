#!/bin/bash
# JIT注入 campaign の状況表示。watch で回して自分で見る用。
#   docker exec v8-heap-sandbox-artifact-env bash /work/trees/jit_campaign/jit_status.sh
#   watch -n 30 'docker exec v8-heap-sandbox-artifact-env bash /work/trees/jit_campaign/jit_status.sh'
ROOT=/work/trees/jit_campaign
JR=$ROOT/jit_run
NCORES=18            # watchdog_jitfuzz.sh の NCORES と合わせる
LAST=$((NCORES-1))

echo "=== JIT injection campaign  $(date '+%F %T') ==="
echo "v8fuzz: $(pgrep -xc v8fuzz)/$NCORES   watchdog: $(pgrep -fc watchdog_jitfuzz.sh)   RESUMED(restarts): $(grep -c RESUMED $JR/watchdog.log 2>/dev/null)"

obj=0
for c in $(seq 0 $LAST); do
  obj=$((obj + $(ls $JR/fuzzer-$c/crashes/*.ron 2>/dev/null | wc -l)))
done
echo "objectives (sandbox-bypass candidates) TOTAL: $obj"
if [ "$obj" -gt 0 ]; then
  echo "  workers with objectives:"
  for c in $(seq 0 $LAST); do
    n=$(ls $JR/fuzzer-$c/crashes/*.ron 2>/dev/null | wc -l)
    [ "$n" -gt 0 ] && echo "    fuzzer-$c: $n"
  done
fi

# exec/s = 固定の約5分窓での直近レート(累積でない。落ちたら 0 と出る)。
# 履歴を /tmp に貯め、約 WIN 秒前のサンプルと比較する。watch の間隔に依らず窓は約5分。
HIST=/tmp/jit_status_hist
WIN=300
now=$(date +%s)
declare -a EXN
for c in $(seq 0 $LAST); do
  # rotatelogs で書き込み先が別ファイルに移る＋再起動で exec がリセットされる。
  # ∴「全ローテ最大」でなく、最新mtimeのローテファイルの最後の executions 行(=現runの最新値)を読む。
  lf=$(ls -t $JR/logs/fuzzer_$c.log* 2>/dev/null | head -1)
  v=$(tail -n 400 "$lf" 2>/dev/null | grep -a "executions:" | grep -oE "executions: [0-9]+" | grep -oE "[0-9]+" | tail -1)
  EXN[$c]=${v:-0}
done

# 現サンプルを履歴に追記し、2*WIN より古い行は捨てる
echo "$now ${EXN[*]}" >> "$HIST"
awk -v cut=$((now-2*WIN)) '$1>=cut' "$HIST" > "$HIST.tmp" 2>/dev/null && mv "$HIST.tmp" "$HIST"

# 基準 = WIN秒以上前で最も新しいサンプル。無ければ(履歴が浅い)最古を使う
ref=$(awk -v t=$((now-WIN)) '$1<=t' "$HIST" | tail -1)
[ -z "$ref" ] && ref=$(head -1 "$HIST")
read -a REF <<< "$ref"
rep=${REF[0]:-$now}
dt=$(( now - rep ))

echo "--- workers  (e/s = 直近 約${dt}s窓) ---"
printf "%-10s %9s %12s %8s\n" worker corpus exec e/s
tot_ex=0
for c in $(seq 0 $LAST); do
  # corpus はログ(古いローテを読む恐れ)でなく実ディレクトリの件数を数える=常に正確
  cor=$(ls $JR/fuzzer-$c/corpus 2>/dev/null | wc -l)
  rex=${REF[$((c+1))]:-0}
  if [ "$dt" -gt 0 ] && [ "$rep" != "$now" ]; then
    rate=$(( (${EXN[$c]} - rex) / dt ))
  else
    rate="-"
  fi
  printf "%-10s %9s %12s %8s\n" "fuzzer-$c" "${cor:--}" "${EXN[$c]}" "$rate"
  tot_ex=$((tot_ex + ${EXN[$c]}))
done
echo "total executions: $tot_ex"
