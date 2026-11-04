"""Claude Code as a builder (and as the driver): `claude -p --output-format stream-json`.

This is the jac-paper harness's `run_claude`, behind the adapter interface:
the same flags, sessions and limit handling.

Options (builder `options` in the experiment):
  bin          the CLI (default `claude`)
  safe_mode    pass --safe-mode (default: on unless skills are installed, which it hides)
  auth         "inherit" (default), "subscription" (drop ANTHROPIC_API_KEY so the
               login pays; through the proxy, its auth passes through) or "api-key"
  extra_args   more CLI arguments
"""

import os;
import re;
import uuid;
import from pathlib { Path }
import from agent_bench.common { Json }
import from agent_bench.trace { Event, text_of, tool_kind }
import from agent_bench.usage { Usage }
import from agent_bench.agents.base { Agent, Parsed, TurnRequest, copy_skills, jsonl }

obj ClaudeCode(Agent) {
    static has name: str = "claude-code",
        # `result.modelUsage` and `total_cost_usd` cover the whole session so
        # far, so a resumed session counts once, at its last turn.
        self_usage_cumulative: bool = True;

    def binary -> str {
        return str(self.spec.options.get("bin", "claude"));
    }

    def install(ws: Path, home: Path, skills: list[Path], notes: str) -> tuple[dict[str, str], str] {
        self.home = home;
        self.has_skills = bool(skills);
        if not skills {
            return ({}, "");
        }
        names = copy_skills(skills, ws / ".claude" / "skills");
        self.skills_delivered = [f".claude/skills/{n}" for n in names];
        # Claude Code lists them itself; the prompt says nothing (as in run_builds.py).
        return ({}, "");
    }

    def env(base: dict[str, str]) -> dict[str, str] {
        env = dict(base);
        for k in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT") {
            env.pop(k, None);
        }
        auth = str(self.spec.options.get("auth", "inherit"));
        if auth == "subscription" {
            env.pop("ANTHROPIC_API_KEY", None);
        }
        if self.endpoint is not None {
            env["ANTHROPIC_BASE_URL"] = self.endpoint.base_url;
            if auth == "api-key" {
                env["ANTHROPIC_API_KEY"] = self.endpoint.key;
            }
        }
        return env;
    }

    def command(req: TurnRequest) -> tuple[list[str], str | None] {
        o = self.spec.options;
        safe = bool(o.get("safe_mode", not self.has_skills));
        cmd: list[str] = [self.binary(), "-p", "--output-format", "stream-json", "--verbose"];
        if self.spec.model {
            cmd += ["--model", self.spec.model];
        }
        if safe {
            cmd.append("--safe-mode");
        }
        cmd += ["--setting-sources", str(o.get("setting_sources", "project")), "--strict-mcp-config",
                "--dangerously-skip-permissions"];
        if req.resume and req.session {
            cmd += ["--resume", req.session];
        } else {
            req.session = req.session or str(uuid.uuid4());
            cmd += ["--session-id", req.session];
        }
        if req.tools_denied {
            cmd += ["--disallowedTools", *req.tools_denied];
        }
        cmd += [str(a) for a in o.get("extra_args", [])];
        return (cmd, req.message);
    }

    def parse(transcript: Path, stderr: str) -> Parsed {
        res: Json | None = None;
        session = "";
        for ev in jsonl(transcript) {
            session = str(ev.get("session_id") or session);
            if ev.get("type") == "result" {
                res = ev;
            }
        }
        if res is None {
            return Parsed(session=session, text=stderr[-2000:], is_error=True);
        }
        usage: Usage | None = None;
        model_usage: Json = res.get("modelUsage") or {};
        if model_usage {
            usage = Usage();
            for mu in model_usage.values() {
                m = mu as Json;
                usage = usage + Usage(
                    input=int(m.get("inputTokens", 0)), output=int(m.get("outputTokens", 0)),
                    cache_read=int(m.get("cacheReadInputTokens", 0)),
                    cache_write=int(m.get("cacheCreationInputTokens", 0)),
                    reasoning=int(m.get("thinkingTokens", 0))
                );
            }
        }
        return Parsed(
            text=str(res.get("result", "") or ""), session=str(res.get("session_id", session)),
            usage=usage, cost_usd=res.get("total_cost_usd"), num_turns=res.get("num_turns"),
            is_error=bool(res.get("is_error", True)), limited=res.get("api_error_status") == 429,
            detail={"subtype": res.get("subtype"), "duration_api_ms": res.get("duration_api_ms"),
                    "modelUsage": res.get("modelUsage"), "usage": res.get("usage"),
                    "self_usage_cumulative": True}
        );
    }

    def events(transcript: Path, role: str, seq: int) -> Iterator[Event] {
        # stream-json repeats an assistant message once per content block, each
        # with the message's usage so far: keep the last usage per message id.
        usage_by_msg: dict[str, tuple[Json, str]] = {};
        order: list[str] = [];
        for ev in jsonl(transcript) {
            t = ev.get("type");
            msg: Json = ev.get("message") or {};
            if t == "assistant" {
                mid = str(msg.get("id", ""));
                if msg.get("usage") {
                    if mid not in usage_by_msg {
                        order.append(mid);
                    }
                    usage_by_msg[mid] = (msg["usage"], str(msg.get("model", "")));
                }
                for b in msg.get("content") or [] {
                    blk = b as Json;
                    if blk.get("type") == "text" and blk.get("text") {
                        yield Event(`type="message", role=role, seq=seq, text=str(blk["text"]),
                                    model=str(msg.get("model", "")));
                    } elif blk.get("type") == "tool_use" {
                        inp: Json = blk.get("input") or {};
                        name = str(blk.get("name", ""));
                        yield Event(`type="tool_call", role=role, seq=seq, tool=name, kind=tool_kind(name, inp),
                                    call_id=str(blk.get("id", "")), input=inp);
                    }
                }
            } elif t == "user" {
                content = msg.get("content");
                if isinstance(content, list) {
                    for b in content {
                        blk = b as Json;
                        if blk.get("type") == "tool_result" {
                            yield Event(`type="tool_result", role=role, seq=seq,
                                        call_id=str(blk.get("tool_use_id", "")),
                                        output=text_of(blk.get("content")), is_error=bool(blk.get("is_error")));
                        }
                    }
                }
            } elif t == "result" {
                for mid in order {
                    (u, model) = usage_by_msg[mid];
                    yield Event(`type="usage", role=role, seq=seq, model=model, usage=u);
                }
                order = [];
                yield Event(`type="final", role=role, seq=seq, text=str(ev.get("result", "") or ""),
                            session=str(ev.get("session_id", "")), is_error=bool(ev.get("is_error")));
            }
        }
        for mid in order {  # a turn cut off before its result event
            (u, model) = usage_by_msg[mid];
            yield Event(`type="usage", role=role, seq=seq, model=model, usage=u);
        }
    }

    def native_logs(ws: Path) -> list[Path] {
        d = Path(os.path.expanduser("~/.claude/projects")) / re.sub(r"[^A-Za-z0-9]", "-", str(ws));
        return [d] if d.exists() else [];
    }
}
