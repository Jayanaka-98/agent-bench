"""A scripted builder for tests: makes model calls through the proxy, then
writes a broken solution first and the right one on a follow-up."""
import json
import shutil
import sys
import urllib.request
from pathlib import Path

msg_file, ws, base = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
msg = msg_file.read_text()
for stream in (False, True):
    req = urllib.request.Request(f"{base}/v1/messages", data=json.dumps(
        {"model": "fake", "max_tokens": 5, "stream": stream}).encode(), headers={"Content-Type": "application/json"})
    urllib.request.urlopen(req).read()
target = ws / "wordfreq" / "wordfreq.py"
target.parent.mkdir(exist_ok=True)
if "## Follow-up" in msg or "--solve" in sys.argv:
    shutil.copy(Path(__file__).with_name("wordfreq_solution.py"), target)
    print("Built wordfreq; all checks pass.")
else:
    target.write_text("def top_words(text, n, stopwords=None):\n    return []\n")
    print("Built a first draft.")
