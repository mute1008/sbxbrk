# SbxBrk JIT injection campaign — 運用手引き

V8 サンドボックスバイパス探索のための JIT 注入ファジング campaign を、Docker 上で長期無人稼働
させるための運用ドキュメント。**これまで会話メモリだけに置いていた運用知識を、ここに集約する。**
新しくこのリポジトリで作業を始める人（および Claude Code）はまずこれを読むこと。

## 0. TL;DR（3コマンド）

```bash
./ops/campaign_up.sh          # コンテナ起動 → sysctl → watchdog（= campaign 再開）
./ops/campaign_status.sh      # 状況表示（watch で回すなら: ./ops/campaign_status.sh watch）
./ops/campaign_down.sh        # jit campaign だけ停止（baseline は巻き込まない）
```

前提: Docker Desktop（WSL 統合）が起動していること。マシン/WSL/コンテナを再起動すると campaign は
**自動では復帰しない**。復帰は必ず `campaign_up.sh` を叩く（sysctl と watchdog をまとめて面倒見る）。

## 1. 全体像

- **目的**: JIT に計装を注入した d8 を Fuzzilli 由来の JIT シードで叩き、サンドボックス外への
  書き込み（sandbox-bypass）候補を objective として集める。
- **実行体**: Rust 製ファザ `v8fuzz`（LibAFL ベース）が d8 を driver として回す。18ワーカー、
  各1コアに pin。死んだら `--resume` で復帰。
- **1コンテナ**: 同じコンテナ内で **jit_campaign** と **baseline_campaign** が並走しうる。
  片方だけ止めたい時は work-dir でスコープする（後述の落とし穴）。

## 2. ディレクトリと自己完結性

campaign の実データ・ビルド済みバイナリは `trees/`（**gitignored, 58G+**）に置く。git には入れない。
`trees/jit_campaign/` は自己完結していて、以下を内包する:

| パス（コンテナ内 `/work/...`） | 中身 |
|---|---|
| `trees/jit_campaign/fuzzer/target/release/v8fuzz` | ファザ本体（sbxbrk-fuzzer 由来、sbxbrk-libafl を焼き込み済み） |
| `trees/jit_campaign/v8-build/out/fuzzing-build/d8` | JIT計装 d8（sbxbrk-v8 由来、696MB） |
| `trees/jit_campaign/jit_run/fuzzer-<0..17>/corpus` | 各ワーカーの corpus |
| `trees/jit_campaign/jit_run/fuzzer-<0..17>/crashes/*.ron` | objective（sandbox-bypass 候補、IPC shmem マスク） |
| `trees/jit_campaign/jit_run/logs/fuzzer_<c>.log*` | ワーカーログ（rotatelogs で回転） |
| `trees/jit_campaign/jit_run/watchdog.log` | RESUMED/FRESH の記録 |
| `trees/jit_campaign/jit_seeds/` | JIT シード |
| `trees/jit_campaign/watchdog_jitfuzz.sh` | ワーカー起動/再起動ループ（NCORES=18） |
| `trees/jit_campaign/jit_status.sh` | 状況表示スクリプト |

**source の系譜**: `trees/jit_campaign` は `sbxbrk` リポジトリの `jit_campaign` ブランチの worktree。
その submodule は本リポジトリの submodule と同一（`fuzzer→sbxbrk-fuzzer`, `v8-build→sbxbrk-v8`）。
つまり動いているバイナリは既に sbxbrk-fuzzer / sbxbrk-v8 / sbxbrk-libafl 由来。source を更新して
バイナリを作り直したい時だけ再ビルドが要る（数時間）。

## 3. コンテナの起動の仕組み（要点）

- `env/start.sh` は **コンテナを作る/繋ぐだけ**で、campaign（watchdog/fuzzer）は起動しない。
- `env/start.sh` は**コンテナ名 `v8-heap-sandbox-artifact-env` で既存を探して再接続**する。
  → **落とし穴**: 別マシン/別パスに移設した後にそのまま叩くと、旧マウントを指す古いコンテナに
  繋がってしまう。`campaign_up.sh` は「/work のマウント元が今のリポジトリと違えば `docker rm -f`」
  して作り直すことでこれを回避している。手で `start.sh` を叩く時は、先に古いコンテナを消すこと。
- `/work` にマウントされるのは `start.sh` を実行した SbxBrk リポジトリのルート（`env/start.sh:56`）。
  だから「新しい方で動かす」＝そのリポジトリから `campaign_up.sh`（内部で start.sh）を叩く、の意味。

## 4. 状況の読み方（jit_status.sh）

```
./ops/campaign_status.sh
```

