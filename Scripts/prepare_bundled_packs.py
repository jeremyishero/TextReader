#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
CI 用：准备随 App 分发的内置语音包（BundledVoicePacks/<packId>/）。

来源：hf-mirror 下载 fp32 onnx + 小文件（tokens/lexicon/dict/fsts）→
      onnxruntime 动态量化为 int8（体积约 1/4，~116MB → ~35MB）→ 组装进 BundledVoicePacks/。
特例：melo 直接用官方 int8（model.int8.onnx）；aishell3 无 hf 仓库，从 GitHub Release 下载精简 zip。

用前：pip install onnxruntime onnx
产物：TextReader/BundledVoicePacks/<packId>/（模型只含正式+专用音色所需的最小集合）
"""
import json
import os
import shutil
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # repo 根（TextReader/）
OUT = os.path.join(ROOT, "BundledVoicePacks")
MIRROR = "https://hf-mirror.com"

# (packId, hf repo, 模型文件名, 是否量化)
PACKS = [
    ("theresa",  "csukuangfj/vits-zh-hf-theresa",   "theresa.onnx", True),
    ("eula",     "csukuangfj/vits-zh-hf-eula",      "eula.onnx", True),
    ("doom",     "csukuangfj/vits-zh-hf-doom",      "doom.onnx", True),
    ("keqing",   "csukuangfj/vits-zh-hf-keqing",    "keqing.onnx", True),
    ("echo",     "csukuangfj/vits-zh-hf-echo",      "echo.onnx", True),
    ("fanchen-c","csukuangfj/vits-zh-hf-fanchen-C", "vits-zh-hf-fanchen-C.onnx", True),
    ("zh-ll",    "csukuangfj/sherpa-onnx-vits-zh-ll", "model.onnx", True),
    ("melo",     "csukuangfj/vits-melo-tts-zh_en",  "model.int8.onnx", False),
]
AISHELL3_RELEASE_URL = os.environ.get(
    "AISHELL3_PACK_URL",
    "https://github.com/jeremyishero/TextReader/releases/download/voicepacks/aishell3-min.zip")
SMALL_FILE_MAX = 8 * 1024 * 1024   # 小文件上限（tokens/lexicon/fsts；dict/ 内文件都很小）


def download(url, dst):
    print(f"  ↓ {url.split('/')[-1]} ...", flush=True)
    tmp = dst + ".part"
    subprocess.run(["curl", "-sL", "--fail", "--retry", "3", "-o", tmp, url], check=True)
    os.replace(tmp, dst)


def hf_tree(repo):
    req = urllib.request.Request(f"{MIRROR}/api/models/{repo}/tree/main?recursive=true")
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def prepare(pack_id, repo, model_name, quantize):
    dst = os.path.join(OUT, pack_id)
    os.makedirs(dst, exist_ok=True)
    # 1) 模型
    model_path = os.path.join(dst, model_name)
    if not os.path.isfile(model_path):
        download(f"{MIRROR}/{repo}/resolve/main/{model_name}", model_path)
    # 2) 量化
    if quantize:
        from onnxruntime.quantization import quantize_dynamic, QuantType
        qpath = os.path.join(dst, model_name.replace(".onnx", ".int8.onnx"))
        if not os.path.isfile(qpath):
            print(f"  quantize {pack_id} ...", flush=True)
            quantize_dynamic(model_path, qpath, weight_type=QuantType.QInt8)
        os.remove(model_path)   # 只保留 int8，省 bundle 体积
        model_path = qpath
    print(f"  model: {os.path.getsize(model_path)/1048576:.1f}MB")
    # 3) 小文件（tokens/lexicon/fsts/dict/**）
    for f in hf_tree(repo):
        if f.get("type") != "file" or f.get("size", 0) > SMALL_FILE_MAX:
            continue
        name = f["path"]
        if name.endswith(".onnx") or name == model_name:
            continue
        target = os.path.join(dst, name)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        if not os.path.isfile(target):
            download(f"{MIRROR}/{repo}/resolve/main/{name}", target)
    print(f"  done {pack_id}")
    return model_path


def prepare_aishell3():
    dst = os.path.join(OUT, "aishell3")
    os.makedirs(dst, exist_ok=True)
    ztmp = os.path.join(OUT, "_aishell3.zip")
    download(AISHELL3_RELEASE_URL, ztmp)
    subprocess.run([sys.executable, "-c",
                    f"import zipfile;zipfile.ZipFile(r'{ztmp}').extractall(r'{OUT}/_aishell3_x')"], check=True)
    src = os.path.join(OUT, "_aishell3_x", "aishell3")
    for name in os.listdir(src):
        if name == "rule.far":
            continue   # rule_fars 未被 App 使用，且 180MB
        s = os.path.join(src, name)
        if os.path.isfile(s):
            shutil.copy2(s, os.path.join(dst, name))
    shutil.rmtree(os.path.join(OUT, "_aishell3_x"), ignore_errors=True)
    os.remove(ztmp)
    print("  done aishell3")


def main():
    os.makedirs(OUT, exist_ok=True)
    for pack_id, repo, model, q in PACKS:
        print(f"=== {packId_fmt(pack_id)} ===")
        prepare(pack_id, repo, model, q)
    print("=== aishell3 ===")
    prepare_aishell3()
    # 汇总
    total = 0
    for d in sorted(os.listdir(OUT)):
        p = os.path.join(OUT, d)
        if not os.path.isdir(p):
            continue
        sz = sum(os.path.getsize(os.path.join(r, f)) for r, _ds, fs in os.walk(p) for f in fs)
        total += sz
        print(f"  {d}: {sz/1048576:.1f}MB")
    print(f"TOTAL: {total/1048576:.1f}MB")


def packId_fmt(x):
    return x


if __name__ == "__main__":
    main()
