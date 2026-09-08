"""Verify only runtime evidence from the published stack, never fixture rows."""
import json
from pathlib import Path
import re
import sys
from html.parser import HTMLParser

root = Path(sys.argv[1])
session_id = sys.argv[2]


def imported(name):
    text = (root / name).read_text()
    loaded = re.findall(r"^loaded (\d+) interaction", text, re.M)
    skipped = re.findall(r"^\s*(\d+) already present", text, re.M)
    assert len(loaded) == 1, f"{name}: expected exactly one successful import"
    return int(loaded[0]), int(skipped[0]) if skipped else 0


capture = [json.loads(line) for line in (root / "capture.jsonl").read_text().splitlines() if line.strip()]
assert capture, "RailMon capture is empty"
inserted, duplicates = imported("install.log")
assert inserted == 0 and duplicates > 0, "first stack import must prove prior webhook delivery"
file_inserted, file_duplicates = imported("first-file-import.log")
assert file_inserted == duplicates and file_duplicates == 0, "fresh database must import all captured interactions"
overview = json.loads((root / "overview.json").read_text())
assert overview["totals"]["interactions"] == duplicates, "stored count must equal parsed capture count"
rows = json.loads((root / "interactions.json").read_text())["items"]
assert len(rows) == duplicates, "API must return the captured interactions"
assert all(row["session_id"] == session_id for row in rows), "unexpected session rows"
assert {row["method"] for row in rows} == {"POST"}, "unexpected demo methods"
assert {row["status_code"] for row in rows} == {200}, "demo request failed"
assert {row["path"] for row in rows} == {"/v1/demo", "/v1/demo/other"}, "demo routes missing"
assert any(s["session_id"] == session_id for s in json.loads((root / "sessions.json").read_text()))


class Stat(HTMLParser):
    collecting = False
    value = ""

    def handle_starttag(self, tag, attrs):
        if dict(attrs).get("id") == "stat-interactions":
            self.collecting = True

    def handle_endtag(self, tag):
        self.collecting = False

    def handle_data(self, data):
        if self.collecting:
            self.value += data


stat = Stat()
stat.feed((root / "dashboard.html").read_text())
assert int(stat.value.replace(",", "").strip()) == duplicates, "rendered dashboard count does not match API"
assert (root / "dashboard.png").stat().st_size > 0, "missing rendered dashboard screenshot"
print(f"PASS: {len(capture)} capture records; {duplicates} webhook interactions; "
      f"{file_inserted} first-file-import inserts; rendered dashboard shows {duplicates}.")
