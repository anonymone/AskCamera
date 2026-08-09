#!/usr/bin/env bash
# 下载 YOLO-World Core ML 模型到 Models/（约 150MB，模型文件不入 git）。
# 模型来源: https://github.com/john-rocky/CoreML-Models (YOLO-World: GPL-3.0)
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p Models
cd Models

BASE="https://github.com/john-rocky/CoreML-Models/releases/download/yolo-models-v1"

for f in yoloworld_detector.mlpackage.zip clip_text_encoder.mlpackage.zip clip_vocab.json.zip; do
    name="${f%.zip}"
    if [ -e "$name" ]; then
        echo "已存在，跳过: $name"
        continue
    fi
    echo "下载 $f ..."
    curl -fL -o "$f" "$BASE/$f"
    unzip -qo "$f"
    rm "$f"
done

echo "完成。模型文件:"
ls -la
