"""The agent-bench TUI: launch experiments and watch builds as they happen.

    agent-bench tui [--runs RUNS_DIR] [--experiments DIR ...] [--server URL]
    agent-bench monitor [RUNS_DIR ...] [--server URL]

Every screen reads through one `Api`: the server API (server/api.jac), called
in-process (`LocalApi`) or over HTTP from an `agent-bench serve` (`HttpApi`),
which is how the TUI watches another machine. The web UI calls the same API.

- **Home**: runs and experiment files. `n` launches the highlighted
  experiment as a detached process, so quitting the TUI never stops a run.
- **Monitor** (`m`): everything running now, across runs, refreshed every 2 s.
- **Run**: every build live, with the highlighted build's trace below it.
- **Build**: trace (filterable), metered calls, summary, prompt, acceptance.
"""

import json;
import re;
import urllib.request;
import from datetime { datetime }
import from pathlib { Path }
import from rich.text { Text }
import from textual.app { App, ComposeResult }
import from textual.binding { Binding }
import from textual.containers { Horizontal, Vertical }
import from textual.screen { ModalScreen, Screen }
import from textual.widgets {
    DataTable, Footer, Header, Input, Label, RichLog, Sparkline, Static, TabbedContent, TabPane
}
import from agent_bench.common { Json }
import agent_bench.server.api as api;

glob STATUS_STYLE: dict[str, str] = {
    "works": "bold green", "done": "green", "done-not-working": "bold red", "incomplete": "yellow",
    "over-budget": "magenta", "error": "bold red", "running": "cyan", "prepared": "dim", "stopped": "bold red"
};
glob KIND_STYLE: dict[str, str] = {
    "bash": "yellow", "read": "blue", "write": "green", "edit": "green", "search": "blue",
    "skill": "magenta", "web": "cyan", "subagent": "magenta", "plan": "dim"
};
glob CALLS: list[str] = [
    "info", "list_runs", "run_builds", "monitor", "build_info", "build_trace", "build_calls", "build_file",
    "aggregate", "list_experiments", "launch", "stop_run", "runner_log"
];

# ---------------------------------------------------------------------------
# The API, in-process or over HTTP
# ---------------------------------------------------------------------------

obj Api {
    def call(name: str, args: Json = {}) -> any {
        raise NotImplementedError(name);
    }

    def where -> str {
        return "";
    }
}

"""The server API's functions, called directly."""
obj LocalApi(Api) {
    has runs_dirs: list[Path],
        exp_dirs: list[Path];

    def postinit {
        api.configure(self.runs_dirs, self.exp_dirs);
    }

    def call(name: str, args: Json = {}) -> any {
        if name not in CALLS {
            raise KeyError(name);
        }
        return getattr(api, name)(**args);
    }

    def where -> str {
        return ", ".join([str(p) for p in self.runs_dirs]);
    }
}

"""An `agent-bench serve` elsewhere: POST /function/<name>, the result unwrapped."""
obj HttpApi(Api) {
    has base: str,
        timeout: float = 15.0;

    def call(name: str, args: Json = {}) -> any {
        req = urllib.request.Request(
            f"{self.base.rstrip('/')}/function/{name}", data=json.dumps(args).encode(),
            headers={"Content-Type": "application/json"}, method="POST"
        );
        with urllib.request.urlopen(req, timeout=self.timeout) as r {
            env = json.loads(r.read()) as Json;
        }
        if not env.get("ok") {
            err: Json = env.get("error") or {};
            raise RuntimeError(str(err.get("message") or err or "request failed"));
        }
        data: Json = env.get("data") or {};
        return data.get("result");
    }

    def where -> str {
        return self.base;
    }
}

# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------

def fmt_tokens(n: any) -> str {
    if n in ("", None) {
        return "";
    }
    v = int(n);
    if v >= 1000000 {
        return f"{v / 1000000:.2f}M";
    }
    return f"{v / 1000:.0f}K" if v >= 1000 else str(v);
}

