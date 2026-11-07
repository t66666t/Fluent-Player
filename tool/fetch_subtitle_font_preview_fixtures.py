"""Explicitly fetch five small official specimens for native rendering checks.

Run from any directory, then set SUBTITLE_FONT_NATIVE_PREVIEWS=1 and run:
flutter test --no-pub test/subtitle_font_preview_native_test.dart
Nothing downloaded here is included in application assets.
"""

import hashlib
import json
import re
from pathlib import Path
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen

DESTINATION = Path(__file__).resolve().parents[1] / "build/font-preview-verification"
USER_AGENT = "FluentPlayer-FontPreview/1.0"
SAMPLES = [
    ("zh-Hans", "Noto Sans SC", "字幕预览 Aa"),
    ("zh-Hant", "Noto Sans TC", "字幕預覽 Aa"),
    ("ja", "Noto Sans JP", "字幕プレビュー Aa"),
    ("ko", "Noto Sans KR", "자막 미리보기 Aa"),
    ("en", "Inter", "Subtitle preview Aa"),
]


def fetch(url, limit):
    with urlopen(Request(url, headers={"User-Agent": USER_AGENT}), timeout=25) as response:
        data = response.read(limit + 1)
    if len(data) > limit:
        raise ValueError("Preview response exceeds its size limit")
    return data


def main():
    DESTINATION.mkdir(parents=True, exist_ok=True)
    manifest = []
    for language, family, text in SAMPLES:
        css_url = "https://fonts.googleapis.com/css2?" + urlencode({
            "family": family + ":wght@400", "text": text,
        })
        css = fetch(css_url, 32 * 1024)
        urls = re.findall(r"url\(([^)]+)\)", css.decode("utf-8"))
        if len(urls) != 1:
            raise ValueError("Expected one specimen font")
        url = urls[0].strip("\"'")
        origin = urlparse(url)
        if origin.scheme != "https" or origin.hostname != "fonts.gstatic.com":
            raise ValueError("Unexpected specimen origin")
        data = fetch(url, 256 * 1024)
        if data[:4] not in (b"\x00\x01\x00\x00", b"OTTO"):
            raise ValueError("Preview must be a native TTF/OTF font")
        filename = language + ".ttf"
        (DESTINATION / filename).write_bytes(data)
        (DESTINATION / (language + ".css")).write_bytes(css)
        manifest.append({
            "language": language, "family": family, "text": text,
            "cssUrl": css_url, "fontUrl": url, "file": filename,
            "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
        })
        print(language, family, len(data))
    (DESTINATION / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
