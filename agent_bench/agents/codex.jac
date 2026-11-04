"""OpenAI Codex CLI as a builder: `codex exec --json`.

Facts this relies on (Codex 0.166 source, checked 2026-11-01):
- `codex exec ... -` reads the prompt from stdin; exec never asks for
  approval, and `--dangerously-bypass-approvals-and-sandbox` lifts the sandbox.
- JSON events: thread.started{thread_id}, turn.completed{usage},
  item.completed{item}, turn.failed, error. Items: agent_message, reasoning,
  command_execution, file_change, mcp_tool_call, web_search, todo_list.
- `turn.completed.usage` is the thread's running total, so a resumed thread
  counts once, at its last turn: {input_tokens (incl. cached),
  cached_input_tokens, cache_write_input_tokens, output_tokens,
  reasoning_output_tokens}.
- `codex exec resume <thread_id>` continues a thread.
- The only wire API is Responses: the endpoint's upstream must serve
  `/v1/responses`. There is no Anthropic Messages support.
- `CODEX_HOME` isolates config, auth and session logs; skills are read from
  `.agents/skills`.
- A ChatGPT login lives in `$CODEX_HOME/auth.json`. A custom provider with
  `requires_openai_auth = true` sends that login's headers, so the proxy can
  meter a subscription build by passing them through to
  `https://chatgpt.com/backend-api/codex` (the provider appends `/responses`).
  `supports_websockets = false` keeps every call on HTTP, where the proxy sees it.

Options (builder `options` in the experiment):
  bin          the CLI (default `codex`)
  auth         "api-key" (default: the endpoint's key, `/v1` Responses) or
               "chatgpt" (copy a ChatGPT login into each build's CODEX_HOME; the
               endpoint's upstream is the ChatGPT Codex backend, and the client's
               auth passes through the proxy, so set no `key_env` on it)
  auth_file    the login to copy (default `~/.codex/auth.json`)
  extra_args   more CLI arguments
"""

import json;
import os;
import shutil;
import from pathlib { Path }
import from agent_bench.common { Json }
import from agent_bench.trace { Event, tool_kind }
import from agent_bench.usage { Usage }
import from agent_bench.agents.base { Agent, Parsed, TurnRequest, copy_skills, jsonl }