def styled(s: str) -> Text {
    return Text(s, style=STATUS_STYLE.get(s, ""));
}

def dur(s: float) -> str {
    t = int(max(s, 0));
    return f"{t // 3600}h{(t % 3600) // 60:02d}m" if t >= 3600 else f"{t // 60}m{t % 60:02d}s";
}

"""A long first `jac check` or a big install can be quiet for minutes; past a
quarter of an hour it is worth a look."""
def quiet_text(s: float) -> Text {
    style = "bold red" if s > 900 else ("yellow" if s > 300 else "dim");
    return Text(dur(s), style=style);
}

def phase_text(phase: str, state: str) -> Text {
    if state == "stopped" {
        return Text(f"STOPPED ({phase})", style="bold red");
    }
    style = "";
    if phase.startswith("limit") {
        style = "magenta";
    } elif phase.startswith("acceptance") {
        style = "cyan";
    } elif phase.startswith("driver") {
        style = "blue";
    } elif "retry" in phase {
        style = "yellow";
    }
    return Text(phase, style=style);
}

def event_line(e: Json, width: int = 220) -> Text {
    head = Text(f"{int(e.get('seq') or 0):02d} {str(e.get('role') or '')[:7]:<7} ", style="dim");
    kind = str(e.get("type", ""));
    body = Text("");
    if kind == "tool_call" {
        inp: Json = e.get("input") or {};
        arg = inp.get("command") or inp.get("file_path") or inp.get("path") or inp.get("pattern")
            or inp.get("skill") or json.dumps(inp);
        body = Text(str(e.get("tool", "")), style="bold " + KIND_STYLE.get(str(e.get("kind", "")), ""))
            + Text(" " + str(arg));
    } elif kind == "tool_result" {
        out = str(e.get("output") or "").strip().replace("\n", " ⏎ ");
        body = Text("  ↳ ", style="dim") + Text(out, style="red" if e.get("is_error") else "dim");
    } elif kind == "usage" {
        body = Text(f"  · call {json.dumps(e.get('usage'))}", style="dim italic");
    } elif kind == "final" {
        body = Text("■ " + str(e.get("text") or "").strip().replace("\n", " ⏎ "), style="bold");
    } else {
        body = Text(str(e.get("text") or "").strip().replace("\n", " ⏎ "));
    }
    line = head + body;
    line.truncate(width);
    return line;
}

# ---------------------------------------------------------------------------
# Screens
# ---------------------------------------------------------------------------

"""The running app, typed: the checker reads Textual's `Screen.app` as a method."""
def app_of(screen: any) -> AgentBench {
    return screen.app as AgentBench;
}

"""One line of input, or a yes/no (enter = yes, escape = no)."""
class Ask(ModalScreen) {
    static has BINDINGS: list[Binding] = [Binding("escape", "cancel", "Cancel")];

    def init(self: Ask, question: str, default_value: str = "", confirm: bool = False) {
        super.init();
        self.question = question;
        self.default_value = default_value;
        self.confirm = confirm;
    }

    def compose(self: Ask) -> ComposeResult {
        with Vertical(id="ask") {
            yield Label(self.question);
            yield Input(value=self.default_value, placeholder="enter = yes, esc = no" if self.confirm else "");
        }
    }

    def on_input_submitted(self: Ask, ev: Input.Submitted) {
        self.dismiss("yes" if self.confirm else ev.value);
    }

    def action_cancel(self: Ask) {
        self.dismiss(None);
    }
}

class TextScreen(Screen) {
    static has BINDINGS: list[Binding] = [Binding("escape,q", "app.pop_screen", "Back")];

    def init(self: TextScreen, title_text: str, body: str) {
        super.init();
        self.title_text = title_text;
        self.body = body;
    }

    def compose(self: TextScreen) -> ComposeResult {
        yield Header();
        yield RichLog(wrap=True, markup=False, highlight=True);
        yield Footer();
    }

