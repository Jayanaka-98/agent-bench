"""The effortbench TUI: launch experiments and watch builds as they happen.

    effortbench tui [--runs RUNS_DIR] [--experiments DIR ...]

- **Home**: the runs under RUNS_DIR (builds finished / total, working, running)
  and the experiment files found. `n` launches the highlighted experiment as a
  detached process (its log is <run>/runner.log), so quitting the TUI never
  stops a run.
- **Run**: every build with its state, status, metered tokens so far, model
  calls and time, refreshed every 2 s; below it, the highlighted build's
  trace as it happens. `a` is the aggregate report, `l` the runner log.
- **Build**: the trace (filter by role, kind, or a regex), the metered calls,
  the summary, the prompt, and the acceptance runs.

Everything here reads the same files the CLI does; the CLI stays the way a
supervising Claude session drives the harness.
"""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import sys
from datetime import datetime
from pathlib import Path

from rich.text import Text
from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import ModalScreen, Screen
from textual.widgets import (DataTable, Footer, Header, Input, Label, RichLog, Static, TabbedContent,
                             TabPane)

from . import agents, report
from . import trace as tr
from .agents.base import BuilderSpec

STATUS_STYLE = {"works": "bold green", "done": "green", "done-not-working": "bold red", "incomplete": "yellow",
                "over-budget": "magenta", "error": "bold red", "running": "cyan", "prepared": "dim"}
KIND_STYLE = {"bash": "yellow", "read": "blue", "write": "green", "edit": "green", "search": "blue",
              "skill": "magenta", "web": "cyan", "subagent": "magenta", "plan": "dim"}


def fmt_tokens(n) -> str:
    if n in ("", None):
        return ""
    n = int(n)
    return f"{n / 1e6:.2f}M" if n >= 1e6 else f"{n / 1e3:.0f}K" if n >= 1e3 else str(n)


def styled(s: str) -> Text:
    return Text(s, style=STATUS_STYLE.get(s, ""))


# ---------------------------------------------------------------------------
# Reading builds, finished or live
# ---------------------------------------------------------------------------

_event_cache: dict[tuple, list] = {}


def build_events(bdir: Path) -> list[tr.Event]:
    """A build's trace: trace.jsonl, plus, while it runs, the transcripts not
    yet folded into it, read through the build's own adapter."""
    events = list(tr.read(bdir / "trace.jsonl"))
    if (bdir / "summary.json").exists():
        return events
    meta = bdir / "build.json"
    if not meta.exists():
        return events
    b = json.loads(meta.read_text())["builder"]
    done = {(e.role, e.seq) for e in events}
    for t in sorted((bdir / "transcripts").glob("*.jsonl")):
        m = re.match(r"(\d+)-(builder|driver)", t.name)
        if not m or (m.group(2), int(m.group(1))) in done:
            continue
        key = (str(t), t.stat().st_mtime, t.stat().st_size)
        if key not in _event_cache:
            spec = (BuilderSpec(name=b["name"], agent=b["agent"], model=b.get("model", ""))
                    if m.group(2) == "builder" else BuilderSpec(name="driver", agent="claude-code"))
            try:
                _event_cache[key] = list(agents.make(spec).events(t, m.group(2), int(m.group(1))))
            except Exception:  # noqa: BLE001 - a half-written transcript
                _event_cache[key] = []
        events += _event_cache[key]
    return events


def event_line(e: tr.Event, width: int = 220) -> Text:
    head = Text(f"{e.seq:02d} {e.role[:7]:<7} ", style="dim")
    if e.type == "tool_call":
        arg = e.input.get("command") or e.input.get("file_path") or e.input.get("path") or \
            e.input.get("pattern") or e.input.get("skill") or json.dumps(e.input)
        body = Text(f"{e.tool}", style=f"bold {KIND_STYLE.get(e.kind, '')}") + Text(f" {arg}")
    elif e.type == "tool_result":
        out = (e.output or "").strip().replace("\n", " ⏎ ")
        body = Text("  ↳ ", style="dim") + Text(out, style="red" if e.is_error else "dim")
    elif e.type == "usage":
        u = e.usage or {}
        body = Text(f"  · call {json.dumps(u)}", style="dim italic")
    elif e.type == "final":
        body = Text("■ " + (e.text or "").strip().replace("\n", " ⏎ "), style="bold")
    else:
        body = Text((e.text or "").strip().replace("\n", " ⏎ "))
    line = head + body
    line.truncate(width)
    return line


