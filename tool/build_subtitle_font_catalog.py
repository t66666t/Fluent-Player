"""Refresh the shipped catalog from official Google Fonts data, pinned to a commit.

Only OFL families with a license and normal TTF/OTF files are offered for direct
download. Git blob digests verify downloads; no API key or runtime backend.
"""
import datetime
import json
import re
import unicodedata
import urllib.request
from pathlib import Path


def fetch(url):
    request = urllib.request.Request(url, headers={"User-Agent": "subtitle-font-catalog"})
    return urllib.request.urlopen(request, timeout=90).read().decode()


def key(value):
    return re.sub(r"[^a-z0-9]", "", unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode().lower())


def main():
    today = datetime.date.today().isoformat()
    metadata = fetch("https://fonts.google.com/metadata/fonts")
    metadata = json.loads(metadata[metadata.index("{"):])["familyMetadataList"]
    tree = json.loads(fetch("https://api.github.com/repos/google/fonts/git/trees/main?recursive=1"))
    if tree.get("truncated"):
        raise RuntimeError("Incomplete upstream tree")
    revision = tree["sha"]
    folders = {}
    for item in tree["tree"]:
        path = item["path"]
        if path.startswith("ofl/") and path.count("/") == 2:
            folders.setdefault(path.split("/")[1], []).append(item)
    fonts = []
    subsets = {"latin": "en", "japanese": "ja", "korean": "ko", "chinese-simplified": "zh-Hans",
               "chinese-traditional": "zh-Hant", "arabic": "ar", "cyrillic": "ru", "greek": "el",
               "devanagari": "hi", "thai": "th", "hebrew": "he", "vietnamese": "vi"}
    for family in metadata:
        folder = key(family["family"])
        entries = folders.get(folder, [])
        license_entry = next((e for e in entries if e["path"].endswith("/OFL.txt")), None)
        faces = [e for e in entries if e["path"].lower().endswith((".ttf", ".otf"))
                 and not re.search(r"italic|oblique|\[.*ital", e["path"], re.I)]
        if not license_entry or not faces:
            continue
        faces.sort(key=lambda e: e["path"])
        def raw(path):
            return "https://raw.githubusercontent.com/google/fonts/" + revision + "/" + urllib.parse.quote(path)
        languages = sorted({subsets[s] for s in family["subsets"] if s in subsets})
        fonts.append({"name": family["family"], "languages": languages,
                      "weights": sorted({int(w) for w in family["fonts"] if w.isdigit()}),
                      "files": [raw(e["path"]) for e in faces], "hashes": [e["sha"] for e in faces],
                      "licenseFile": raw(license_entry["path"]), "license": "commercial",
                      "sourceUrl": "https://github.com/google/fonts/tree/" + revision + "/ofl/" + folder,
                      "verifiedOn": today})
    fonts.sort(key=lambda f: f["name"].lower())
    fonts.insert(0, {"name": "汉仪风尚黑 75W（个人版）", "languages": ["zh", "en"],
                     "license": "personal", "sourceUrl": "https://www.hanyi.com.cn/productdetail?id=10750",
                     "verifiedOn": today})
    target = Path(__file__).resolve().parents[1] / "assets/fonts/licenses/subtitle-font-catalog.json"
    target.write_text(json.dumps({"revision": revision, "fonts": fonts}, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
    print(f"Saved {len(fonts)} families from {revision}")


if __name__ == "__main__":
    main()