- **corpus 列** = 実ディレクトリの件数を数えた値。**増えていれば前進**。最も信頼できる指標。
- **exec 列** = そのワーカープロセスの**起動からの累計**（campaign 全体の累積ではない）。
  ワーカーが再起動すると **0 にリセット**される。だから「total executions が減った」ように見えても
  異常ではなく、単に resume/再起動でカウンタが巻き戻っただけ。実体（corpus・objective）は消えない。
- **e/s 列** = 約5分窓の直近レート。resume 直後や再起動直後は `-` / `0` / **負** に見える。
  これはカウンタリセットを跨いだ引き算の表示アーティファクトで、スループットが負なのではない。
  窓が post-resume のサンプルで満たされれば正に戻る。
- **objectives TOTAL** = sandbox-bypass **候補**の総数。確定ではない（トリアージ要、後述）。

### 報告する時のフォーマット
薄いデータで「頭打ち/減速」と断じない。running-max で見る。毎回：論文比 + objective 分類 +
カバレッジ + 新規発見レート（エッジ/h）。「オーファンが〜」を連呼しない。

## 5. 落とし穴（会話メモリから移設した運用知識）

1. **再起動後は自動復帰しない**。マシン/WSL/コンテナ再起動のたびに `campaign_up.sh` を叩く。
   sysctl は揮発するので毎回設定が要る。忘れると `check.rs`(modes/check.rs の system_checks) が即死
   させる。`campaign_up.sh` が全項目を内包している。check.rs が検査するのは:
   - `kernel.core_pattern` = `core`（WSL 既定は `|/wsl-capture-crash …` なので必ず要る）
   - `kernel.shm_rmid_forced` = `1`（**IPC 名前空間ごと**。コンテナ再起動で自前の名前空間が 0 に戻る＝
     ホストで設定してもこの private-IPC コンテナには届かない → コンテナ内で root exec して設定）
   - `kernel.perf_event_paranoid` ≤ `1`
   - `fs.suid_dumpable` = `0`
   コンテナは Privileged だが既定ユーザは非root。∴ 設定は `docker exec -u root` が要る。
2. **broad な `pkill -f v8fuzz` は禁止**。同一コンテナの baseline_campaign の12ワーカーまで殺す。
   停止は必ず work-dir でスコープ（`campaign_down.sh` がそうしている）。撃つ前に `pgrep` で確認。
3. **オーファン d8 を掃除する**。ワーカーがクラッシュすると子 d8 が init(ppid=1) に引き取られ、
   CPU を空回りし続ける（過去に47時間空回りした例あり）。watchdog は毎ループ ppid=1 の d8 を掃除し、
   `campaign_down.sh` も停止後に掃除する。
4. **JIT シードには d8 フラグが必須**。`--jit-fuzzing` を含む v8ProcessArgs 前提。フラグ無しで測ると
   未最適化を誤認する。watchdog の ARGS に必要フラグは入っている（`--jit-fuzzing --wasm-staging` 等）。
5. **wasm 種が 0 本ならまず `--wasm` 欠落を疑う**（WasmProgramTemplate は無効時に全除外される）。
6. **objective の主要クラスは計装バグ由来の偽陽性**。`InstrumentLoad` のレジスタ保存漏れで
   backtracking regexp 等が自己クラッシュする。トリアージ時はまずこれを疑う（脱出ではない）。
7. **診断経路の objective はフィルタしない**。診断出力 READ 偽陽性はパイプライン稼働の陽性対照
   （liveness）として残す。消す提案を繰り返さない。

## 6. objective のトリアージ（再現手順）

- objective は `crashes/*.ron`。中身のマスクは **IPC shmem 経由**なので、まず **fuzzer 出力（.ron の
  マスク）を読む**。動的計装での実測に逃げない。「in-sandbox」等のトートロジーで着地しない。
- 再現は隔離した work-dir にコピーして `v8fuzz ... --resume --debug-child` で再実行し、
  addr2line でシンボル化する。
- 上記 5-6 の偽陽性クラス（計装バグ・診断経路）をまず除外してから、本物の脱出候補を精査する。

## 7. スクリプト一覧

| スクリプト | 役割 |
|---|---|
| `ops/campaign_up.sh` | コンテナ起動/再接続 → sysctl → watchdog（= 再開）。冪等。 |
| `ops/campaign_status.sh` | 状況表示（`watch` 引数で 30秒更新） |
| `ops/campaign_down.sh` | jit campaign だけ停止 + 孤児 d8 掃除（baseline は巻き込まない） |

生の watchdog / status は `trees/jit_campaign/watchdog_jitfuzz.sh` と `.../jit_status.sh`（gitignored の
実データ側にある。ops/ の3本はそれをホストから安全に叩くラッパ）。
