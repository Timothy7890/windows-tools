#!/usr/bin/env python3
"""Web gallery for grayscale semantic/instance label PNGs."""

from __future__ import annotations

import argparse
import colorsys
import html
import io
import os
import re
from functools import lru_cache
from pathlib import Path

import numpy as np
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse, HTMLResponse, Response
from PIL import Image


# Canonical label palette from PlantSegNeRF CUDA viewer:
# plantsegnerf_pp_cuda/src/testbed_nerf.cu (semantic and instance share it).
PALETTE_FIXED = np.array(
    [
        [255, 255, 255],  #  0 white
        [255, 0, 0],      #  1 red
        [0, 128, 255],    #  2 dodger blue
        [0, 204, 0],      #  3 green
        [255, 204, 0],    #  4 amber
        [0, 255, 255],    #  5 cyan
        [255, 0, 255],    #  6 magenta
        [255, 128, 0],    #  7 orange
        [102, 0, 255],    #  8 violet
        [0, 255, 102],    #  9 spring green
        [204, 255, 0],    # 10 yellow-green
        [0, 102, 204],    # 11 steel blue
        [255, 0, 102],    # 12 crimson
        [153, 77, 0],     # 13 brown
        [0, 204, 153],    # 14 teal
        [204, 0, 153],    # 15 deep pink
        [102, 204, 0],    # 16 lime
        [51, 51, 255],    # 17 royal blue
        [255, 102, 102],  # 18 salmon
        [153, 0, 102],    # 19 plum
        [0, 153, 102],    # 20 sea green
        [255, 153, 204],  # 21 pink
        [102, 255, 204],  # 22 aquamarine
        [204, 153, 255],  # 23 lavender
    ],
    dtype=np.uint8,
)


def label_color(label: int) -> tuple[int, int, int]:
    """Match the CUDA viewer palette, with ignore label 255 shown dark."""
    if label == 255:
        return (28, 28, 32)
    if 0 <= label < len(PALETTE_FIXED):
        return tuple(int(v) for v in PALETTE_FIXED[label])
    hue = ((label - len(PALETTE_FIXED)) * 0.618033988) % 1.0
    rgb = colorsys.hsv_to_rgb(hue, 1.0, 1.0)
    return tuple(int(round(v * 255)) for v in rgb)


def natural_key(path: Path) -> list[object]:
    return [
        int(part) if part.isdigit() else part.lower()
        for part in re.split(r"(\d+)", path.name)
    ]


def find_pngs(png_dir: Path) -> list[Path]:
    files = sorted(
        (p for p in png_dir.iterdir() if p.is_file() and p.suffix.lower() == ".png"),
        key=natural_key,
    )
    if not files:
        raise ValueError(f"目录中没有 PNG: {png_dir}")
    return files


def load_labels(path: Path) -> np.ndarray:
    with Image.open(path) as image:
        labels = np.asarray(image)
    if labels.ndim == 3:
        labels = labels[..., 0]
    if labels.ndim != 2:
        raise ValueError(f"不是二维标签图: {path} shape={labels.shape}")
    return labels.astype(np.int64, copy=False)


@lru_cache(maxsize=24)
def colorized_png(path_str: str, mtime_ns: int) -> bytes:
    del mtime_ns  # cache invalidation key
    labels = load_labels(Path(path_str))
    colored = np.zeros((*labels.shape, 3), dtype=np.uint8)
    for label in np.unique(labels):
        colored[labels == label] = label_color(int(label))
    output = io.BytesIO()
    Image.fromarray(colored, "RGB").save(output, format="PNG")
    return output.getvalue()


@lru_cache(maxsize=24)
def label_summary(path_str: str, mtime_ns: int) -> tuple[tuple[int, int], ...]:
    del mtime_ns
    values, counts = np.unique(load_labels(Path(path_str)), return_counts=True)
    return tuple((int(value), int(count)) for value, count in zip(values, counts))