obj Codex(Agent) {
    static has name: str = "codex",
        self_usage_cumulative: bool = True;

    def binary -> str {
        return str(self.spec.options.get("bin", "codex"));
    }

    def auth -> str {
        return str(self.spec.options.get("auth", "api-key"));
    }

    def install(ws: Path, home: Path, skills: list[Path], notes: str) -> tuple[dict[str, str], str] {
        self.home = home;
        (home / "codex").mkdir(parents=True, exist_ok=True);
        if self.endpoint is not None and self.endpoint.api == "anthropic" {
            raise ValueError("codex speaks only the Responses API; give it an OpenAI-compatible endpoint");
        }
        if self.auth() == "chatgpt" {
            src = Path(os.path.expanduser(str(self.spec.options.get("auth_file", "~/.codex/auth.json"))));
            if not src.is_file() {
                raise FileNotFoundError(f"codex auth = chatgpt needs a login at {src}: run `codex login --device-auth`");
            }
            dst = home / "codex" / "auth.json";
            shutil.copyfile(src, dst);
            os.chmod(dst, 0o600);
        }
        if not skills {
            return ({}, "");
        }
        names = copy_skills(skills, ws / ".agents" / "skills");
        self.skills_delivered = [f".agents/skills/{n}" for n in names];
        # Codex lists them itself; the prompt says nothing (as for Claude Code).
        return ({}, "");
    }

    def env(base: dict[str, str]) -> dict[str, str] {
        env = dict(base);
        if self.home is not None {
            env["CODEX_HOME"] = str(self.home / "codex");
        }
        if self.endpoint is not None and self.auth() != "chatgpt" {
            env["AGENT_BENCH_KEY"] = self.endpoint.key;
        }
        return env;
    }

    def command(req: TurnRequest) -> tuple[list[str], str | None] {
        cmd: list[str] = [self.binary(), "exec"];
        resumed = req.resume and bool(req.session);
        if resumed {
            cmd += ["resume", req.session];
        }
        cmd += ["--json", "--dangerously-bypass-approvals-and-sandbox", "--skip-git-repo-check"];
        if self.spec.model {
            cmd += ["-m", self.spec.model];
        }
        if not resumed {
            cmd += ["-C", str(req.ws)];
        }
        if self.endpoint is not None {
            if self.auth() == "chatgpt" {
                provider = 'model_providers.metered={name="metered",base_url="' + self.endpoint.base_url
                    + '",wire_api="responses",requires_openai_auth=true,supports_websockets=false}';
            } else {
                provider = 'model_providers.metered={name="metered",base_url="' + self.endpoint.base_url
                    + '/v1",env_key="AGENT_BENCH_KEY",wire_api="responses",supports_websockets=false}';
            }
            cmd += ["-c", "model_provider=metered", "-c", provider];
        }
        cmd += [str(a) for a in self.spec.options.get("extra_args", [])];
        cmd.append("-");
        return (cmd, req.message);
    }

    def parse(transcript: Path, stderr: str) -> Parsed {
        session = "";
        text = "";
        usage: Usage | None = None;
        turns = 0;
        failed: list[Json] = [];
        for ev in jsonl(transcript) {
            t = ev.get("type");
            if t == "thread.started" {
                session = str(ev.get("thread_id", session));
            } elif t == "turn.completed" {
                turns += 1;
                u: Json = ev.get("usage") or {};
                cached = int(u.get("cached_input_tokens") or 0);
                write = int(u.get("cache_write_input_tokens") or 0);
                usage = Usage(
                    input=max(int(u.get("input_tokens") or 0) - cached - write, 0), cache_read=cached,
                    cache_write=write, output=int(u.get("output_tokens") or 0),
                    reasoning=int(u.get("reasoning_output_tokens") or 0)
                );
            } elif t in ("turn.failed", "error") {
                failed.append(ev);
            } elif t == "item.completed" {
                it: Json = ev.get("item") or {};
                if it.get("type") == "agent_message" {
                    text = str(it.get("text", ""));
                }
            }
        }
        detail: Json = {"self_usage_cumulative": True};
        if failed {
            detail["errors"] = failed[-3:];
        }
        return Parsed(
            text=text or (json.dumps(failed[-1]) if failed else stderr[-2000:]), session=session,
            usage=usage, num_turns=turns, is_error=bool(failed) or not turns, detail=detail
        );
    }

    def events(transcript: Path, role: str, seq: int) -> Iterator[Event] {
        text = "";
        session = "";
        for ev in jsonl(transcript) {
            t = ev.get("type");
            if t == "thread.started" {
                session = str(ev.get("thread_id", ""));
            } elif t == "turn.completed" {
                yield Event(`type="usage", role=role, seq=seq, usage=ev.get("usage") or {});
            } elif t == "item.completed" {
                it: Json = ev.get("item") or {};
                kind = str(it.get("type", ""));
                iid = str(it.get("id", ""));
                if kind == "agent_message" {
                    text = str(it.get("text", ""));
                    yield Event(`type="message", role=role, seq=seq, text=text);
                } elif kind == "command_execution" {
                    yield Event(`type="tool_call", role=role, seq=seq, tool="command_execution", kind="bash",
                                call_id=iid, input={"command": it.get("command", "")});
                    yield Event(`type="tool_result", role=role, seq=seq, call_id=iid,
                                output=str(it.get("aggregated_output", "")),
                                is_error=(it.get("exit_code") not in (0, None)) or it.get("status") == "failed");
                } elif kind == "file_change" {
                    for ch in it.get("changes") or [] {
                        c = ch as Json;
                        yield Event(`type="tool_call", role=role, seq=seq, tool="file_change",
                                    kind="write" if c.get("kind") == "add" else "edit", call_id=iid, input=c);
                    }
                } elif kind in ("web_search", "mcp_tool_call", "todo_list") {
                    inp: Json = {k: v for (k, v) in it.items() if k not in ("id", "type")};
                    yield Event(`type="tool_call", role=role, seq=seq, tool=kind, kind=tool_kind(kind),
                                call_id=iid, input=inp);
                }
            }
        }
        yield Event(`type="final", role=role, seq=seq, text=text, session=session);
    }
}
