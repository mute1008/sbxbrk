# JIT/wasm サンドボックス読みシード生成 — 設計と使い方

## 目的

SbxBrk 論文が未対応とした **JIT/最適化経路の V8 Sandbox Bypass** を探すためのシードを作る。
狙いは「**最適化された機械語（TurboFan/Maglev/wasm TurboFan）がサンドボックスを密に読む**関数」を含む
JS シードで、その読みを SbxBrk のアセンブラレベル fault injection（`InstrumentLoad`）が破壊できること。
最適化コードは BCE / キャッシュした length・map・ポインタ / elements-kind 等をサンドボックス上のデータに
**仮定**するので、その値を注入で書き換えると OOB / type-confusion / escape に化ける可能性がある。

計装は SbxBrk のもので、`-DSBXBRK_NO_INSTRUMENT_ASSEMBLER` を**外した**ビルド（= JIT campaign 用の
`v8-build`）で JIT 機械語まで計装が効く。論文キャンペーンは同フラグを定義（計装 OFF）した別ビルド。

## 大枠

パイプラインは3段。**生成 → 種変換(フィルタ) → 注入ファジング**。

```
 Fuzzilli(coverage d8)          jit_seed_convert.py            v8fuzz(jit計装d8)
  4テンプレで.js生成      →      骨格を残す種だけ抽出      →     注入発火でバイパス探索
  gen_run/corpus/*.js           +FuzzerInjectionPoint(1)        jit_seeds/ を種に
                                 jit_seeds/*.js
```

### シードテンプレート (`fuzzilli/Sources/Fuzzilli/Profiles/SbxBrkJITTemplates.swift`)

`V8Profile.swift` の `additionalProgramTemplates` に登録した4本。各々「最適化される関数＋
サンドボックス読み＋`%Optimize*`/`%WasmTierUpFunction` の骨格」を出す。

| テンプレ | tier | 骨格トリガ | 読みの作り方 |
|---|---|---|---|
| `TurbofanSandboxReadFuzzer` | TurboFan | `%OptimizeFunctionOnNextCall` | 型付き配列に対する**長さ境界ループ** `for(i<a.length) sum+=a[i]`（BCE＋backing-store読み）＋`b.build`で多様化 |
| `MaglevSandboxReadFuzzer` | Maglev | `%OptimizeMaglevOnNextCall` | 同上、subject関数を共有しトリガのみ差し替え |
| `WasmTurbofanFuzzer`(上流) | wasm TurboFan | `%WasmTierUpFunction` | wasm関数を tier-up 前に1回実行→tier-up。wasm-gc型群も生成 |
| `WasmInJsInlineSandboxReadFuzzer` | JS(wasmインライン) | `%OptimizeFunctionOnNextCall` | JS関数が小さいwasm関数を繰り返し呼ぶ→TurboFanがwasmをJIT JSにインライン。**同一引数**でwarmup/最適化しdeopt回避（上流`WasmInJsInliningFuzzer`は意図的にdeoptするので流用不可、これは非deopt版） |

**設計上の要点**:
- 具体的な**型付き引数**を渡して本体を確実に実行させる（warmupがインタプリタで通り、本体のカバレッジも取れる）。
- warmupと最適化後の呼び出しは**同一引数**（lazy deopt を避け、注入点で最適化を維持する）。
- 結果を accumulate して return（wasm/配列読みが DCE で消えないように）。

## 使い方

すべてコンテナ `v8-heap-sandbox-artifact-env` 内、パスは `/work/trees/jit_campaign/...`。
バイナリ: coverage d8 = `v8-fuzzilli/out/fuzzbuild/d8`、jit計装d8 = `v8-build/out/fuzzing-build/d8`、
FuzzilliCli = `fuzzilli/.build/release/FuzzilliCli`、v8fuzz = `fuzzer/target/release/v8fuzz`
(要 `LD_LIBRARY_PATH=fuzzer/target/release`)。

### 0. FuzzilliCli ビルド（テンプレを変えた時）

```
cd /work/trees/jit_campaign/fuzzilli
/opt/swift-6.2/usr/bin/swift build -c release
```
注意: Swift は **6.2**（`/opt/swift-6.2`。デフォルト6.0.3は trailing comma を弾く）。
稼働中の FuzzilliCli があるとリンクが `Text file busy` で失敗するので先に止める。

### 1. 生成 (coverage d8 で .js コーパスを作る)

```
FuzzilliCli --profile=v8 --engine=hybrid --corpusGenerationIterations=1 --wasm \
  --storagePath=<out> --overwrite \
  --consecutiveMutations=0 --minimizationLimit=1.0 \
  --jobs=4 --timeout=300,900 \
  <coverage d8>
```

**各フラグの理由（ここが本質。全部意味がある）**:

- **`--wasm` は必須**。無いと FuzzilliCli が **WasmProgramTemplate を全部フィルタで除外**する
  (`main.swift`: `enableWasm = args.has("--wasm")` → `!enableWasm` なら `filter{ !($0 is WasmProgramTemplate) }`)。
  自作 wasm テンプレも消えて生成物に wasm が0本になる。`--wasm-staging`(d8側)とは別物。
