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

import from agent_bench.common { Json }

obj Usage {
    has input: int = 0,
        cache_read: int = 0,
        cache_write: int = 0,
        output: int = 0,
        reasoning: int = 0,   # part of output; not added to total
        calls: int = 0,
        total: int {
            getter -> int {
                return self.input + self.cache_read + self.cache_write + self.output;
            }
        };

    def __add__(other: Usage) -> Usage {
        return Usage(
            input=self.input + other.input,
            cache_read=self.cache_read + other.cache_read,
            cache_write=self.cache_write + other.cache_write,
            output=self.output + other.output,
            reasoning=self.reasoning + other.reasoning,
            calls=self.calls + other.calls
        );
    }

    def to_dict -> dict[str, int] {
        return {
            "input": self.input, "cache_read": self.cache_read, "cache_write": self.cache_write,
            "output": self.output, "reasoning": self.reasoning, "calls": self.calls,
            "total": self.total
        };
    }

    static def from_dict(d: Json | None) -> Usage {
        src: Json = d or {};
        return Usage(
            input=_i(src.get("input")), cache_read=_i(src.get("cache_read")),
            cache_write=_i(src.get("cache_write")), output=_i(src.get("output")),
            reasoning=_i(src.get("reasoning")), calls=_i(src.get("calls"))
        );
    }
}

def _i(v: any) -> int {
    try {
        return int(v or 0);
    } except (TypeError, ValueError) {
        return 0;
    }
}

def from_anthropic(u: Json) -> Usage {
    return Usage(
        input=_i(u.get("input_tokens")),
        cache_read=_i(u.get("cache_read_input_tokens")),
        cache_write=_i(u.get("cache_creation_input_tokens")),
        output=_i(u.get("output_tokens")),
        calls=1
    );
}

"""Chat Completions or Responses usage."""
def from_openai(u: Json) -> Usage {
    prompt = _i(u.get("prompt_tokens", u.get("input_tokens")));
    out = _i(u.get("completion_tokens", u.get("output_tokens")));
    pd: Json = u.get("prompt_tokens_details") or u.get("input_tokens_details") or {};
    od: Json = u.get("completion_tokens_details") or u.get("output_tokens_details") or {};
    read = _i(pd.get("cached_tokens"));
    write = _i(pd.get("cache_write_tokens"));
    return Usage(
        input=max(prompt - read - write, 0), cache_read=read, cache_write=write,
        output=out, reasoning=_i(od.get("reasoning_tokens")), calls=1
    );
}

"""Normalize a usage object of either family; None if it is not one."""
def detect(u: any) -> Usage | None {
    if not isinstance(u, dict) {
        return None;
    }
    d = u as Json;
    if "cache_read_input_tokens" in d or "cache_creation_input_tokens" in d {
        return from_anthropic(d);
    }
    if "prompt_tokens" in d or "completion_tokens" in d {
        return from_openai(d);
    }
    if "input_tokens" in d or "output_tokens" in d {
        # Anthropic and Responses share these names; Responses nests its cache
        # count under input_tokens_details.
        if "input_tokens_details" in d or "output_tokens_details" in d {
            return from_openai(d);
        }
        return from_anthropic(d);
    }
    return None;
}

"""A streamed Messages call reports input and cache counts in `message_start`
and the final output count (cumulative) in the last `message_delta`; newer API
versions repeat input counts there too."""
def merge_anthropic_stream(start: Json, delta: Json) -> Usage {
    merged: Json = dict(start);
    for (k, v) in delta.items() {
        if v is None {
            continue;
        }
        if isinstance(v, (int, float)) {
            merged[k] = max(_i(merged.get(k)), _i(v));
        } else {
            merged[k] = v;
        }
    }
    return from_anthropic(merged);
}
