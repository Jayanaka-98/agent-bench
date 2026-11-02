from agent_bench.build import role_tokens
from agent_bench.usage import Usage, detect, from_anthropic, from_openai, merge_anthropic_stream


def test_anthropic_input_is_uncached():
    u = from_anthropic({"input_tokens": 10, "cache_read_input_tokens": 1000,
                        "cache_creation_input_tokens": 50, "output_tokens": 7})
    assert (u.input, u.cache_read, u.cache_write, u.output, u.total) == (10, 1000, 50, 7, 1067)


def test_openai_chat_prompt_includes_cache():
    u = from_openai({"prompt_tokens": 1200, "completion_tokens": 30,
                     "prompt_tokens_details": {"cached_tokens": 1000},
                     "completion_tokens_details": {"reasoning_tokens": 12}})
    assert (u.input, u.cache_read, u.output, u.reasoning, u.total) == (200, 1000, 30, 12, 1230)


def test_responses_usage():
    u = detect({"input_tokens": 500, "input_tokens_details": {"cached_tokens": 400}, "output_tokens": 9,
                "output_tokens_details": {"reasoning_tokens": 3}})
    assert (u.input, u.cache_read, u.output, u.total) == (100, 400, 9, 509)


def test_detect_anthropic_without_cache_fields():
    assert detect({"input_tokens": 5, "output_tokens": 6}).total == 11


def test_stream_merge_takes_final_output():
    u = merge_anthropic_stream({"input_tokens": 3, "cache_read_input_tokens": 100, "output_tokens": 1},
                               {"output_tokens": 42})
    assert (u.input, u.cache_read, u.output) == (3, 100, 42)


def _row(session, total_in, cost):
    return {"role": "builder", "session": session, "self_usage": Usage(input=total_in).to_dict(), "cost_usd": cost}


def test_cumulative_session_counts_last_row_even_with_equal_attempts():
    """Rows written after a limit wait all carry attempt 1. The session's last
    row is the total; the first row (before the wait) is not."""
    rows = [_row("s1", 100, 0.1), _row("s1", 100, 0.1), _row("s1", 160, 0.2)]
    t = role_tokens(rows, "builder", None, cumulative=True)
    assert t["total"] == 160 and t["self_cost_usd"] == 0.2


def test_non_cumulative_sums_turns_and_metered_wins():
    rows = [_row("a", 100, 0.1), _row("a", 50, 0.1)]
    assert role_tokens(rows, "builder", None, cumulative=False)["total"] == 150
    t = role_tokens(rows, "builder", Usage(input=7, calls=1), cumulative=False)
    assert t["source"] == "metered" and t["total"] == 7 and t["self_reported"]["total"] == 150