    def on_mount(self: TextScreen) {
        self.sub_title = self.title_text;
        (self.query_one(RichLog) as RichLog).write(self.body);
    }
}

class ReportScreen(Screen) {
    static has BINDINGS: list[Binding] = [Binding("escape,q", "app.pop_screen", "Back"), Binding("b", "regroup", "Group by")];

    def init(self: ReportScreen, runs: list[str]) {
        super.init();
        self.run_names = runs;
        self.group_by = "task,arm,builder";
    }

    def compose(self: ReportScreen) -> ComposeResult {
        yield Header();
        yield DataTable(zebra_stripes=True);
        yield Footer();
    }

    def on_mount(self: ReportScreen) {
        self.sub_title = "report: " + ", ".join(self.run_names);
        self.fill();
    }

    def fill(self: ReportScreen) {
        t = self.query_one(DataTable) as DataTable;
        t.clear(columns=True);
        rows = app_of(self).api.call("aggregate", {"runs": self.run_names, "group_by": self.group_by}) as list[Json];
        if not rows {
            return;
        }
        t.add_columns(*list(rows[0].keys()));
        for r in rows {
            t.add_row(*[fmt_tokens(v) if k.startswith("tokens") else str(v) for (k, v) in r.items()]);
        }
    }

    def action_regroup(self: ReportScreen) {
        def done(v: str | None) {
            if v {
                self.group_by = v;
                self.fill();
            }
        }
        app_of(self).push_screen(Ask("group by (comma list of task, arm, builder, agent, model)", self.group_by), done);
    }
}

class BuildScreen(Screen) {
    static has BINDINGS: list[Binding] = [
        Binding("escape,q", "app.pop_screen", "Back"), Binding("f", "filter", "Filter trace"),
        Binding("r", "reload", "Reload")
    ];

    def init(self: BuildScreen, run: str, build: str) {
        super.init();
        self.run = run;
        self.build = build;
        self.filter = "";
        self.trace_pos = 0;
        self.summary_seen = False;
    }

    def compose(self: BuildScreen) -> ComposeResult {
        yield Header();
        yield Static(id="head");
        with TabbedContent() {
            with TabPane("Trace", id="t-trace") {
                yield RichLog(id="trace", wrap=False, markup=False, max_lines=20000);
            }
            with TabPane("Calls", id="t-calls") {
                yield DataTable(id="calls", zebra_stripes=True);
            }
            with TabPane("Summary", id="t-summary") {
                yield RichLog(id="summary", wrap=True, highlight=True);
            }
            with TabPane("Prompt", id="t-prompt") {
                yield RichLog(id="prompt", wrap=True, markup=False);
            }
            with TabPane("Acceptance", id="t-accept") {
                yield RichLog(id="accept", wrap=True, markup=False);
            }
        }
        yield Footer();
    }

    def on_mount(self: BuildScreen) {
        self.sub_title = f"{self.run} / {self.build}";
        self.action_reload();
        self.set_interval(2, self.tick);
    }

    def matches(self: BuildScreen, e: Json) -> bool {
        if not self.filter {
            return True;
        }
        for term in self.filter.split() {
            (k, _, v) = term.partition("=");
            if v {
                if (k == "role" and e.get("role") != v) or (k == "kind" and e.get("kind") != v and e.get("type") != v) {
                    return False;
                }
            } elif not re.search(term, event_line(e, 100000).plain, re.I) {
                return False;
            }
        }
        return True;
    }

    def tick(self: BuildScreen) {
        if self.summary_seen and self.trace_pos {
            return;
        }
        t = app_of(self).api.call("build_trace", {"run": self.run, "build": self.build, "offset": self.trace_pos}) as Json;
        log = self.query_one("#trace", RichLog) as RichLog;
        for e in t["events"] {
            if self.matches(e) {
                log.write(event_line(e));
            }
        }
        self.trace_pos = int(t["next"]);
        self.head();
    }