def runs(runs_dir: Path) -> list[dict]:
    out = []
    if not runs_dir.exists():
        return out
    for rd in sorted((p for p in runs_dir.iterdir() if (p / "manifest.json").exists()),
                     key=lambda p: p.stat().st_mtime, reverse=True):
        m = json.loads((rd / "manifest.json").read_text())
        st = report.status(rd)
        done = [s for s in st if s["state"] == "finished"]
        out.append({"run": rd.name, "dir": rd, "builds": len(st), "finished": len(done),
                    "works": sum(s.get("status") == "works" for s in done),
                    "running": sum(s["state"] == "running" for s in st),
                    "alive": runner_alive(rd), "started": m.get("started", "")[:16].replace("T", " ")})
    return out


def runner_alive(run_dir: Path) -> bool:
    pid = run_dir / "runner.pid"
    if not pid.exists():
        return False
    try:
        os.kill(int(pid.read_text().strip()), 0)
        return True
    except (ValueError, ProcessLookupError, PermissionError):
        return False


def launch(experiment: Path, run_id: str, only: list[str] = ()) -> Path:
    """Start `effortbench run` detached; returns the run directory."""
    from .config import Experiment
    exp = Experiment.load(experiment, run_id or None)
    rd = exp.runs_dir / exp.run_id
    rd.mkdir(parents=True, exist_ok=True)
    cmd = [sys.executable, "-m", "effortbench.cli", "run", str(experiment), "--run-id", exp.run_id]
    if only:
        cmd += ["--only", *only]
    with (rd / "runner.log").open("a") as log:
        log.write(f"\n[{datetime.now():%H:%M:%S}] launched from the TUI: {' '.join(cmd)}\n")
        p = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                             start_new_session=True, cwd=experiment.parent)
    (rd / "runner.pid").write_text(str(p.pid))
    return rd


# ---------------------------------------------------------------------------
# Screens
# ---------------------------------------------------------------------------

class Ask(ModalScreen[str | None]):
    """One line of input, or a yes/no (enter = yes, escape = no)."""
    BINDINGS = [Binding("escape", "cancel", "Cancel")]

    def __init__(self, question: str, default: str = "", confirm: bool = False) -> None:
        super().__init__()
        self.question, self.default, self.confirm = question, default, confirm

    def compose(self) -> ComposeResult:
        with Vertical(id="ask"):
            yield Label(self.question)
            yield Input(value=self.default, placeholder="enter = yes, esc = no" if self.confirm else "")

    def on_input_submitted(self, ev: Input.Submitted) -> None:
        self.dismiss(ev.value if not self.confirm else "yes")

    def action_cancel(self) -> None:
        self.dismiss(None)


class TextScreen(Screen):
    BINDINGS = [Binding("escape,q", "app.pop_screen", "Back")]

    def __init__(self, title: str, text: str) -> None:
        super().__init__()
        self.title_text, self.body = title, text

    def compose(self) -> ComposeResult:
        yield Header()
        log = RichLog(wrap=True, markup=False, highlight=True)
        yield log
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = self.title_text
        self.query_one(RichLog).write(self.body)


class ReportScreen(Screen):
    BINDINGS = [Binding("escape,q", "app.pop_screen", "Back"), Binding("b", "regroup", "Group by")]

    def __init__(self, run_dirs: list[Path]) -> None:
        super().__init__()
        self.run_dirs, self.by = run_dirs, "task,arm,builder"

    def compose(self) -> ComposeResult:
        yield Header()
        yield DataTable(zebra_stripes=True)
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = "report: " + ", ".join(p.name for p in self.run_dirs)
        self.fill()

    def fill(self) -> None:
        t = self.query_one(DataTable)
        t.clear(columns=True)
        rows = report.aggregate(self.run_dirs, tuple(self.by.split(",")))
        if not rows:
            return
        t.add_columns(*rows[0].keys())
        for r in rows:
            t.add_row(*[fmt_tokens(v) if k.startswith("tokens") else str(v) for k, v in r.items()])

    def action_regroup(self) -> None:
        def done(v):
            if v:
                self.by = v
                self.fill()
        self.app.push_screen(Ask("group by (comma list of task, arm, builder, agent, model)", self.by), done)


