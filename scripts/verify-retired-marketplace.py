#!/usr/bin/env python3
"""Check that legacy packages stay test-only and no public catalog is shipped."""
import hashlib
import json
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit

root = Path(__file__).resolve().parent.parent
website = root / "Website"
legacy = root / "Host/fixtures/legacy-skin-packages"
manifest = json.loads((legacy / "manifest.json").read_text())
assert len(manifest["files"]) == 4
for name, expected in manifest["files"].items():
    assert Path(name).name == name
    data = (legacy / name).read_bytes()
    assert len(data) == expected["byteCount"], name
    assert hashlib.sha256(data).hexdigest() == expected["sha256"], name

assert not (website / "skins").exists(), "Public catalog assets must not be deployed"
assert not list(website.rglob("*.pocketpad")), "Legacy packages belong only in test fixtures"
for path in ["Website/skins.js", "scripts/build-skin-directory.sh", "scripts/verify-skin-directory.py"]:
    assert not (root / path).exists(), f"Retired distribution entry point: {path}"


class Links(HTMLParser):
    def handle_starttag(self, tag, attrs):
        fields = dict(attrs)
        for key in ["href", "src"]:
            value = fields.get(key) or ""
            target = urlsplit(value)
            if target.scheme or target.netloc:
                continue
            assert not target.path.startswith("/skins/"), f"Public package/catalog link: {value}"
            assert target.path not in ["/skins.js", "/skins.html"], f"Retired directory entry: {value}"


for page in website.rglob("*.html"):
    Links().feed(page.read_text())
notice = (website / "skins.html").read_text()
assert 'href="/docs.html#keypad-editor"' in notice
assert 'name="robots" content="noindex"' in notice
assert 'id="skin-directory"' not in notice
assert (website / "404.html").is_file()
print("Marketplace retired; four exact legacy packages remain outside the public website")
