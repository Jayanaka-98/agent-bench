"""One token record for every API and agent.

The effort measure is the tokens a builder processes: uncached input, cache
reads, cache writes and output. That is the jac-paper harness's
`total_tokens` (input + output + cache read + cache creation). Providers split
the same quantities differently, so everything is normalized here:

- **Anthropic Messages**: `input_tokens` is *uncached* input; cache reads and
  writes are separate fields.
- **OpenAI Chat Completions**: `prompt_tokens` *includes* cached tokens
  (`prompt_tokens_details.cached_tokens`); OpenRouter may also report
  `cache_write_tokens` there, which is likewise inside `prompt_tokens`.
- **OpenAI Responses**: `input_tokens` includes `input_tokens_details.cached_tokens`.

Reasoning tokens are a part of output, kept separately for information only.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, fields


@dataclass
class Usage:
    input: int = 0          # uncached input
    cache_read: int = 0
    cache_write: int = 0
    output: int = 0
    reasoning: int = 0      # part of output; not added to total
    calls: int = 0

    @property
    def total(self) -> int:
        return self.input + self.cache_read + self.cache_write + self.output

    def __add__(self, other: "Usage") -> "Usage":
        return Usage(**{f.name: getattr(self, f.name) + getattr(other, f.name) for f in fields(self)})

    def to_dict(self) -> dict:
        return {**asdict(self), "total": self.total}

    @classmethod
    def from_dict(cls, d: dict | None) -> "Usage":
        d = d or {}
        return cls(**{f.name: int(d.get(f.name) or 0) for f in fields(cls)})


def _i(v) -> int:
    try:
        return int(v or 0)
    except (TypeError, ValueError):
        return 0


def from_anthropic(u: dict) -> Usage:
    return Usage(input=_i(u.get("input_tokens")),
                 cache_read=_i(u.get("cache_read_input_tokens")),
                 cache_write=_i(u.get("cache_creation_input_tokens")),
                 output=_i(u.get("output_tokens")), calls=1)


def from_openai(u: dict) -> Usage:
    """Chat Completions or Responses usage."""
    prompt = _i(u.get("prompt_tokens", u.get("input_tokens")))
    out = _i(u.get("completion_tokens", u.get("output_tokens")))
    pd = u.get("prompt_tokens_details") or u.get("input_tokens_details") or {}
    od = u.get("completion_tokens_details") or u.get("output_tokens_details") or {}
    read = _i(pd.get("cached_tokens"))
    write = _i(pd.get("cache_write_tokens"))
    return Usage(input=max(prompt - read - write, 0), cache_read=read, cache_write=write,
                 output=out, reasoning=_i(od.get("reasoning_tokens")), calls=1)


def detect(u: dict) -> Usage | None:
    """Normalize a usage object of either family; None if it is not one."""
    if not isinstance(u, dict):
        return None
    if "cache_read_input_tokens" in u or "cache_creation_input_tokens" in u:
        return from_anthropic(u)
    if "prompt_tokens" in u or "completion_tokens" in u:
        return from_openai(u)
    if "input_tokens" in u or "output_tokens" in u:
        # Anthropic and Responses share these names; Responses nests its cache
        # count under input_tokens_details.
        return from_openai(u) if "input_tokens_details" in u or "output_tokens_details" in u \
            else from_anthropic(u)
    return None


def merge_anthropic_stream(start: dict, delta: dict) -> Usage:
    """A streamed Messages call reports input and cache counts in
    `message_start` and the final output count (cumulative) in the last
    `message_delta`; newer API versions repeat input counts there too."""
    merged = dict(start)
    for k, v in delta.items():
        if v is not None:
            merged[k] = max(_i(merged.get(k)), _i(v)) if isinstance(v, (int, float)) else v
    return from_anthropic(merged)