class BuildScreen(Screen):
    BINDINGS = [Binding("escape,q", "app.pop_screen", "Back"), Binding("f", "filter", "Filter trace"),
                Binding("r", "reload", "Reload")]

    def __init__(self, bdir: Path) -> None:
        super().__init__()
        self.bdir, self.filter, self.shown = bdir, "", 0

    def compose(self) -> ComposeResult:
        yield Header()
        yield Static(id="head")
        with TabbedContent():
            with TabPane("Trace", id="t-trace"):
                yield RichLog(id="trace", wrap=False, markup=False, max_lines=20000)
            with TabPane("Calls", id="t-calls"):
                yield DataTable(id="calls", zebra_stripes=True)
            with TabPane("Summary", id="t-summary"):
                yield RichLog(id="summary", wrap=True, highlight=True)
            with TabPane("Prompt", id="t-prompt"):
                yield RichLog(id="prompt", wrap=True, markup=False)
            with TabPane("Acceptance", id="t-accept"):
                yield RichLog(id="accept", wrap=True, markup=False)
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = self.bdir.name
        self.action_reload()
        self.set_interval(2, self.tick)

    def matches(self, e: tr.Event) -> bool:
        if not self.filter:
            return True
        for term in self.filter.split():
            k, _, v = term.partition("=")
            if v:
                if (k == "role" and e.role != v) or (k == "kind" and e.kind != v and e.type != v):
                    return False
            elif not re.search(term, event_line(e, 100000).plain, re.I):
                return False
        return True

    def tick(self) -> None:
        if (self.bdir / "summary.json").exists() and self.shown:
            return
        evs = build_events(self.bdir)
        log = self.query_one("#trace", RichLog)
        for e in evs[self.shown:]:
            if self.matches(e):
                log.write(event_line(e))
        self.shown = len(evs)
        self.head()

    def head(self) -> None:
        meta = json.loads((self.bdir / "build.json").read_text()) if (self.bdir / "build.json").exists() else {}
        s = json.loads((self.bdir / "summary.json").read_text()) if (self.bdir / "summary.json").exists() else None
        b = meta.get("builder", {})
        if s:
            tk = s["tokens"]["builder"]
            line = (f"[b]{s['status']}[/b]  builder {b.get('agent')} {b.get('model')}  "
                    f"tokens {fmt_tokens(tk['total'])} ({tk['source']}, {tk['calls']} calls)  "
                    f"driver {fmt_tokens(s['tokens']['driver']['total'])}  rounds {s['rounds']}  "
                    f"{s['wall_s'] / 60:.1f} min  acceptance runs {s['acceptance_runs']}")
        else:
            calls = self.calls()
            tot = sum((c.get("usage") or {}).get("total", 0) for c in calls)
            line = (f"[cyan b]running[/]  builder {b.get('agent')} {b.get('model')}  "
                    f"metered so far {fmt_tokens(tot)} in {len(calls)} calls")
        self.query_one("#head", Static).update(line)

    def calls(self) -> list[dict]:
        p = self.bdir / "calls.jsonl"
        if p.exists():
            return [json.loads(l) for l in p.read_text().splitlines()]
        meta = self.bdir / "build.json"
        ledger = self.bdir.parent / "proxy" / "ledger.jsonl"
        if not meta.exists() or not ledger.exists():
            return []
        tag = json.loads(meta.read_text())["proxy_tag"] + "."
        return [json.loads(l) for l in ledger.read_text().splitlines() if f'"tag": "{tag}' in l]

    def action_reload(self) -> None:
        self.shown = 0
        self.query_one("#trace", RichLog).clear()
        self.tick()
        t = self.query_one("#calls", DataTable)
        t.clear(columns=True)
        t.add_columns("time", "role", "model", "input", "cache read", "cache write", "output", "total", "ms",
                      "stream")
        for c in self.calls():
            u = c.get("usage") or {}
            t.add_row(datetime.fromtimestamp(c["ts"]).strftime("%H:%M:%S"), c["tag"].rsplit(".", 1)[-1],
                      c.get("model") or c.get("request_model", ""), *(str(u.get(k, "")) for k in
                      ("input", "cache_read", "cache_write", "output", "total")), str(c.get("ms", "")),
                      "y" if c.get("stream") else "")
        for wid, path in (("#summary", "summary.json"), ("#prompt", "prompt-builder.md")):
            log = self.query_one(wid, RichLog)
            log.clear()
            f = self.bdir / path
            log.write(f.read_text() if f.exists() else f"({path} not written yet)")
        acc = self.query_one("#accept", RichLog)
        acc.clear()
        for f in sorted((self.bdir / "acceptance").glob("accept-*.log")) if (self.bdir / "acceptance").exists() else []:
            acc.write(f"── {f.name} ──\n" + f.read_text(errors="replace")[-20000:])
        if (self.bdir / "acceptance.jsonl").exists():
            acc.write("── verdicts ──\n" + (self.bdir / "acceptance.jsonl").read_text())

    def action_filter(self) -> None:
        def done(v):
            if v is not None:
                self.filter = v
                self.action_reload()
        self.app.push_screen(Ask("trace filter: role=builder kind=bash and/or a regex (empty = all)", self.filter),
                             done)