- **組み込みテンプレの append を無効化済み** (`main.swift`)。標準では `ProgramTemplates`(JIT1Function/
  WasmCodegen/JSONFuzzer… 約15種, 総weight~51)が全部プールに足され、自作4本が少数派になる。
  我々のシードは自作テンプレ**だけ**であるべきなのでループをコメントアウトした。復帰は同箇所を戻す。
- **`--engine=hybrid`**: `fuzzOne()` が毎回テンプレを1本インスタンス化して生成する。mutationエンジン
  (デフォルト)はコードジェネレータ＋変異が主でテンプレはたまにしか使わない。
- **`--corpusGenerationIterations=1`**: 初期の corpusGeneration（GenerativeEngine=コードジェネレータの
  ブートストラップ）を最短で抜けて hybrid 主フェーズへ。デフォルト100は「新カバレッジを100回連続で
  出せなくなるまで」続く＝1.8Mエッジが枯れるまで長い。**`--consecutiveMutations=0` と一体の設定**で、
  変異しない我々にはブートストラップcorpusは使われないので小さくてよい。
- **`--consecutiveMutations=0` / `--minimizationLimit=1.0`**: 生成後の変異・最小化で `%Optimize*` 骨格が
  剥がれるのを防ぐ。代償は本体多様性が「テンプレ1回の`b.build`」だけになる点（下記「未決」参照）。

**起動の注意**: バックグラウンド起動は `docker exec -d` で完全デタッチする。`nohup ... &` だと
BashツールのタイムアウトSIGTERMが子まで波及して落ちる。

### 2. 種変換 (最適化維持の種だけ抽出＋注入マーカー挿入)

```
D8=<jit計装d8> LD_LIBRARY_PATH=<fuzzerのdir> \
  python3 jit_seed_convert.py <corpus_dir> <out_seed_dir>
```

`jit_seed_convert.py`（このリポジトリで新規作成）がやること:
1. 各 .js の最後の最適化トリガを探す（`%OptimizeFunctionOnNextCall`/`%OptimizeMaglevOnNextCall`/
   `%WasmTierUpFunction`）。無ければ捨てる。
2. jit計装d8 で「注入点で最適化を維持しているか」を判定:
   - JS: `--trace-opt` を見て、その関数の最後の最適化イベントが `completed compiling`(非deopt)か。
   - wasm: トリガ直後に `%IsLiftoffFunction(fn)` プローブを挿し、Liftoff でない(=TurboFan化)か。
3. 通ったものだけ、トリガ行の直後に `FuzzerInjectionPoint(1);` を挿入して出力。

出力例: `入力=229 使える=127 (JS=115 wasm=12) 不採用=47 骨格なし=55`。

### 3. 注入ファジング (jit計装d8 で注入を発火させ探索)

```
LD_LIBRARY_PATH=<fuzzerのdir> v8fuzz fuzz --log-level info --timeout 2000 \
  --work-dir <fresh> --seed-dir <out_seed_dir> -- \
  <jit計装d8> --fuzzing --sandbox-fuzzing --single-threaded --allow-natives-syntax \
  --expose-gc --future --harmony --js-staging --jit-fuzzing --wasm-staging --omit-quit
```

注入マスクは v8fuzz の **IPC shmem 経由**で渡る（スタンドアロン d8 の fake FuzzerIpc では発火しない）。
発火の確認は v8fuzz ログの `TestCaseExecutionMetadata`:
```
total_number_of_intercepted_loads: 7017, last_executed_injection_point: Some(InjectionPointId(1)),
total_executed_injection_point: 1
```
intercepted_loads が「最適化コードが読んだサンドボックスロード数」、InjectionPointId(1) が挿入した
マーカーの発火。`objectives` が増えればサンドボックス違反（バイパス候補）。

## 実測（このパイプラインの検証結果）

- 生成: 4テンプレのみで corpus 229本、全4種の骨格が出る（TF/Maglev/WasmTierUp/WasmInline）。
- 種変換: 127本が最適化維持で採用（JS=115, wasm=12）、全て `FuzzerInjectionPoint(1)` 挿入済み。
- 注入: 全種で InjectionPointId(1) 発火。intercepted_loads は **JS種 3000〜7000 / wasm種 31〜122**。

## 未決の論点（意図的に保留、勝手に決めない）

- **wasm種の読みが薄い**（intercepted 31〜122）。wasm線形メモリの境界は "trusted" で最適化コードの
  サンドボックス読みが少ない。バイパス面は WasmGC struct/array（サンドボックス内）なので、テンプレを
  WasmGC 読み中心に振ると濃くできるはず。要テンプレ調整。
- **本体多様性 vs 骨格保持**。`--consecutiveMutations=0` で骨格は守れるが、本体多様性がテンプレ1回の
  `b.build` ランダム生成だけになる。変異を入れる(>0)と mutator/splice で多様になるが `%Optimize` が
  剥がれやすい。入れるなら「剥がれたら種変換側で最適化トリガを再挿入」等の対策が要る。
- **deopt歩留まり**。`b.build` のランダム後半が最適化コードの map 仮定を自分で壊し "wrong map" deopt を
  起こすことがある。自作テンプレのみなら歩留まり55%程度。読みの主要部を `b.build` の**前**に置く等で改善余地。
```