    def head(self: BuildScreen) {
        i = app_of(self).api.call("build_info", {"run": self.run, "build": self.build}) as Json;
        meta: Json = i.get("meta") or {};
        b: Json = meta.get("builder") or {};
        s: Json | None = i.get("summary");
        line = "";
        if s {
            self.summary_seen = True;
            tk: Json = s["tokens"]["builder"];
            line = f"[b]{s['status']}[/b]  builder {b.get('agent')} {b.get('model')}  tokens {fmt_tokens(tk['total'])} "
                + f"({tk['source']}, {tk['calls']} calls)  driver {fmt_tokens(s['tokens']['driver']['total'])}  "
                + f"rounds {s['rounds']}  {float(s['wall_s']) / 60:.1f} min  acceptance runs {s['acceptance_runs']}";
        } else {
            live: Json = i.get("live") or {};
            line = f"[cyan b]{live.get('phase', i.get('state'))}[/]  builder {b.get('agent')} {b.get('model')}  "
                + f"metered so far {fmt_tokens(i.get('metered_tokens'))} in {i.get('calls')} calls";
        }
        (self.query_one("#head", Static) as Static).update(line);
    }

    def action_reload(self: BuildScreen) {
        self.trace_pos = 0;
        self.summary_seen = False;
        (self.query_one("#trace", RichLog) as RichLog).clear();
        self.tick();
        t = self.query_one("#calls", DataTable) as DataTable;
        t.clear(columns=True);
        t.add_columns("time", "role", "model", "input", "cache read", "cache write", "output", "total", "ms", "stream");
        for c in app_of(self).api.call("build_calls", {"run": self.run, "build": self.build}) as list[Json] {
            u: Json = c.get("usage") or {};
            t.add_row(
                datetime.fromtimestamp(float(c.get("ts") or 0)).strftime("%H:%M:%S"), str(c.get("role")),
                str(c.get("model") or ""), *[str(u.get(k, "")) for k in ("input", "cache_read", "cache_write", "output", "total")],
                str(c.get("ms", "")), "y" if c.get("stream") else ""
            );
        }
        for (wid, name) in (("#summary", "summary.json"), ("#prompt", "prompt-builder.md"), ("#accept", "acceptance")) {
            log = self.query_one(wid, RichLog) as RichLog;
            log.clear();
            text = str(app_of(self).api.call("build_file", {"run": self.run, "build": self.build, "name": name}));
            log.write(text or f"({name} not written yet)");
        }
    }

    def action_filter(self: BuildScreen) {
        def done(v: str | None) {
            if v is not None {
                self.filter = v;
                self.action_reload();
            }
        }
        app_of(self).push_screen(Ask("trace filter: role=builder kind=bash and/or a regex (empty = all)", self.filter), done);
    }
}

class RunScreen(Screen) {
    static has BINDINGS: list[Binding] = [
        Binding("escape,q", "app.pop_screen", "Back"), Binding("enter", "open", "Open build", show=True),
        Binding("a", "report", "Report"), Binding("l", "log", "Runner log"), Binding("s", "stop", "Stop run")
    ];

    def init(self: RunScreen, run: str) {
        super.init();
        self.run = run;
        self.rows: list[Json] = [];
        self.tail_for = "";
        self.tail_offset = 0;
    }

    def compose(self: RunScreen) -> ComposeResult {
        yield Header();
        with Vertical() {
            yield DataTable(id="builds", zebra_stripes=True, cursor_type="row");
            yield Label("", id="tail-title");
            yield RichLog(id="tail", wrap=False, markup=False, max_lines=400);
        }
        yield Footer();
    }

    def on_mount(self: RunScreen) {
        (self.query_one("#builds", DataTable) as DataTable).add_columns(
            "build", "state", "status", "tokens", "calls", "min", "turns", "accept");
        self.refresh_rows();
        self.set_interval(2, self.refresh_rows);
    }

