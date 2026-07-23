#!/usr/bin/env bash
# JIT campaign の状況を表示する。ホスト側で実行。
#   ./ops/campaign_status.sh          # 一発表示
#   ./ops/campaign_status.sh watch    # 30秒ごとに更新して眺める
#
# 読み方の注意（詳しくは ops/README.md）:
#   - corpus 列 = 実ディレクトリの件数。増えていれば前進。これが一番信頼できる指標。
#   - exec 列   = プロセス起動からの累計（累積ではない）。再起動で 0 に戻る。
#   - e/s 列    = 約5分窓の直近レート。resume/再起動直後は - や 0 や負に見える（異常でない）。
set -euo pipefail
CONTAINER=v8-heap-sandbox-artifact-env
STATUS=/work/trees/jit_campaign/jit_status.sh

if ! docker container inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null | grep -q true; then
  echo "コンテナ $CONTAINER が起動していない。先に ./ops/campaign_up.sh" >&2
  exit 1
fi

if [ "${1:-}" = "watch" ]; then
  exec watch -n 30 "docker exec $CONTAINER bash $STATUS"
else
  exec docker exec "$CONTAINER" bash "$STATUS"
fi
