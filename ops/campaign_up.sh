#!/usr/bin/env bash
# JIT注入ファジング campaign を起動する（コンテナ作成/再接続 → sysctl → watchdog）。
# ホスト側で実行する。冪等: 二重に叩いても安全（既に動いていれば起動をスキップ）。
#
#   ./ops/campaign_up.sh
#
# 前提: Docker daemon (Docker Desktop) が起動していること。
#       起動していないと最初の docker コマンドで失敗する。
set -euo pipefail

CONTAINER=v8-heap-sandbox-artifact-env

# このスクリプトの2つ上 = SbxBrk リポジトリのルート（env/ がある所）。
# これが /work にマウントされる。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

echo "[up] repo (=/work にマウントする所): $REPO"

# 0) daemon 生存チェック（落ちていれば分かりやすく落とす）
if ! docker info >/dev/null 2>&1; then
  echo "[up] ERROR: Docker daemon が応答しない。Docker Desktop を起動してから再実行。" >&2
  exit 1
fi

# 1) 既存コンテナが「別のパス」をマウントしていたら stale なので消す。
#    env/start.sh は名前で既存に再接続してしまうため、この掃除が無いと
#    旧マウント（trees が無い旧 ~/SbxBrk 等）に繋がる罠にはまる。
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  MNT="$(docker container inspect "$CONTAINER" --format '{{range .Mounts}}{{if eq .Destination "/work"}}{{.Source}}{{end}}{{end}}')"
  if [ "$MNT" != "$REPO" ]; then
    echo "[up] stale container は $MNT をマウント（欲しいのは $REPO）→ 削除"
    docker rm -f "$CONTAINER" >/dev/null
  fi
fi

# 2) コンテナを用意する。
#    - 無ければ env/start.sh の「新規作成」経路が docker run -d で detached 作成して返る。
#    - 有れば（停止中かも）docker start で起こすだけ（start.sh の対話 exec は避ける）。
if ! docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  echo "[up] コンテナを新規作成（env/start.sh）"
  ( cd "$REPO" && ./env/start.sh )
else
  echo "[up] 既存コンテナを start"
  docker start "$CONTAINER" >/dev/null
fi

# 起動待ち
until [ "$(docker container inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = "true" ]; do sleep 1; done
echo "[up] container running"

# 3) sysctl（root）。忘れると check.rs(modes/check.rs の system_checks) が即死させる。
#    コンテナは Privileged だが既定ユーザは非root ∴ -u root が要る。
#    コンテナ/WSL 再起動のたびに揮発するので毎回設定する。
#    check.rs が検査する全項目をここで満たす:
#      core_pattern=core / shm_rmid_forced=1(IPC名前空間ごと) / perf_event_paranoid<=1 / suid_dumpable=0
#    (core_uses_pid=0 は無害な追加)
docker exec -u root "$CONTAINER" sh -c '
  echo core > /proc/sys/kernel/core_pattern
  echo 0    > /proc/sys/kernel/core_uses_pid
  echo 1    > /proc/sys/kernel/shm_rmid_forced
  echo 1    > /proc/sys/kernel/perf_event_paranoid
  echo 0    > /proc/sys/fs/suid_dumpable'
echo "[up] sysctl 設定済 (core_pattern / shm_rmid_forced / perf_event_paranoid / suid_dumpable)"

# 4) watchdog を detached 起動（冪等: 既に居れば起動しない）。
#    watchdog が18ワーカーを --resume で復帰させ、死んだら再起動し、
#    オーファン d8(ppid=1) を毎ループ掃除する。
#    稼働判定は独立した exec で pgrep する（pgrep は自PIDを除外するので、
#    launch文字列を含む bash -lc に自己誤マッチする問題を避ける）。
running="$(docker exec "$CONTAINER" pgrep -fc watchdog_jitfuzz.sh 2>/dev/null || echo 0)"
if [ "${running:-0}" -gt 0 ]; then
  echo "[up] watchdog は既に稼働中 ($running)"
else
  docker exec "$CONTAINER" bash -lc \
    'cd /work/trees/jit_campaign && setsid nohup bash watchdog_jitfuzz.sh >> jit_run/watchdog_boot.log 2>&1 < /dev/null'
  echo "[up] watchdog を起動した"
fi

# 5) 検証（数秒待って status を見る）
sleep 3
echo "[up] ---- 初期 status ----"
docker exec "$CONTAINER" bash /work/trees/jit_campaign/jit_status.sh | head -3
echo "[up] 完了。継続監視は ./ops/campaign_status.sh"
