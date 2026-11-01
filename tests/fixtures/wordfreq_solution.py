import argparse
import re
import sys
from collections import Counter
from pathlib import Path

WORD = re.compile(r"[A-Za-z']+")
STOPWORDS = Path(__file__).resolve().parent.parent / "data" / "stopwords.txt"


def top_words(text, n, stopwords=None):
    if stopwords is None:
        stopwords = set(STOPWORDS.read_text().split())
    words = (w.lower().strip("'") for w in WORD.findall(text))
    c = Counter(w for w in words if w and w not in stopwords)
    return sorted(c.items(), key=lambda kv: (-kv[1], kv[0]))[:max(n, 0)]


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("file")
    ap.add_argument("-n", type=int, default=10)
    a = ap.parse_args()
    try:
        text = Path(a.file).read_text()
    except OSError as e:
        print(f"error: {e}", file=sys.stderr)
        sys.exit(2)
    for w, k in top_words(text, a.n):
        print(f"{w}\t{k}")
