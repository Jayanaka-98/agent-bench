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

A protocol gets a `Session` (build.py) and returns an `Outcome`.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from . import accept

VERDICT = re.compile(r"^\s*\**\s*VERDICT:\s*(DONE|CONTINUE)\b\**", re.M)


@dataclass
class Outcome:
    status: str = "incomplete"   # works | done-not-working | done | incomplete | over-budget | error
    verdicts: list[str] = field(default_factory=list)
    accepts: list[dict] = field(default_factory=list)
    commits: list[str] = field(default_factory=list)


def _accept(s, out: Outcome, label: str) -> bool:
    out.commits.append(s.snapshot(f"before acceptance, {label}"))
    s.log(f"acceptance ({label})")
    v = s.accept(len(out.accepts) + 1)
    out.accepts.append(v)
    s.log(f"acceptance {'PASS' if v['passed'] else 'FAIL'} {v.get('metrics', {})}")
    return v["passed"]


def one_shot(s) -> Outcome:
    out = Outcome()
    b = s.builder(s.prompt, first=True)
    out.commits.append(s.snapshot("builder round 0"))
    if b.over_budget:
        out.status = "over-budget"
        return out
    if b.is_error and not b.text:
        out.status = "error"
    if not s.has_accept:
        out.status = "done" if out.status != "error" else "error"
        return out
    out.status = "works" if _accept(s, out, "one-shot") else "done-not-working"
    return out


def accept_loop(s) -> Outcome:
    out = Outcome()
    b = s.builder(s.prompt, first=True)
    out.commits.append(s.snapshot("builder round 0"))
    for rnd in range(1, s.max_rounds + 1):
        if b.over_budget or s.over_budget():
            out.status = "over-budget"
            return out
        if _accept(s, out, f"round {rnd}"):
            out.status = "works"
            return out
        out.status = "done-not-working"
        if rnd == s.max_rounds:
            break
        b = s.builder(accept.feedback(out.accepts[-1]), first=False)
        out.commits.append(s.snapshot(f"builder round {rnd}"))
    return out


def reviewed(s) -> Outcome:
    out = Outcome()
    b = s.builder(s.prompt, first=True)
    out.commits.append(s.snapshot("builder round 0"))
    for rnd in range(1, s.max_rounds + 1):
        if b.over_budget or s.over_budget():
            out.status = "over-budget"
            return out
        msg = (s.driver_intro + "\n\n" if rnd == 1 else "") + (
            f"## Review round {rnd} of {s.max_rounds}\n\n"
            f"The builder's report:\n\n{b.text or '(the builder produced no final message)'}")
        d = s.driver(msg, first=rnd == 1)
        if d.over_budget:
            out.status = "over-budget"
            return out
        m = VERDICT.search(d.text or "")
        verdict = m.group(1) if m else "CONTINUE"
        out.verdicts.append(verdict)
        if verdict == "DONE":
            if not s.has_accept:
                out.status = "done"
                return out
            if _accept(s, out, f"after review {rnd}"):
                out.status = "works"
                return out
            out.status = "done-not-working"
            if rnd == s.max_rounds:
                return out
            feedback = accept.feedback(out.accepts[-1])
        else:
            out.status = "incomplete"
            if rnd == s.max_rounds:
                return out
            feedback = "Review from the supervising developer:\n\n" + (
                (d.text or "")[m.end():].strip() if m else (d.text or "").strip())
        if s.over_budget():
            out.status = "over-budget"
            return out
        b = s.builder(feedback, first=False)
        out.commits.append(s.snapshot(f"builder round {rnd}"))
    return out


PROTOCOLS = {"one-shot": one_shot, "accept-loop": accept_loop, "reviewed": reviewed}
