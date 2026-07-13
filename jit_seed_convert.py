#!/usr/bin/env python3
"""
jit_seed_convert.py

Fuzzilli が生成・lift した .js コーパスを、SbxBrk の注入キャンペーン用シードに変換する。

前提となるシードの形（私たちの4テンプレが出す骨格）:
    %PrepareFunctionForOptimization(f);
    f(...); f(...);                 // warmup(インタプリタ実行)
    %OptimizeFunctionOnNextCall(f); // or %OptimizeMaglevOnNextCall(f) / %WasmTierUpFunction(f)
    f(...);                         // 最適化済み実行 ← ここで注入したい

各 .js について:
  1. 最後の最適化トリガを探す。
       JS   : %OptimizeFunctionOnNextCall(FN) / %OptimizeMaglevOnNextCall(FN)
       wasm : %WasmTierUpFunction(FN)
     無ければ「骨格なし」で捨てる。
  2. 計装 jit d8 で、FN が注入点で最適化を"維持"しているか判定する。
       JS   : --trace-opt を回し、FN の最後の最適化イベントが "completed compiling"
              (deoptimizing/bailout でない) か。
       wasm : トリガ直後に %IsLiftoffFunction(FN) プローブを挿して回し、Liftoff でない
              (= TurboFan に上がっている) か。wasm は deopt しないのでこの tier 確認が相当。
  3. 通ったものだけ、トリガ行の直後に FuzzerInjectionPoint(1); を挿入して out_dir に出す。

使い方:
    D8=<jit計装d8> LD_LIBRARY_PATH=<libv8fuzz_runtimeのdir> \
        python3 jit_seed_convert.py <lifted_corpus_dir> <out_seed_dir>
"""
import os
import re
import subprocess
import sys
import tempfile

D8 = os.environ.get("D8", "/work/trees/jit_campaign/v8-build/out/fuzzing-build/d8")
# 骨格が最適化されるのに必要な d8 フラグ（特に --jit-fuzzing）。--sandbox-fuzzing で計装が有効。
D8_FLAGS = (
    "--sandbox-fuzzing --allow-natives-syntax --fuzzing --expose-gc --omit-quit "
    "--future --harmony --js-staging --jit-fuzzing --wasm-staging"
).split()
TRACE_FLAGS = ["--trace-opt", "--trace-deopt"]

ENV = dict(os.environ)
ENV.setdefault("LD_LIBRARY_PATH", "/work/trees/jit_campaign/fuzzer/target/release")

RUN_TIMEOUT = 25

# JS: TurboFan / Maglev、wasm: WasmTierUpFunction。最後に現れるものを最適化点とみなす。
TRIGGER_RE = re.compile(
    r"%(OptimizeFunctionOnNextCall|OptimizeMaglevOnNextCall|WasmTierUpFunction)\((\w+)\)"
)


def find_last_trigger(text):
    """(match, kind, fn) を返す。無ければ (None, None, None)。"""
    last = None
    for m in TRIGGER_RE.finditer(text):
        last = m
    if last is None:
        return None, None, None
    kind = "wasm" if last.group(1) == "WasmTierUpFunction" else "js"
    return last, kind, last.group(2)


def _run_d8(path):
    """d8 で path を実行し、stdout+stderr を返す。失敗時 None。"""
    try:
        p = subprocess.run(
            [D8] + D8_FLAGS + TRACE_FLAGS + [path],
            capture_output=True, text=True, timeout=RUN_TIMEOUT, env=ENV,
        )
        return p.stdout + p.stderr
    except Exception:
        return None


def stays_optimized_js(js_path, fn):
    """--trace-opt を見て、FN の最後の最適化イベントが completed(非deopt) か。"""
    out = _run_d8(js_path)
    if out is None:
        return False
    verdict = None
    tag = "<JSFunction %s " % fn
    for line in out.splitlines():
        if tag not in line:
            continue
        if "completed compiling" in line:
            verdict = "opt"
        elif "deoptimizing" in line or "bailout" in line:
            verdict = "deopt"
    return verdict == "opt"


def stays_optimized_wasm(text, trigger, fn):
    """トリガ直後に %IsLiftoffFunction プローブを挿して回し、TurboFan 化を確認する。"""
    nl = text.index("\n", trigger.end())
    probe = (
        'try { print("WTIER:" + %%IsLiftoffFunction(%s)); } '
        'catch (e) { print("WTIER:err"); }\n' % fn
    )
    probed = text[: nl + 1] + probe + text[nl + 1:]
    tmp = None
    try:
        with tempfile.NamedTemporaryFile("w", suffix=".js", delete=False) as tf:
            tf.write(probed)
            tmp = tf.name
        out = _run_d8(tmp)
    finally:
        if tmp:
            os.unlink(tmp)
    if out is None:
        return False
    # Liftoff でない(=false) と出れば TurboFan。true/err は不採用。
    return "WTIER:false" in out


def insert_injection_point(text, trigger):
    """トリガ行の直後に FuzzerInjectionPoint(1); を挿入し、続く最適化済み呼び出しで注入発火。"""
    nl = text.index("\n", trigger.end())
    return text[: nl + 1] + "FuzzerInjectionPoint(1);\n" + text[nl + 1:]


def main():
    if len(sys.argv) < 3:
        print("usage: jit_seed_convert.py <lifted_corpus_dir> <out_seed_dir>")
        return 2
    corpus_dir, out_dir = sys.argv[1], sys.argv[2]
    os.makedirs(out_dir, exist_ok=True)

    n = no_skeleton = rejected = 0
    used_js = used_wasm = 0
    for name in sorted(os.listdir(corpus_dir)):
        if not name.endswith(".js"):
            continue
        n += 1
        path = os.path.join(corpus_dir, name)
        text = open(path, errors="ignore").read()

        trigger, kind, fn = find_last_trigger(text)
        if trigger is None:
            no_skeleton += 1
            continue

        if kind == "js":
            ok = stays_optimized_js(path, fn)
        else:
            ok = stays_optimized_wasm(text, trigger, fn)

        if not ok:
            rejected += 1
            continue

        open(os.path.join(out_dir, name), "w").write(
            insert_injection_point(text, trigger)
        )
        if kind == "js":
            used_js += 1
        else:
            used_wasm += 1

    used = used_js + used_wasm
    print(
        "入力=%d  使える(最適化維持+マーカー+出力)=%d (JS=%d wasm=%d)  不採用=%d  骨格なし=%d"
        % (n, used, used_js, used_wasm, rejected, no_skeleton)
    )
    print("出力: %s (%d 本)" % (out_dir, used))
    return 0


if __name__ == "__main__":
    sys.exit(main())