class RunScreen(Screen):
    BINDINGS = [Binding("escape,q", "app.pop_screen", "Back"), Binding("enter", "open", "Open build", show=True),
                Binding("a", "report", "Report"), Binding("l", "log", "Runner log"),
                Binding("s", "stop", "Stop run")]

    def __init__(self, run_dir: Path) -> None:
        super().__init__()
        self.run_dir, self.rows, self.tail_for, self.tail_n = run_dir, [], None, 0

    def compose(self) -> ComposeResult:
        yield Header()
        with Vertical():
            yield DataTable(id="builds", zebra_stripes=True, cursor_type="row")
            yield Label("", id="tail-title")
            yield RichLog(id="tail", wrap=False, markup=False, max_lines=400)
        yield Footer()

    def on_mount(self) -> None:
        t = self.query_one("#builds", DataTable)
        t.add_columns("build", "state", "status", "tokens", "calls", "min", "turns", "accept")
        self.refresh_rows()
        self.set_interval(2, self.refresh_rows)

    def refresh_rows(self) -> None:
        self.sub_title = f"{self.run_dir.name}  ({'runner alive' if runner_alive(self.run_dir) else 'no runner'})"
        t = self.query_one("#builds", DataTable)
        cur = t.cursor_row
        self.rows = report.status(self.run_dir)
        t.clear()
        for s in self.rows:
            fin = s["state"] == "finished"
            t.add_row(s["build"], styled(s["state"]), styled(s.get("status", "")),
                      fmt_tokens(s.get("builder_tokens") if fin else s.get("metered_tokens_so_far")),
                      str(s.get("calls") if fin else s.get("calls_so_far", "")),
                      str(s.get("wall_min", "")), str(s.get("turns_done", "")),
                      str(s.get("acceptance_runs", "")), key=s["build"])
        if self.rows:
            t.move_cursor(row=min(max(cur, 0), len(self.rows) - 1))
        self.tail()

    def current(self) -> Path | None:
        t = self.query_one("#builds", DataTable)
        if not self.rows or t.cursor_row < 0 or t.cursor_row >= len(self.rows):
            return None
        return self.run_dir / self.rows[t.cursor_row]["build"]

    def tail(self) -> None:
        b = self.current()
        log = self.query_one("#tail", RichLog)
        if b != self.tail_for:
            self.tail_for, self.tail_n = b, 0
            log.clear()
            self.query_one("#tail-title", Label).update(f"── {b.name if b else ''} ──")
        if b is None:
            return
        evs = [e for e in build_events(b) if e.type != "usage"]
        if self.tail_n == 0:
            evs_new = evs[-60:]
        else:
            evs_new = evs[self.tail_n:]
        for e in evs_new:
            log.write(event_line(e, 400))
        self.tail_n = len(evs)

    def on_data_table_row_highlighted(self, ev: DataTable.RowHighlighted) -> None:
        self.tail()

    def on_data_table_row_selected(self, ev: DataTable.RowSelected) -> None:
        self.action_open()

    def action_open(self) -> None:
        b = self.current()
        if b:
            self.app.push_screen(BuildScreen(b))

    def action_report(self) -> None:
        self.app.push_screen(ReportScreen([self.run_dir]))

    def action_log(self) -> None:
        f = self.run_dir / "runner.log"
        self.app.push_screen(TextScreen("runner.log", f.read_text(errors="replace")[-100000:] if f.exists()
                                        else "(no runner.log: this run was not launched from the TUI)"))

    def action_stop(self) -> None:
        if not runner_alive(self.run_dir):
            self.notify("no live runner for this run")
            return

        def done(v):
            if v:
                pid = int((self.run_dir / "runner.pid").read_text())
                os.killpg(pid, signal.SIGTERM)
                self.notify(f"sent SIGTERM to runner {pid}; re-launching resumes unfinished builds")
        self.app.push_screen(Ask(f"Stop the runner of {self.run_dir.name}? Running builds are killed.",
                                 confirm=True), done)


