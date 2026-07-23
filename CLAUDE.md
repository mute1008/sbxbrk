# SbxBrk — 作業を始める前に

これは V8 サンドボックスバイパス探索の JIT 注入ファジング campaign。**運用の入口は
[`ops/README.md`](./ops/README.md)**。起動・状況確認・停止は `ops/` の3スクリプトで行う。
（以前は運用知識を会話メモリに置いていたが、すべて `ops/README.md` に移した。そちらが正典。）

## すぐ使う

```bash
./ops/campaign_up.sh          # コンテナ起動 → sysctl → watchdog（= campaign 再開）。冪等。
./ops/campaign_status.sh      # 状況表示（30秒更新は: ./ops/campaign_status.sh watch）
./ops/campaign_down.sh        # jit campaign だけ停止（baseline は巻き込まない）
```

前提: Docker Desktop（WSL 統合）が起動していること。

## 絶対に外さない要点（詳細は ops/README.md）

- **再起動後は自動復帰しない**。マシン/WSL/コンテナ再起動のたびに `campaign_up.sh` を叩く。
  sysctl（core_pattern 等）は揮発するので毎回設定が要る。忘れると check.rs が即死する
  （`campaign_up.sh` が内包）。
- **broad な `pkill -f v8fuzz` 禁止**。同一コンテナの baseline_campaign を巻き込む。停止は work-dir で
  スコープする（`campaign_down.sh` がそうしている）。撃つ前に `pgrep` で確認。
- **status の読み方**: `corpus` 件数の増加＝前進（最も信頼できる）。`exec` はプロセス起動からの累計で
  再起動時 0 に戻る。`e/s` は resume 直後 `-`/`0`/負に見えるが異常ではない（カウンタリセット由来）。
- **objective は候補**であって確定ではない。主要な偽陽性クラス（InstrumentLoad 計装バグ・診断経路）を
  まず除外してトリアージする。
- 実データは `trees/`（**gitignored, 58G+**）。`trees/jit_campaign` は自己完結（v8fuzz/d8/corpus/seeds）で、
  source は sbxbrk-fuzzer / sbxbrk-v8 / sbxbrk-libafl 由来。

## 構成メモ

- `env/start.sh` は**コンテナを作る/繋ぐだけ**（campaign は起動しない）。コンテナ名で既存に再接続する
  ため、移設後にそのまま叩くと旧マウントに繋がる罠がある → `campaign_up.sh` がマウント不一致を検出して
  作り直す。
- `/work` = `start.sh` を実行した SbxBrk リポジトリのルート。