PAGE = """<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>PlantSegNeRF Mask Viewer</title>
  <style>
    :root { color-scheme: dark; font-family: ui-sans-serif, system-ui, sans-serif; }
    * { box-sizing: border-box; }
    body { margin: 0; background: #111318; color: #e8eaf0; }
    header { padding: 12px 18px; background: #1a1d24; border-bottom: 1px solid #30343e; }
    h1 { margin: 0 0 4px; font-size: 18px; }
    .path { color: #9ba3b4; font: 12px ui-monospace, monospace; overflow-wrap: anywhere; }
    main { display: grid; grid-template-columns: minmax(0, 1fr) 250px; height: calc(100vh - 69px); }
    .viewer { min-width: 0; display: flex; flex-direction: column; padding: 12px; }
    .toolbar { display: flex; gap: 8px; align-items: center; margin-bottom: 10px; }
    button { border: 1px solid #454b59; border-radius: 6px; padding: 6px 11px;
             background: #252a34; color: inherit; cursor: pointer; }
    button:hover { background: #303746; }
    #position { min-width: 92px; text-align: center; color: #bbc2d0; }
    #slider { flex: 1; min-width: 80px; }
    #filename { font: 13px ui-monospace, monospace; color: #dce2ee; }
    .stage { flex: 1; min-height: 0; display: flex; align-items: center; justify-content: center;
             overflow: hidden; border-radius: 8px; background:
             repeating-conic-gradient(#20242c 0 25%, #171a20 0 50%) 50% / 24px 24px; }
    #mask { max-width: 100%; max-height: 100%; object-fit: contain; }
    aside { overflow: auto; padding: 13px; border-left: 1px solid #30343e; background: #171a20; }
    aside h2 { margin: 0 0 10px; font-size: 14px; }
    .legend { display: grid; grid-template-columns: 22px 1fr auto; gap: 6px 8px;
              align-items: center; margin-bottom: 7px; font-size: 12px; }
    .swatch { width: 20px; height: 20px; border: 1px solid #555b68; border-radius: 3px; }
    .count { color: #929bad; font-variant-numeric: tabular-nums; }
    .hint { color: #7f889a; font-size: 11px; line-height: 1.5; margin-top: 16px; }
    @media (max-width: 760px) {
      main { grid-template-columns: 1fr; height: auto; }
      .viewer { height: 75vh; }
      aside { border-left: 0; border-top: 1px solid #30343e; }
    }
  </style>
</head>
<body>
  <header>
    <h1>__MASK_TYPE__ Mask · <span id="filename"></span></h1>
    <div class="path">__PNG_DIR__</div>
  </header>
  <main>
    <section class="viewer">
      <div class="toolbar">
        <button id="prev">← 上一张</button>
        <span id="position"></span>
        <button id="next">下一张 →</button>
        <input id="slider" type="range" min="0" max="__MAX_INDEX__" value="0">
        <button id="mode">显示灰度</button>
      </div>
      <div class="stage"><img id="mask" alt="mask"></div>
    </section>
    <aside>
      <h2>当前图像标签</h2>
      <div id="legend"></div>
      <div class="hint">方向键：前后切换<br>Home / End：首张 / 末张<br>G：灰度/彩色切换</div>
    </aside>
  </main>
  <script>
    const total = __TOTAL__;
    let current = 0, raw = false;
    const image = document.getElementById('mask');
    const slider = document.getElementById('slider');

    async function show(index) {
      current = Math.max(0, Math.min(total - 1, index));
      slider.value = current;
      image.src = `/image/${current}?raw=${raw ? 1 : 0}&v=${Date.now()}`;
      const meta = await fetch(`/meta/${current}`).then(r => r.json());
      document.getElementById('filename').textContent = meta.name;
      document.getElementById('position').textContent = `${current + 1} / ${total}`;
      document.getElementById('legend').innerHTML = meta.labels.map(item =>
        `<div class="legend"><span class="swatch" style="background:${item.color}"></span>` +
        `<span>${item.label}${item.label === 255 ? ' (ignore)' : ''}</span>` +
        `<span class="count">${item.percent.toFixed(2)}%</span></div>`
      ).join('');
    }
    document.getElementById('prev').onclick = () => show(current - 1);
    document.getElementById('next').onclick = () => show(current + 1);
    slider.oninput = () => show(Number(slider.value));
    document.getElementById('mode').onclick = event => {
      raw = !raw;
      event.target.textContent = raw ? '显示彩色' : '显示灰度';
      show(current);
    };
    document.addEventListener('keydown', event => {
      if (event.key === 'ArrowLeft') show(current - 1);
      else if (event.key === 'ArrowRight') show(current + 1);
      else if (event.key === 'Home') show(0);
      else if (event.key === 'End') show(total - 1);
      else if (event.key.toLowerCase() === 'g') document.getElementById('mode').click();
    });
    show(0);
  </script>
</body>
</html>
"""


def build_app(png_dir: Path, mask_type: str) -> FastAPI:
    files = find_pngs(png_dir)
    app = FastAPI(title="PlantSegNeRF Mask Viewer")

    def file_at(index: int) -> Path:
        if index < 0 or index >= len(files):
            raise HTTPException(status_code=404, detail="图像索引越界")
        return files[index]

    @app.get("/", response_class=HTMLResponse)
    def page() -> str:
        return (
            PAGE.replace("__MASK_TYPE__", html.escape(mask_type.capitalize()))
            .replace("__PNG_DIR__", html.escape(str(png_dir)))
            .replace("__MAX_INDEX__", str(len(files) - 1))
            .replace("__TOTAL__", str(len(files)))
        )

    @app.get("/image/{index}")
    def image(index: int, raw: int = 0):
        path = file_at(index)
        if raw:
            return FileResponse(path)
        stat = path.stat()
        return Response(
            content=colorized_png(str(path), stat.st_mtime_ns),
            media_type="image/png",
            headers={"Cache-Control": "no-store"},
        )

    @app.get("/meta/{index}")
    def meta(index: int) -> dict:
        path = file_at(index)
        stat = path.stat()
        summary = label_summary(str(path), stat.st_mtime_ns)
        total = sum(count for _, count in summary)
        return {
            "name": path.name,
            "labels": [
                {
                    "label": label,
                    "count": count,
                    "percent": count * 100.0 / max(total, 1),
                    "color": "#{:02x}{:02x}{:02x}".format(*label_color(label)),
                }
                for label, count in summary
            ],
        }

    return app


def main() -> None:
    parser = argparse.ArgumentParser(
        description="彩色预览 semantic/instance/instance_g 灰度 PNG"
    )
    parser.add_argument("--png-dir", required=True, type=Path)
    parser.add_argument(
        "--mask-type",
        choices=("semantic", "instance", "instance_g"),
        required=True,
    )
    parser.add_argument("--host", default="0.0.0.0")
    parser.add_argument("--port", type=int, default=7007)
    args = parser.parse_args()

    png_dir = args.png_dir.expanduser().resolve()
    if not png_dir.is_dir():
        parser.error(f"PNG 目录不存在: {png_dir}")
    files = find_pngs(png_dir)
    print(f"[mask-viewer] {args.mask_type}: {len(files)} 张 -> {png_dir}")
    print(f"[mask-viewer] http://localhost:{args.port}")
    uvicorn.run(build_app(png_dir, args.mask_type), host=args.host, port=args.port)


if __name__ == "__main__":
    main()
