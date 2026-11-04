"""OpenHands as a builder: the `openhands` CLI in headless mode.

Facts this relies on (OpenHands-CLI 1.16 / agent SDK 1.59 source, checked
2026-11-01; the old `python -m openhands.core.main` is gone):
- `openhands --headless --json --override-with-envs -f task.md` runs one task
  and auto-approves. The model comes only from LLM_MODEL / LLM_API_KEY /
  LLM_BASE_URL, and only with `--override-with-envs`. Models are LiteLLM
  names: `anthropic/<m>` for the Messages API, `openai/<m>` for
  OpenAI-compatible endpoints.
- Each JSON line is an event, discriminated by `kind` (ActionEvent,
  ObservationEvent, MessageEvent, ...). The run prints
  `Conversation ID: <hex>` at the end; `--resume <id>` continues it (the CLI
  passes both; not yet checked at run time, so `resume` is off by default).
- Per-call usage is not in the stream; it is in the conversation state
  (`base_state.json`: stats.usage_to_metrics.*.token_usages[]) under
  OPENHANDS_CONVERSATIONS_DIR. The proxy's count is the measure either way.
- Skills are read from `.agents/skills`; user dirs use `~`, so HOME is the
  build's own home.

Options: bin, resume (default false), extra_args.
"""

import json;
import re;
import from pathlib { Path }
import from agent_bench.common { Json }
import from agent_bench.trace { Event, text_of, tool_kind }
import from agent_bench.usage { Usage }
import from agent_bench.agents.base { Agent, Parsed, TurnRequest, copy_skills, jsonl }

glob CONV_ID: re.Pattern = re.compile(r"Conversation ID:\s*([0-9a-fA-F-]{8,})");

def oh_kind(name: str, act: Json) -> str {
    n = name.lower();
    if any([s in n for s in ("terminal", "bash", "cmd", "execute")]) {
        return "bash";
    }
    if any([s in n for s in ("file_editor", "fileeditor", "str_replace", "edit")]) {
        return tool_kind("str_replace_editor", act);
    }
    if "task" in n or "think" in n {
        return "plan";
    }
    if "browser" in n or "fetch" in n {
        return "web";
    }
    return tool_kind(name, act);
}