    def refresh_rows(self: RunScreen) {
        self.sub_title = self.run;
        t = self.query_one("#builds", DataTable) as DataTable;
        cur = t.cursor_row;
        self.rows = app_of(self).api.call("run_builds", {"run": self.run}) as list[Json];
        t.clear();
        for s in self.rows {
            fin = s["state"] == "finished";
            t.add_row(
                str(s["build"]), styled(str(s["state"])), styled(str(s.get("status", ""))),
                fmt_tokens(s.get("builder_tokens") if fin else s.get("metered_tokens_so_far")),
                str(s.get("calls") if fin else s.get("calls_so_far", "")), str(s.get("wall_min", "")),
                str(s.get("turns_done", "")), str(s.get("acceptance_runs", "")), key=str(s["build"])
            );
        }
        if self.rows {
            t.move_cursor(row=min(max(cur, 0), len(self.rows) - 1));
        }
        self.tail();
    }

    def current(self: RunScreen) -> str {
        t = self.query_one("#builds", DataTable) as DataTable;
        if not self.rows or t.cursor_row < 0 or t.cursor_row >= len(self.rows) {
            return "";
        }
        return str(self.rows[t.cursor_row]["build"]);
    }

    def tail(self: RunScreen) {
        b = self.current();
        log = self.query_one("#tail", RichLog) as RichLog;
        if b != self.tail_for {
            self.tail_for = b;
            self.tail_offset = 0;
            log.clear();
            (self.query_one("#tail-title", Label) as Label).update(f"── {b} ──");
        }
        if not b {
            return;
        }
        tr = app_of(self).api.call("build_trace", {"run": self.run, "build": b, "offset": self.tail_offset}) as Json;
        evs = [e for e in tr["events"] if e.get("type") != "usage"];
        for e in (evs[-60:] if self.tail_offset == 0 else evs) {
            log.write(event_line(e, 400));
        }
        self.tail_offset = int(tr["next"]);
    }

    def on_data_table_row_highlighted(self: RunScreen, ev: DataTable.RowHighlighted) {
        self.tail();
    }

    def on_data_table_row_selected(self: RunScreen, ev: DataTable.RowSelected) {
        self.action_open();
    }

    def action_open(self: RunScreen) {
        b = self.current();
        if b {
            app_of(self).push_screen(BuildScreen(self.run, b));
        }
    }

    def action_report(self: RunScreen) {
        app_of(self).push_screen(ReportScreen([self.run]));
    }

    def action_log(self: RunScreen) {
        text = str(app_of(self).api.call("runner_log", {"run": self.run}));
        app_of(self).push_screen(TextScreen("runner.log", text or "(no runner.log: this run was not launched from a UI)"));
    }

    def action_stop(self: RunScreen) {
        def done(v: str | None) {
            if v {
                r = app_of(self).api.call("stop_run", {"run": self.run}) as Json;
                self.notify(f"stopped runner {r.get('pid')}; relaunching resumes unfinished builds"
                            if r.get("stopped") else str(r.get("reason")));
            }
        }
        app_of(self).push_screen(Ask(f"Stop the runner of {self.run}? Running builds are killed.", confirm=True), done);
    }
}

class MonitorScreen(Screen) {
    """Everything running now, across all runs, refreshed every 2 s."""
    static has BINDINGS: list[Binding] = [
        Binding("escape,q", "app.pop_screen", "Back"), Binding("enter", "open", "Open build"),
        Binding("r", "open_run", "Open run"), Binding("p", "pause", "Pause feed")
    ];

    def init(self: MonitorScreen) {
        super.init();
        self.snap: Json = {};
        self.feed_cursor = 0;
        self.paused = False;
    }

