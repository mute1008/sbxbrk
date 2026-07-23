#!/usr/bin/env bash
# JIT campaign だけを停止する。ホスト側で実行。
#   ./ops/campaign_down.sh
#
# 重要: broad な `pkill -f v8fuzz` は同一コンテナ内の baseline_campaign の
#       ワーカーまで巻き込む。ここでは work-dir を jit_campaign に限定して撃つ。
#       停止後、孤児化した d8(ppid=1) を掃除する（放置すると CPU を空回りし続ける）。
#
# 実装注意: プロセス特定は「直接 exec の pgrep」で行い、集めた PID を kill する。
#   `docker exec C bash -lc 'pkill -f watchdog_jitfuzz.sh ...'` にすると、パターン
#   文字列を argv に含む bash -lc ラッパー自身に pkill が誤マッチしてスクリプトが
#   途中で死ぬ。pgrep は自PIDを除外し、直接 exec なら余計なラッパーも無い。
set -euo pipefail
CONTAINER=v8-heap-sandbox-artifact-env
JR_PAT="work-dir /work/trees/jit_campaign/jit_run"

if ! docker container inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  echo "コンテナ $CONTAINER が起動していない。何もしない。" >&2
  exit 0
fi

# 指定パターンにマッチする PID を container 内で集める（直接 exec / pgrep は自PID除外）。
# マッチ0件で pgrep が exit 1 を返しても set -e/pipefail で死なないよう || true で吸収する。
pids() { docker exec "$CONTAINER" pgrep -f "$1" 2>/dev/null | tr '\n' ' ' || true; }
kill_pids() { # $1=signal $2=pattern
  local p; p="$(pids "$2")" || true
  if [ -n "${p// }" ]; then
    docker exec "$CONTAINER" kill "-$1" $p 2>/dev/null || true
  fi
}

# 1) watchdog を先に止める（止めないと即座にワーカーを再起動する）
kill_pids TERM watchdog_jitfuzz.sh
sleep 1
# 2) jit_campaign の work-dir を持つワーカーだけを止める（baseline は巻き込まない）
kill_pids TERM "$JR_PAT"
sleep 3
# 3) しぶといものは SIGKILL
kill_pids KILL watchdog_jitfuzz.sh
kill_pids KILL "$JR_PAT"
sleep 1
# 4) 孤児 d8(ppid=1) を掃除
orphans="$(docker exec "$CONTAINER" bash -lc 'ps -eo pid,ppid,comm | awk "\$2==1 && \$3==\"d8\" {print \$1}" | tr "\n" " "')"
[ -n "${orphans// }" ] && docker exec "$CONTAINER" kill -9 $orphans 2>/dev/null || true

# 5) 結果表示
docker exec "$CONTAINER" bash -lc '
  echo "停止後: watchdog=$(pgrep -fc watchdog_jitfuzz.sh) v8fuzz=$(pgrep -xc v8fuzz) d8=$(pgrep -xc d8) 孤児d8=$(ps -eo ppid,comm|awk '"'"'$1==1&&$2=="d8"'"'"'|wc -l)"'
echo "[down] 完了（baseline_campaign には触れていない）"