obj OpenHands(Agent) {
    static has name: str = "openhands";

    def can_resume -> bool {
        return bool(self.spec.options.get("resume", False));
    }

    def binary -> str {
        return str(self.spec.options.get("bin", "openhands"));
    }

    def install(ws: Path, home: Path, skills: list[Path], notes: str) -> tuple[dict[str, str], str] {
        self.home = home;
        (home / ".openhands" / "conversations").mkdir(parents=True, exist_ok=True);
        if not skills {
            return ({}, "");
        }
        names = copy_skills(skills, ws / ".agents" / "skills");
        self.skills_delivered = [f".agents/skills/{n}" for n in names];
        return ({}, f"<!-- skills installed natively in .agents/skills: {', '.join(names)} -->");
    }

    def litellm_model -> str {
        m = self.spec.model;
        head = m.split("/", 1)[0] if "/" in m else "";
        if head in ("anthropic", "openai", "openrouter", "ollama") {
            return m;
        }
        prefix = "anthropic" if self.endpoint is not None and self.endpoint.api == "anthropic" else "openai";
        return f"{prefix}/{m}";
    }

    def env(base: dict[str, str]) -> dict[str, str] {
        env = dict(base);
        if self.home is not None {
            env["HOME"] = str(self.home);
            env["OPENHANDS_PERSISTENCE_DIR"] = str(self.home / ".openhands");
            env["OPENHANDS_CONVERSATIONS_DIR"] = str(self.home / ".openhands" / "conversations");
        }
        env["LLM_MODEL"] = self.litellm_model();
        if self.endpoint is not None {
            env["LLM_API_KEY"] = self.endpoint.key;
            # LiteLLM appends /v1/messages for Anthropic; OpenAI-compatible bases include /v1.
            env["LLM_BASE_URL"] = self.endpoint.base_url + ("" if self.endpoint.api == "anthropic" else "/v1");
        }
        return env;
    }

    def command(req: TurnRequest) -> tuple[list[str], str | None] {
        task = req.bdir / "transcripts" / f"{req.seq:02d}-{req.role}.task.md";
        task.write_text(req.message);
        cmd: list[str] = [self.binary(), "--headless", "--json", "--override-with-envs"];
        if req.resume and req.session {
            cmd += ["--resume", req.session];
        }
        cmd += ["-f", str(task)];
        cmd += [str(a) for a in self.spec.options.get("extra_args", [])];
        return (cmd, None);
    }

    def state_usage(conv: str) -> Usage | None {
        if self.home is None or not conv {
            return None;
        }
        for state in (self.home / ".openhands" / "conversations").glob(f"{conv}*/base_state.json") {
            try {
                d = json.loads(state.read_text());
            } except ValueError {
                continue;
            }
            u = Usage();
            stats: Json = (d as Json).get("stats") or {};
            metrics: Json = stats.get("usage_to_metrics") or {};
            for m in metrics.values() {
                for t in (m as Json).get("token_usages") or [] {
                    tu = t as Json;
                    read = int(tu.get("cache_read_tokens") or 0);
                    write = int(tu.get("cache_write_tokens") or 0);
                    u = u + Usage(
                        input=max(int(tu.get("prompt_tokens") or 0) - read - write, 0), cache_read=read,
                        cache_write=write, output=int(tu.get("completion_tokens") or 0),
                        reasoning=int(tu.get("reasoning_tokens") or 0), calls=1
                    );
                }
            }
            return u;
        }
        return None;
    }

    def parse(transcript: Path, stderr: str) -> Parsed {
        raw = transcript.read_text(errors="replace") if transcript.exists() else "";
        found = CONV_ID.findall(raw + "\n" + stderr);
        conv = str(found[-1]) if found else "";
        text = "";
        finished = False;
        errors: list[Json] = [];
        for ev in jsonl(transcript) {
            k = str(ev.get("kind", ""));
            act: Json = ev.get("action") or {};
            if k == "ActionEvent" and "Finish" in str(act.get("kind", "")) {
                text = str(act.get("message", "") or text);
                finished = True;
            } elif k == "MessageEvent" and ev.get("source") == "agent" {
                lm: Json = ev.get("llm_message") or {};
                text = text_of(lm.get("content")) or text;
            } elif "Error" in k {
                errors.append(ev);
            }
        }
        detail: Json = {"finished": finished};
        if errors {
            detail["errors"] = errors[-3:];
        }
        return Parsed(
            text=text or stderr[-2000:], session=conv, usage=self.state_usage(conv),
            is_error=not (finished or text) or (bool(errors) and not finished), detail=detail
        );
    }

    def events(transcript: Path, role: str, seq: int) -> Iterator[Event] {
        text = "";
        for ev in jsonl(transcript) {
            k = str(ev.get("kind", ""));
            if k == "ActionEvent" {
                act: Json = ev.get("action") or {};
                name = str(ev.get("tool_name") or act.get("kind", ""));
                if "Finish" in str(act.get("kind", "")) {
                    text = str(act.get("message", "") or text);
                    continue;
                }
                inp: Json = {k2: v for (k2, v) in act.items() if k2 != "kind"};
                yield Event(`type="tool_call", role=role, seq=seq, tool=name, kind=oh_kind(name, act),
                            call_id=str(ev.get("tool_call_id") or ev.get("id", "")), input=inp);
            } elif k == "ObservationEvent" {
                obs: Json = ev.get("observation") or {};
                yield Event(`type="tool_result", role=role, seq=seq,
                            call_id=str(ev.get("tool_call_id") or ev.get("action_id", "")),
                            output=text_of(obs.get("content", obs.get("output", ""))),
                            is_error=bool(obs.get("is_error") or obs.get("error")));
            } elif k == "MessageEvent" and ev.get("source") == "agent" {
                lm: Json = ev.get("llm_message") or {};
                t = text_of(lm.get("content"));
                if t {
                    text = t;
                    yield Event(`type="message", role=role, seq=seq, text=t);
                }
            }
        }
        yield Event(`type="final", role=role, seq=seq, text=text);
    }
}