    def compose(self: MonitorScreen) -> ComposeResult {
        yield Header();
        yield Static(id="mon-head");
        with Horizontal(id="mon-rate") {
            yield Label("tokens/min, last hour");
            yield Sparkline([0] * 60, id="spark", summary_function=max);
        }
        yield DataTable(id="running", cursor_type="row", zebra_stripes=True);
        with Horizontal(id="mon-bottom") {
            yield RichLog(id="feed", wrap=False, markup=False, max_lines=2000);
            yield DataTable(id="recent", cursor_type="row", zebra_stripes=True);
        }
        yield Footer();
    }

    def on_mount(self: MonitorScreen) {
        self.sub_title = "monitor: " + app_of(self).api.where();
        (self.query_one("#running", DataTable) as DataTable).add_columns(
            "build", "agent", "phase", "in phase", "tokens", "calls", "quiet", "doing now");
        (self.query_one("#recent", DataTable) as DataTable).add_columns("finished", "build", "status", "tokens", "min");
        (self.query_one("#feed", RichLog) as RichLog).write(
            Text("activity feed: every running build's actions as they happen", style="dim"));
        self.tick();
        self.set_interval(2, self.tick);
    }

    def tick(self: MonitorScreen) {
        s = app_of(self).api.call("monitor", {"since": self.feed_cursor}) as Json;
        self.snap = s;
        self.feed_cursor = int(s.get("cursor") or 0);
        c: Json = s.get("counts") or {};
        rate: list[int] = s.get("rate") or [];
        disk = float(s.get("disk_free_gb") or 0);
        head = Text.assemble(
            (f"{c.get('active_runs', 0)} active run(s)", "bold"), "  ·  ",
            (f"{c.get('running', 0)} running", "cyan bold"), "  ·  ", f"{c.get('queued', 0)} queued", "  ·  ",
            (f"{c.get('stopped', 0)} stopped", "bold red" if c.get("stopped") else "dim"), "  ·  ",
            f"{c.get('finished', 0)} finished (", (f"{c.get('works', 0)} work", "green"), ")  ·  ",
            f"{fmt_tokens(sum(rate[-10:]))} tokens in the last 10 min  ·  ",
            (f"{disk} GB free", "bold red" if disk < 5 else "")
        );
        runs: list[Json] = s.get("runs") or [];
        for r in runs {
            head.append("\n  ");
            head.append(str(r["run"]), style="bold");
            head.append(" runner alive" if r["alive"] else " runner dead", style="green" if r["alive"] else "red");
            head.append(f"   {r['finished']}/{r['planned'] or '?'} finished, {r['works']} work, "
                        + f"{r['running']} running, {r['queued']} queued");
        }
        if not runs {
            head.append("\n  nothing running", style="dim");
        }
        (self.query_one("#mon-head", Static) as Static).update(head);
        spark = self.query_one("#spark", Sparkline) as any;   # `data` is a reactive the checker cannot assign
        spark.data = [float(x) for x in rate];

        t = self.query_one("#running", DataTable) as DataTable;
        cur = t.cursor_row;
        t.clear();
        running: list[Json] = s.get("running") or [];
        for r in running {
            doing = Text(str(r["action"]).replace("\n", " ⏎ "));
            doing.truncate(120);
            t.add_row(
                str(r["build"]).replace("__", "/"), f"{r['agent']} {r['model']}".strip(),
                phase_text(str(r["phase"]), str(r["state"])), dur(float(r["phase_s"])), fmt_tokens(r["tokens"]),
                str(r["calls"]), quiet_text(float(r["quiet_s"])), doing, key=str(r["dir"])
            );
        }
        if running {
            t.move_cursor(row=min(max(cur, 0), len(running) - 1));
        }
        if not self.paused {
            feed = self.query_one("#feed", RichLog) as RichLog;
            for f in s.get("feed") or [] {
                who = str(f["build"]);
                feed.write(Text(f"{datetime.now():%H:%M:%S} ", style="dim") + Text(f"{who[-40:]:<40} ", style="bold")
                           + event_line(f["event"], 400)[11:]);
            }
        }
        rt = self.query_one("#recent", DataTable) as DataTable;
        rt.clear();
        for r in s.get("recent") or [] {
            rt.add_row(datetime.fromtimestamp(float(r["at"])).strftime("%H:%M"), str(r["build"]).replace("__", "/"),
                       styled(str(r["status"])), fmt_tokens(r["tokens"]), str(r["min"]), key=str(r["dir"]));
        }
    }