class HomeScreen(Screen):
    BINDINGS = [Binding("q", "app.quit", "Quit"), Binding("enter", "open", "Open"),
                Binding("n", "launch", "Launch experiment"), Binding("c", "compare", "Compare runs"),
                Binding("tab", "app.focus_next", "Switch pane", show=False)]

    def __init__(self, runs_dir: Path, exp_dirs: list[Path]) -> None:
        super().__init__()
        self.runs_dir, self.exp_dirs, self.run_rows, self.exps = runs_dir, exp_dirs, [], []

    def compose(self) -> ComposeResult:
        yield Header()
        with Horizontal():
            with Vertical(id="left"):
                yield Label("[b]Runs[/b]  (enter: open, c: compare all)")
                yield DataTable(id="runs", cursor_type="row", zebra_stripes=True)
            with Vertical(id="right"):
                yield Label("[b]Experiments[/b]  (n: launch)")
                yield DataTable(id="exps", cursor_type="row", zebra_stripes=True)
        yield Footer()

    def on_mount(self) -> None:
        self.sub_title = str(self.runs_dir)
        self.query_one("#runs", DataTable).add_columns("run", "finished", "works", "running", "runner", "started")
        e = self.query_one("#exps", DataTable)
        e.add_columns("experiment", "path")
        for d in self.exp_dirs:
            for f in sorted(d.rglob("*.toml")) if d.is_dir() else [d]:
                if self.runs_dir in f.parents:  # a run's own copy of its experiment
                    continue
                try:
                    txt = f.read_text()
                except OSError:
                    continue
                if "[[builders]]" in txt and "tasks" in txt:
                    self.exps.append(f)
                    e.add_row(f.stem, str(f.parent), key=str(f))
        self.refresh_runs()
        self.set_interval(3, self.refresh_runs)

    def refresh_runs(self) -> None:
        t = self.query_one("#runs", DataTable)
        cur = t.cursor_row
        self.run_rows = runs(self.runs_dir)
        t.clear()
        for r in self.run_rows:
            t.add_row(r["run"], f"{r['finished']}/{r['builds']}", str(r["works"]), str(r["running"]),
                      Text("alive", style="green") if r["alive"] else Text("-", style="dim"), r["started"],
                      key=r["run"])
        if self.run_rows:
            t.move_cursor(row=min(max(cur, 0), len(self.run_rows) - 1))

    def action_open(self) -> None:
        if self.focused is self.query_one("#exps", DataTable):
            self.action_launch()
            return
        t = self.query_one("#runs", DataTable)
        if self.run_rows and 0 <= t.cursor_row < len(self.run_rows):
            self.app.push_screen(RunScreen(self.run_rows[t.cursor_row]["dir"]))

    def on_data_table_row_selected(self, ev: DataTable.RowSelected) -> None:
        self.action_open()

    def action_compare(self) -> None:
        if self.run_rows:
            self.app.push_screen(ReportScreen([r["dir"] for r in self.run_rows]))

    def action_launch(self) -> None:
        t = self.query_one("#exps", DataTable)
        if not self.exps or not (0 <= t.cursor_row < len(self.exps)):
            self.notify("no experiment selected")
            return
        f = self.exps[t.cursor_row]
        default = re.search(r'^run_id\s*=\s*"([^"]+)"', f.read_text(), re.M)

        def done(v):
            if v is None:
                return
            run_id, _, only = v.partition(" ")
            try:
                rd = launch(f, run_id.strip(), only.split())
            except Exception as e:  # noqa: BLE001
                self.notify(f"launch failed: {e}", severity="error")
                return
            self.notify(f"launched {rd.name}")
            self.refresh_runs()
            self.app.push_screen(RunScreen(rd))
        self.app.push_screen(Ask(f"Launch {f.name}: run id [space-separated --only filters]",
                                 default.group(1) if default else ""), done)


class EffortBench(App):
    TITLE = "effortbench"
    CSS = """
    #left, #right { width: 1fr; }
    #builds { height: 1fr; }
    #tail { height: 1fr; border-top: solid $primary; }
    #ask { width: 80; height: auto; padding: 1 2; border: thick $primary; background: $surface; }
    Ask { align: center middle; }
    #head { padding: 0 1; height: auto; }
    """

    def __init__(self, runs_dir: Path, exp_dirs: list[Path], run: Path | None = None) -> None:
        super().__init__()
        self.runs_dir, self.exp_dirs, self.start_run = runs_dir, exp_dirs, run

    def on_mount(self) -> None:
        self.push_screen(HomeScreen(self.runs_dir, self.exp_dirs))
        if self.start_run:
            self.push_screen(RunScreen(self.start_run))


def main(runs_dir: str = "runs", experiments: list[str] = (), run: str | None = None) -> int:
    EffortBench(Path(runs_dir).resolve(), [Path(e).resolve() for e in experiments] or [Path.cwd()],
                Path(run).resolve() if run else None).run()
    return 0
