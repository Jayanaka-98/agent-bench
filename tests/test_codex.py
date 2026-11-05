"""The Codex adapter's command and install, without running Codex: the API-key
provider, and the ChatGPT-login provider that meters a subscription build."""

import json
from pathlib import Path

import pytest

from agent_bench.agents.base import BuilderSpec, Endpoint, TurnRequest
from agent_bench.agents.codex import Codex

PROXY = "http://127.0.0.1:9000/chatgpt/b~1.builder"


def _agent(tmp_path, auth=None, auth_file=None):
    opts = {}
    if auth:
        opts["auth"] = auth
    if auth_file:
        opts["auth_file"] = str(auth_file)
    spec = BuilderSpec(name="cx", agent="codex", model="gpt-x", endpoint="chatgpt", options=opts)
    return Codex(spec=spec, endpoint=Endpoint(upstream="chatgpt", api="openai", base_url=PROXY))


def _cmd(agent, tmp_path):
    req = TurnRequest(role="builder", seq=0, ws=tmp_path, bdir=tmp_path, env={}, message="hi")
    cmd, stdin = agent.command(req)
    assert stdin == "hi"
    return cmd


def test_api_key_provider(tmp_path):
    a = _agent(tmp_path)
    a.install(tmp_path, tmp_path / "home", [], "")
    cmd = _cmd(a, tmp_path)
    provider = cmd[cmd.index("model_provider=metered") + 2]
    assert f'base_url="{PROXY}/v1"' in provider
    assert 'env_key="AGENT_BENCH_KEY"' in provider
    assert "supports_websockets=false" in provider
    assert a.env({})["AGENT_BENCH_KEY"] == "metered"


def test_chatgpt_provider_copies_login(tmp_path):
    login = tmp_path / "auth.json"
    login.write_text(json.dumps({"auth_mode": "chatgpt", "tokens": {"access_token": "t"}}))
    a = _agent(tmp_path, auth="chatgpt", auth_file=login)
    a.install(tmp_path, tmp_path / "home", [], "")
    copied = tmp_path / "home" / "codex" / "auth.json"
    assert copied.read_text() == login.read_text()
    assert oct(copied.stat().st_mode & 0o777) == "0o600"
    cmd = _cmd(a, tmp_path)
    provider = cmd[cmd.index("model_provider=metered") + 2]
    assert f'base_url="{PROXY}"' in provider
    assert "requires_openai_auth=true" in provider
    assert "env_key" not in provider
    env = a.env({})
    assert env["CODEX_HOME"] == str(tmp_path / "home" / "codex")
    assert "AGENT_BENCH_KEY" not in env


def test_chatgpt_without_login_fails_early(tmp_path):
    a = _agent(tmp_path, auth="chatgpt", auth_file=tmp_path / "missing.json")
    with pytest.raises(FileNotFoundError):
        a.install(tmp_path, tmp_path / "home", [], "")


def test_no_skills_comment(tmp_path):
    skill = tmp_path / "skills" / "s1"
    skill.mkdir(parents=True)
    (skill / "SKILL.md").write_text("---\nname: s1\n---\n")
    a = _agent(tmp_path)
    _, note = a.install(tmp_path / "ws", tmp_path / "home", [skill], "")
    assert note == ""
    assert (tmp_path / "ws" / ".agents" / "skills" / "s1" / "SKILL.md").exists()


def test_skill_set_keeps_top_level_files(tmp_path):
    src = tmp_path / "set"
    (src / "a").mkdir(parents=True)
    (src / "a" / "SKILL.md").write_text("---\nname: a\n---\n")
    (src / "README.md").write_text("index")
    a = _agent(tmp_path)
    a.install(tmp_path / "ws", tmp_path / "home", [src], "")
    got = tmp_path / "ws" / ".agents" / "skills"
    assert (got / "README.md").read_text() == "index"
    assert (got / "a" / "SKILL.md").exists()
    assert a.skills_delivered == [".agents/skills/a"]