    def selected(self: MonitorScreen) -> tuple[str, str] | None {
        focused = self.focused;
        if isinstance(focused, DataTable) and (focused as DataTable).id == "recent" {
            ft = focused as DataTable;
            recent: list[Json] = self.snap.get("recent") or [];
            if 0 <= ft.cursor_row and ft.cursor_row < len(recent) {
                return (str(recent[ft.cursor_row]["run"]), str(recent[ft.cursor_row]["build"]));
            }
            return None;
        }
        t = self.query_one("#running", DataTable) as DataTable;
        running: list[Json] = self.snap.get("running") or [];
        if 0 <= t.cursor_row and t.cursor_row < len(running) {
            return (str(running[t.cursor_row]["run"]), str(running[t.cursor_row]["build"]));
        }
        return None;
    }

    def on_data_table_row_selected(self: MonitorScreen, ev: DataTable.RowSelected) {
        self.action_open();
    }

    def action_open(self: MonitorScreen) {
        sel = self.selected();
        if sel is not None {
            app_of(self).push_screen(BuildScreen(sel[0], sel[1]));
        }
    }

    def action_open_run(self: MonitorScreen) {
        sel = self.selected();
        if sel is not None {
            app_of(self).push_screen(RunScreen(sel[0]));
        }
    }

    def action_pause(self: MonitorScreen) {
        self.paused = not self.paused;
        self.notify("feed paused" if self.paused else "feed resumed");
    }
}

class HomeScreen(Screen) {
    static has BINDINGS: list[Binding] = [
        Binding("q", "app.quit", "Quit"), Binding("enter", "open", "Open"),
        Binding("n", "launch", "Launch experiment"), Binding("c", "compare", "Compare runs"),
        Binding("m", "monitor", "Monitor"), Binding("tab", "app.focus_next", "Switch pane", show=False)
    ];

    def init(self: HomeScreen) {
        super.init();
        self.run_rows: list[Json] = [];
        self.exps: list[Json] = [];
    }

    def compose(self: HomeScreen) -> ComposeResult {
        yield Header();
        with Horizontal() {
            with Vertical(id="left") {
                yield Label("[b]Runs[/b]  (enter: open, c: compare all)");
                yield DataTable(id="runs", cursor_type="row", zebra_stripes=True);
            }
            with Vertical(id="right") {
                yield Label("[b]Experiments[/b]  (n: launch)");
                yield DataTable(id="exps", cursor_type="row", zebra_stripes=True);
            }
        }
        yield Footer();
    }

    def on_mount(self: HomeScreen) {
        self.sub_title = app_of(self).api.where();
        (self.query_one("#runs", DataTable) as DataTable).add_columns("run", "finished", "works", "running", "runner", "started");
        e = self.query_one("#exps", DataTable) as DataTable;
        e.add_columns("experiment", "path");
        self.exps = app_of(self).api.call("list_experiments") as list[Json];
        for x in self.exps {
            e.add_row(str(x["name"]), str(x["dir"]), key=str(x["path"]));
        }
        self.refresh_runs();
        self.set_interval(3, self.refresh_runs);
    }

    def refresh_runs(self: HomeScreen) {
        t = self.query_one("#runs", DataTable) as DataTable;
        cur = t.cursor_row;
        self.run_rows = app_of(self).api.call("list_runs") as list[Json];
        t.clear();
        for r in self.run_rows {
            t.add_row(
                str(r["run"]), f"{r['finished']}/{r['planned']}", str(r["works"]), str(r["running"]),
                Text("alive", style="green") if r["alive"] else Text("-", style="dim"), str(r["started"]),
                key=str(r["run"])
            );
        }
        if self.run_rows {
            t.move_cursor(row=min(max(cur, 0), len(self.run_rows) - 1));
        }
    }

