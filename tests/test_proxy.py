import json
import urllib.request

import pytest

from agent_bench.proxy import ledger_usage, make_app

from fakes import Served, fake_api, free_port


@pytest.fixture()
def setup(tmp_path, monkeypatch):
    monkeypatch.setenv("REAL_KEY", "sk-real")
    s = Served()
    api = fake_api()
    up = s.serve(api, free_port())
    ledger = tmp_path / "ledger.jsonl"
    upstreams = {"anthropic": {"url": up, "api": "anthropic"},
                 "openai": {"url": up, "api": "openai", "key_env": "REAL_KEY"}}
    proxy = s.serve(make_app(upstreams, ledger, ledger.with_suffix(".bodies.jsonl")), free_port())
    yield proxy, api, ledger
    s.close()


def post(url, body, headers=None):
    req = urllib.request.Request(url, data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json", **(headers or {})})
    with urllib.request.urlopen(req, timeout=10) as r:
        return r.read()


def rows(ledger, at_least=1):
    # A streamed call is logged just after the client sees its end.
    import time
    for _ in range(50):
        out = [json.loads(l) for l in ledger.read_text().splitlines()] if ledger.exists() else []
        if len(out) >= at_least:
            return out
        time.sleep(0.05)
    return out


def test_anthropic_plain_and_stream(setup):
    proxy, api, ledger = setup
    post(f"{proxy}/anthropic/b1.builder/v1/messages", {"model": "m", "max_tokens": 5},
         {"x-api-key": "client-key"})
    out = post(f"{proxy}/anthropic/b1.builder/v1/messages", {"model": "m", "stream": True})
    assert b"message_stop" in out  # the stream reaches the client intact
    r = rows(ledger, 2)
    assert [x["usage"]["output"] for x in r] == [5, 25]
    assert r[1]["usage"]["cache_read"] == 900 and r[1]["stream"]
    # no key_env: the client's own auth goes through untouched
    assert api["seen"][0]["headers"]["x-api-key"] == "client-key"
    assert ledger_usage(ledger, "b1.")["b1.builder"].total == (11 + 900 + 40 + 5) + (11 + 900 + 40 + 25)


def test_openai_stream_gets_usage_injected_and_key_replaced(setup):
    proxy, api, ledger = setup
    post(f"{proxy}/openai/b2.builder/v1/chat/completions", {"model": "g", "stream": True},
         {"Authorization": "Bearer dummy"})
    seen = api["seen"][-1]
    assert seen["body"]["stream_options"] == {"include_usage": True}
    assert seen["headers"]["authorization"] == "Bearer sk-real"
    r = rows(ledger)[-1]
    assert r["injected_stream_usage"] and r["usage"]["input"] == 44 and r["usage"]["cache_read"] == 256


def test_responses_stream(setup):
    proxy, _, ledger = setup
    post(f"{proxy}/openai/b3.builder/v1/responses", {"model": "g", "stream": True})
    u = rows(ledger)[-1]["usage"]
    assert (u["input"], u["cache_read"], u["output"]) == (6, 64, 8)


def test_tags_keep_parallel_builds_apart(setup):
    proxy, _, ledger = setup
    post(f"{proxy}/anthropic/x.builder/v1/messages", {"model": "m"})
    post(f"{proxy}/anthropic/y.builder/v1/messages", {"model": "m"})
    post(f"{proxy}/anthropic/x.driver/v1/messages", {"model": "m"})
    live = json.loads(urllib.request.urlopen(f"{proxy}/__usage?prefix=x.").read())
    assert set(live) == {"x.builder", "x.driver"}
    assert set(ledger_usage(ledger, "y.")) == {"y.builder"}


def test_unknown_upstream_is_404(setup):
    proxy, _, _ = setup
    with pytest.raises(urllib.error.HTTPError) as e:
        post(f"{proxy}/nope/t/v1/messages", {"model": "m"})
    assert e.value.code == 404
