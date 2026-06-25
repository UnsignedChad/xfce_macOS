#!/usr/bin/env python3
"""Download up to N 4K (>=3840x2160) landscape wallpapers from dharmx/walls."""
import json, os, struct, sys, urllib.request, random

DEST = os.path.expanduser("~/Pictures/Wallpapers")
CATEGORIES = ["mountain", "nature", "aerial", "fogsmoke", "cold", "calm"]
TARGET = int(sys.argv[1]) if len(sys.argv) > 1 else 100
MINW, MINH = 3840, 2160
UA = {"User-Agent": "Mozilla/5.0 wallpaper-fetch"}

def get(url):
    req = urllib.request.Request(url, headers=UA)
    return urllib.request.urlopen(req, timeout=30).read()

def dims(buf):
    """Return (w,h) for JPEG/PNG bytes, or None."""
    if buf[:8] == b"\x89PNG\r\n\x1a\n":
        w, h = struct.unpack(">II", buf[16:24]); return w, h
    if buf[:2] == b"\xff\xd8":  # JPEG
        i = 2; n = len(buf)
        while i < n:
            while i < n and buf[i] != 0xFF: i += 1
            while i < n and buf[i] == 0xFF: i += 1
            if i >= n: break
            m = buf[i]; i += 1
            if 0xC0 <= m <= 0xCF and m not in (0xC4, 0xC8, 0xCC):
                h, w = struct.unpack(">HH", buf[i+3:i+7]); return w, h
            ln = struct.unpack(">H", buf[i:i+2])[0]; i += ln
    return None

# gather candidate URLs
urls = []
for cat in CATEGORIES:
    try:
        data = json.loads(get(f"https://api.github.com/repos/dharmx/walls/contents/{cat}?per_page=100"))
        for x in data:
            if x["name"].lower().endswith((".jpg", ".jpeg", ".png")):
                urls.append(x["download_url"])
    except Exception as e:
        print(f"  ! {cat}: {e}")
random.shuffle(urls)
print(f"candidates: {len(urls)}  target: {TARGET} 4K (>= {MINW}x{MINH})")

kept = skipped = failed = 0
for url in urls:
    if kept >= TARGET: break
    try:
        buf = get(url)
        d = dims(buf)
        if d and d[0] >= MINW and d[1] >= MINH:
            kept += 1
            with open(f"{DEST}/landscape-{kept:03d}.jpg", "wb") as f:
                f.write(buf)
            if kept % 10 == 0: print(f"  kept {kept}/{TARGET} ...")
        else:
            skipped += 1
    except Exception:
        failed += 1
print(f"DONE: kept={kept} skipped(non-4K)={skipped} failed={failed}")