    def action_open(self: HomeScreen) {
        if self.focused is self.query_one("#exps", DataTable) {
            self.action_launch();
            return;
        }
        t = self.query_one("#runs", DataTable) as DataTable;
        if self.run_rows and 0 <= t.cursor_row and t.cursor_row < len(self.run_rows) {
            app_of(self).push_screen(RunScreen(str(self.run_rows[t.cursor_row]["run"])));
        }
    }

    def on_data_table_row_selected(self: HomeScreen, ev: DataTable.RowSelected) {
        self.action_open();
    }

    def action_monitor(self: HomeScreen) {
        app_of(self).push_screen(MonitorScreen());
    }

    def action_compare(self: HomeScreen) {
        if self.run_rows {
            app_of(self).push_screen(ReportScreen([str(r["run"]) for r in self.run_rows]));
        }
    }

    def action_launch(self: HomeScreen) {
        t = self.query_one("#exps", DataTable) as DataTable;
        if not self.exps or not (0 <= t.cursor_row and t.cursor_row < len(self.exps)) {
            self.notify("no experiment selected");
            return;
        }
        x = self.exps[t.cursor_row];

        def done(v: str | None) {
            if v is None {
                return;
            }
            (run_id, _, only) = v.partition(" ");
            try {
                r = app_of(self).api.call("launch", {"experiment": x["path"], "run_id": run_id.strip(), "only": only.split()}) as Json;
            } except Exception as err {
                self.notify(f"launch failed: {err}", severity="error");
                return;
            }
            self.notify(f"launched {r['run']}");
            self.refresh_runs();
            app_of(self).push_screen(RunScreen(str(r["run"])));
        }
        app_of(self).push_screen(Ask(f"Launch {x['name']}: run id [space-separated --only filters]", str(x["run_id"])), done);
    }
}

class AgentBench(App) {
    static has TITLE: str = "agent-bench",
        CSS: str = """
    #left, #right { width: 1fr; }
    #builds { height: 1fr; }
    #tail { height: 1fr; border-top: solid $primary; }
    #ask { width: 80; height: auto; padding: 1 2; border: thick $primary; background: $surface; }
    Ask { align: center middle; }
    #head { padding: 0 1; height: auto; }
    #mon-head { padding: 0 1; height: auto; }
    #mon-rate { height: 3; padding: 0 1; }
    #mon-rate Label { width: 24; padding-top: 1; }
    #spark { width: 1fr; height: 3; }
    #running { height: 1fr; min-height: 6; }
    #mon-bottom { height: 1fr; }
    #feed { width: 2fr; border-top: solid $primary; }
    #recent { width: 1fr; border-top: solid $primary; }
    """;

    def init(self: AgentBench, runs_dir: Path, exp_dirs: list[Path], run: str | None = None,
             monitor: list[Path] | None = None, server: str = "") {
        super.init();
        self.start_run = run;
        self.start_monitor = monitor is not None;
        self.api: Api = HttpApi(base=server) if server else LocalApi(
            runs_dirs=[Path(p) for p in monitor] if monitor else [Path(runs_dir)], exp_dirs=[Path(p) for p in exp_dirs]);
    }

    def on_mount(self: AgentBench) {
        self.push_screen(HomeScreen());
        if self.start_monitor {
            self.push_screen(MonitorScreen());
        } elif self.start_run {
            self.push_screen(RunScreen(self.start_run));
        }
    }
}

def main(runs_dir: str = "runs", experiments: list[str] = [], run: str | None = None,
         monitor: list[str] | None = None, server: str = "") -> int {
    AgentBench(
        Path(runs_dir).resolve(), [Path(e).resolve() for e in experiments] or [Path.cwd()], run,
        [Path(m).resolve() for m in monitor] if monitor else None, server
    ).run();
    return 0;
}
