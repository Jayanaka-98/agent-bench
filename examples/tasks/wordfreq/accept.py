"""Hidden checks for the wordfreq task. Prints (and with --out writes) a verdict:
{"passed": bool, "metrics": {"cases": n, "passed_cases": k}, "reasons": [...]}"""

import argparse
import importlib.util
import json
import subprocess
import sys
import tempfile
from pathlib import Path

CASES = [
    ("The cat and the hat. The CAT!", 2, None, [("cat", 2), ("hat", 1)]),
    ("b a c b a b", 5, set(), [("b", 3), ("a", 2), ("c", 1)]),
    ("Don't stop; don't 'tis' it", 3, set(), [("don't", 2), ("it", 1), ("stop", 1)]),
    ("x y", 0, set(), []),
    ("'' ' a'", 5, set(), [("a", 1)]),
    ("zeta alpha zeta alpha beta", 2, {"beta"}, [("alpha", 2), ("zeta", 2)]),
    ("one-two three_four 5five", 10, set(), [("five", 1), ("four", 1), ("one", 1), ("three", 1), ("two", 1)]),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("ws")
    ap.add_argument("--out")
    a = ap.parse_args()
    ws = Path(a.ws)
    mod_path = ws / "wordfreq" / "wordfreq.py"
    reasons, ok = [], 0
    total = len(CASES) + 3
    if not mod_path.exists():
        reasons.append("wordfreq/wordfreq.py does not exist")
    else:
        try:
            spec = importlib.util.spec_from_file_location("wordfreq_under_test", mod_path)
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            for text, n, stop, want in CASES:
                got = [tuple(x) for x in mod.top_words(text, n, stop)]
                if got == want:
                    ok += 1
                else:
                    reasons.append(f"top_words({text!r}, {n}, {stop!r}) = {got!r}, expected {want!r}")
        except Exception as e:  # noqa: BLE001
            reasons.append(f"importing or calling top_words failed: {type(e).__name__}: {e}")
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "t.txt"
            f.write_text("It is the end of the end, and the END is near")
            p = subprocess.run([sys.executable, str(mod_path), str(f), "-n", "2"], capture_output=True, text=True)
            if p.returncode == 0 and p.stdout.strip().splitlines() == ["end\t3", "near\t1"]:
                ok += 1
            else:
                reasons.append(f"CLI with default stopwords printed {p.stdout!r} (exit {p.returncode})")
            p = subprocess.run([sys.executable, str(mod_path), str(f)], capture_output=True, text=True)
            if p.returncode == 0 and len(p.stdout.strip().splitlines()) == 2:
                ok += 1
            else:
                reasons.append(f"CLI default -n printed {p.stdout!r}")
            p = subprocess.run([sys.executable, str(mod_path), str(Path(d) / "missing.txt")],
                               capture_output=True, text=True)
            if p.returncode == 2 and p.stderr.strip():
                ok += 1
            else:
                reasons.append(f"missing file: exit {p.returncode}, stderr {p.stderr!r}")
    v = {"passed": ok == total, "metrics": {"cases": total, "passed_cases": ok}, "reasons": reasons}
    if a.out:
        Path(a.out).write_text(json.dumps(v))
    print(json.dumps(v))
    return 0 if v["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
