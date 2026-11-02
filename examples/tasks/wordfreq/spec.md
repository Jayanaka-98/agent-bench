# Build: wordfreq

Write `wordfreq/wordfreq.py`, a module and command-line tool that reports the
most frequent words in a text.

## The function

`top_words(text: str, n: int, stopwords: set[str] | None = None) -> list[tuple[str, int]]`

- A word is a maximal run of ASCII letters and apostrophes, lower-cased.
  Apostrophes at the start or end of a word are stripped; a word that is then
  empty is dropped. `Don't` is `don't`; `'tis'` is `tis`.
- Words in `stopwords` are not counted. With `stopwords=None`, the stopwords
  are read from `data/stopwords.txt` at the repository root (found relative to
  the module file).
- Returns the `n` most frequent words as `(word, count)`, by count descending,
  ties broken alphabetically. Fewer than `n` distinct words returns them all;
  `n <= 0` returns `[]`.

## The command line

`python wordfreq/wordfreq.py FILE [-n N]` (default N = 10) prints one line per
word, `word<TAB>count`, in the order above, and exits 0. A missing file prints
an error to stderr and exits 2.

## Rules

- Python standard library only.
- Do not modify `data/`.
