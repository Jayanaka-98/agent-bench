"""Episode protocols: how the builder's turns, the driver's reviews and the
acceptance checks are put together into one build.

- **one-shot**: one builder session, then one acceptance check, pass or fail.
  No feedback. The cleanest measure of effort.
- **accept-loop**: builder, then acceptance; on failure the check's reasons
  and log go back to the builder, up to `max_rounds` times. No driver.
- **reviewed**: builder, then a Claude Code driver that reviews the work and
  answers `VERDICT: DONE` or `VERDICT: CONTINUE` with feedback for the
  builder. A DONE is then checked by acceptance, and a failure goes back to
  the builder. This is the jac-paper protocol.

A protocol gets a `Session` (build.jac) and returns an `Outcome`.
"""

import re;
import from agent_bench.common { Json }
import from agent_bench.accept { feedback }

glob VERDICT: re.Pattern = re.compile(r"^\s*\**\s*VERDICT:\s*(DONE|CONTINUE)\b\**", re.M);

obj Outcome {
    has status: str = "incomplete",   # works | done-not-working | done | incomplete | over-budget | error
        verdicts: list[str] = [],
        accepts: list[Json] = [],
        commits: list[str] = [];
}

def _accept(s: any, out: Outcome, label: str) -> bool {
    out.commits.append(str(s.snapshot(f"before acceptance, {label}")));
    s.log(f"acceptance ({label})");
    v = s.accept(len(out.accepts) + 1) as Json;
    out.accepts.append(v);
    s.log(f"acceptance {'PASS' if v['passed'] else 'FAIL'} {v.get('metrics', {})}");
    return bool(v["passed"]);
}

def one_shot(s: any) -> Outcome {
    out = Outcome();
    b = s.builder(s.prompt, first=True);
    out.commits.append(str(s.snapshot("builder round 0")));
    if b.over_budget {
        out.status = "over-budget";
        return out;
    }
    if b.is_error and not b.text {
        out.status = "error";
    }
    if not s.has_accept {
        out.status = "done" if out.status != "error" else "error";
        return out;
    }
    out.status = "works" if _accept(s, out, "one-shot") else "done-not-working";
    return out;
}

def accept_loop(s: any) -> Outcome {
    out = Outcome();
    b = s.builder(s.prompt, first=True);
    out.commits.append(str(s.snapshot("builder round 0")));
    for rnd in range(1, int(s.max_rounds) + 1) {
        if b.over_budget or s.over_budget() {
            out.status = "over-budget";
            return out;
        }
        if _accept(s, out, f"round {rnd}") {
            out.status = "works";
            return out;
        }
        out.status = "done-not-working";
        if rnd == s.max_rounds {
            break;
        }
        b = s.builder(feedback(out.accepts[-1]), first=False);
        out.commits.append(str(s.snapshot(f"builder round {rnd}")));
    }
    return out;
}

def reviewed(s: any) -> Outcome {
    out = Outcome();
    b = s.builder(s.prompt, first=True);
    out.commits.append(str(s.snapshot("builder round 0")));
    max_rounds = int(s.max_rounds);
    for rnd in range(1, max_rounds + 1) {
        if b.over_budget or s.over_budget() {
            out.status = "over-budget";
            return out;
        }
        builder_report = str(b.text or "(the builder produced no final message)");
        msg = (str(s.driver_intro) + "\n\n" if rnd == 1 else "")
            + f"## Review round {rnd} of {max_rounds}\n\nThe builder's report:\n\n{builder_report}";
        d = s.driver(msg, first=rnd == 1);
        if d.over_budget {
            out.status = "over-budget";
            return out;
        }
        text = str(d.text or "");
        m = VERDICT.search(text);
        verdict = str(m.group(1)) if m else "CONTINUE";
        out.verdicts.append(verdict);
        follow = "";
        if verdict == "DONE" {
            if not s.has_accept {
                out.status = "done";
                return out;
            }
            if _accept(s, out, f"after review {rnd}") {
                out.status = "works";
                return out;
            }
            out.status = "done-not-working";
            if rnd == max_rounds {
                return out;
            }
            follow = feedback(out.accepts[-1]);
        } else {
            out.status = "incomplete";
            if rnd == max_rounds {
                return out;
            }
            follow = "Review from the supervising developer:\n\n" + (text[m.end():].strip() if m else text.strip());
        }
        if s.over_budget() {
            out.status = "over-budget";
            return out;
        }
        b = s.builder(follow, first=False);
        out.commits.append(str(s.snapshot(f"builder round {rnd}")));
    }
    return out;
}

def run_protocol(name: str, s: any) -> Outcome {
    if name == "one-shot" {
        return one_shot(s);
    }
    if name == "accept-loop" {
        return accept_loop(s);
    }
    if name == "reviewed" {
        return reviewed(s);
    }
    raise KeyError(f"no protocol {name!r}; known: one-shot, accept-loop, reviewed");
}
