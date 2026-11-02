---
name: text-processing
description: Tokenizing and counting words in Python with re and collections.Counter. Use when a task counts or ranks words.
---

# Text processing

- Tokenize with one compiled regex, e.g. `re.compile(r"[A-Za-z']+")`, then
  normalize each match (`.lower()`, `.strip("'")`) and drop empty results.
- Count with `collections.Counter`. For "count descending, ties alphabetical",
  sort `counter.items()` by `key=lambda kv: (-kv[1], kv[0])`; `most_common`
  does not break ties alphabetically.
- Resolve data files relative to the module: `Path(__file__).resolve().parent`.
