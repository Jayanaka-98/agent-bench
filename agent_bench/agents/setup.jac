"""Agents on demand: pinned versions, user-space installs, and sign-in.

- **Pins.** Each agent has an install method and a pinned version (`PINS`).
  A machine overrides them in `~/.agent-bench/agents.toml`

      [codex]
      version = "0.167.0"        # "*" = any installed version; install the latest
      [claude-code]
      package = "@anthropic-ai/claude-code"

  or with `AGENT_BENCH_PIN_<AGENT>=<version>` (`AGENT_BENCH_PIN_CLAUDE_CODE`),
  which wins over the file.
- **ensure.** An agent is ready when the binary a build would run (the
  user-space installs first, then PATH: `common.with_tools`) reports the
  pinned version. Otherwise it is installed under `~/.agent-bench/tools`, no
  sudo: npm agents with `npm install -g --prefix tools/npm`, OpenHands with
  `uv tool install` into `tools/uv`. An npm agent needs Node (Claude Code
  2.1.318 declares node >= 22); without one on PATH, Node 22 LTS is
  downloaded from nodejs.org into `tools/node`, checked against the release's
  SHASUMS256.txt.
- **login.** The agent's own sign-in runs in a detached tmux session
  (`agent-bench-login-<agent>`), which holds its TTY and keeps it waiting for
  the human after the command returns. Its pane is read for the URL and the
  one-time code. Claude Code then wants the code the sign-in page shows typed
  into that TTY: `send_code` types it.
- **preflight.** Before a run's first build: every builder (and the driver,
  for the reviewed protocol) installed at its pin, and every one that pays
  with a login signed in, waiting for the human rather than failing builds.

A builder with `options.bin` set uses that binary as it is: it is neither
installed nor signed in here.
"""

import hashlib;
import io;
import json;
import os;
import platform;
import re;
import shlex;
import shutil;
import subprocess;
import tarfile;
import time;
import tomllib;
import urllib.request;
import from pathlib { Path }
import from agent_bench.common { Json, bench_home, tools_dir, with_tools }
import from agent_bench.agents.base { BuilderSpec }

"""How one agent is installed, and the version builds use."""
obj Pin {
    has agent: str,
        method: str,             # "npm" | "uv"
        package: str,
        version: str,            # "*" = whatever is installed (installs the latest)
        bin: str,
        node_min: int = 20,      # npm: the oldest Node the package runs on
        python: str = "",        # uv: the Python the tool runs on
        verified: str = "";      # how the pin was checked

    """What the installer is given: `pkg@1.2.3` (npm) or `pkg==1.2.3` (uv)."""
    def install_spec -> str {
        if self.version in ("", "*") {
            return self.package;
        }
        return f"{self.package}@{self.version}" if self.method == "npm" else f"{self.package}=={self.version}";
    }

    def matches(installed: str) -> bool {
        return bool(installed) and (self.version in ("", "*") or installed == self.version);
    }
}

# Pins, and how each was verified (2026-11-05):
# - codex 0.166.0: `npm view @openai/codex@0.166.0` (bin codex); run and signed
#   in on Ubuntu 22.04 with `codex login --device-auth`.
# - claude-code 2.1.318: `npm view @anthropic-ai/claude-code@2.1.318` (the
#   `latest` dist-tag; engines node >= 22, so node_min 22); `claude auth login
#   --claudeai` checked on Ubuntu 22.04.
# - opencode 1.19.5: the npm `latest` of `opencode-ai` (bin opencode), the
#   package OpenCode's docs install with `npm i -g opencode-ai`. Registry only:
#   not installed or run here. (The adapter's notes cite OpenCode 2.x source;
#   no 2.x is published on npm.)
# - openhands 1.16.0: PyPI `openhands` (the OpenHands CLI; requires Python
#   3.12), installed as its README says, `uv tool install openhands --python
#   3.12`. Registry only: not installed or run here.
glob PINS: dict[str, Pin] = {
    "codex": Pin(agent="codex", method="npm", package="@openai/codex", version="0.166.0", bin="codex",
                 verified="npm registry; installed and signed in on Ubuntu 22.04"),
    "claude-code": Pin(agent="claude-code", method="npm", package="@anthropic-ai/claude-code", version="2.1.318",
                       bin="claude", node_min=22,
                       verified="npm registry (latest); sign-in checked on Ubuntu 22.04"),
    "opencode": Pin(agent="opencode", method="npm", package="opencode-ai", version="1.19.5", bin="opencode",
                    verified="npm registry (latest) only; not run"),
    "openhands": Pin(agent="openhands", method="uv", package="openhands", version="1.16.0", bin="openhands",
                     python="3.12", verified="PyPI only; not run")
};

glob ALIASES: dict[str, str] = {"claude": "claude-code", "cc": "claude-code", "oh": "openhands"};

glob NODE_DIST: str = "https://nodejs.org/dist/latest-v22.x";
glob VERSION_RE: re.Pattern = re.compile(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?");
glob ANSI_RE: re.Pattern = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07|\r");
glob URL_RE: re.Pattern = re.compile(r"https://[^\s\"'<>]+");
glob CODE_RE: re.Pattern = re.compile(r"\b([A-Z0-9]{4,5}-[A-Z0-9]{4,6})\b");
glob EXIT_MARK: str = "[agent-bench: sign-in exited";

def canonical(agent: str) -> str {
    return ALIASES.get(agent, agent);
}

"""The pins in force: the defaults, then agents.toml, then AGENT_BENCH_PIN_*."""
def pins -> dict[str, Pin] {
    out: dict[str, Pin] = {};
    f = bench_home() / "agents.toml";
    conf: Json = tomllib.loads(f.read_text()) if f.is_file() else {};
    for (name, p) in PINS.items() {
        o: Json = conf.get(name) or {};
        env_v = os.environ.get("AGENT_BENCH_PIN_" + name.upper().replace("-", "_"));
        out[name] = Pin(
            agent=name, method=str(o.get("method", p.method)), package=str(o.get("package", p.package)),
            version=str(env_v if env_v is not None else o.get("version", p.version)), bin=str(o.get("bin", p.bin)),
            node_min=int(o.get("node_min", p.node_min)), python=str(o.get("python", p.python)),
            verified=p.verified if (env_v is None and "version" not in o) else "overridden on this machine"
        );
    }
    return out;
}

def pin_for(agent: str) -> Pin {
    a = canonical(agent);
    ps = pins();
    if a not in ps {
        raise KeyError(f"no pinned install for {agent!r}; known: {', '.join(ps)}");
    }
    return ps[a];
}

# ---- finding and versions ---------------------------------------------------------

"""The binary a build would run: an explicit path as it is, else the first on
the user-space installs, then PATH."""
def resolve(binary: str) -> str {
    if os.sep in binary {
        return binary if os.access(binary, os.X_OK) else "";
    }
    return shutil.which(binary, path=with_tools(dict(os.environ))["PATH"]) or "";
}

def version_of(path: str) -> str {
    if not path {
        return "";
    }
    try {
        out = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=60,
                             env=with_tools(dict(os.environ)), stdin=subprocess.DEVNULL);
    } except (OSError, subprocess.TimeoutExpired) {
        return "";
    }
    m = VERSION_RE.search((out.stdout or "") + "\n" + (out.stderr or ""));
    return m.group(0) if m else "";
}

"""An agent as installed here, against its pin."""
obj Check {
    has agent: str,
        pin: Pin,
        path: str,
        version: str,
        ok: bool;

    def why -> str {
        if self.ok {
            return "ok";
        }
        if not self.path {
            return "not installed";
        }
        return f"version {self.version or '?'} at {self.path}, pinned {self.pin.version}";
    }
}

def check(agent: str) -> Check {
    p = pin_for(agent);
    path = resolve(p.bin);
    v = version_of(path);
    return Check(agent=p.agent, pin=p, path=path, version=v, ok=p.matches(v));
}

# ---- installing ---------------------------------------------------------------------

"""Download a URL's bytes (tests replace this)."""
def fetch(url: str) -> bytes {
    req = urllib.request.Request(url, headers={"User-Agent": "agent-bench"});
    with urllib.request.urlopen(req, timeout=300) as r {
        return r.read();
    }
}

def _node_major(exe: str) -> int {
    try {
        out = subprocess.run([exe, "--version"], capture_output=True, text=True, timeout=30);
    } except (OSError, subprocess.TimeoutExpired) {
        return 0;
    }
    m = re.match(r"v?(\d+)\.", (out.stdout or "").strip());
    return int(m.group(1)) if m else 0;
}

"""The bin directory of a Node at least `min_major` (the user-space one
first, then PATH), or None."""
def find_node(min_major: int) -> Path | None {
    path = with_tools(dict(os.environ))["PATH"];
    for d in path.split(os.pathsep) {
        n = Path(d) / "node";
        if d and os.access(n, os.X_OK) and _node_major(str(n)) >= min_major {
            return Path(d);
        }
    }
    return None;
}

"""nodejs.org's name for this machine: darwin-arm64, linux-x64, ..."""
def node_platform -> str {
    sysname = platform.system().lower();
    if sysname not in ("darwin", "linux") {
        raise RuntimeError(f"no Node download for {platform.system()}: install Node >= 22 yourself");
    }
    arch = {"x86_64": "x64", "amd64": "x64", "arm64": "arm64", "aarch64": "arm64"}.get(platform.machine().lower());
    if arch is None {
        raise RuntimeError(f"no Node download for {platform.machine()}: install Node >= 22 yourself");
    }
    return f"{sysname}-{arch}";
}

"""Download Node 22 LTS into tools/node, checked against SHASUMS256.txt.
Returns its bin directory."""
def download_node(log: Callable[[str], None] = print) -> Path {
    plat = node_platform();
    sums = fetch(NODE_DIST + "/SHASUMS256.txt").decode();
    want = re.compile(r"^([0-9a-f]{64})\s+(node-v22\.\d+\.\d+-" + re.escape(plat) + r"\.tar\.gz)$", re.M);
    m = want.search(sums);
    if not m {
        raise RuntimeError(f"{NODE_DIST}/SHASUMS256.txt lists no Node 22 build for {plat}");
    }
    (sha, name) = (str(m.group(1)), str(m.group(2)));
    log(f"downloading {NODE_DIST}/{name}");
    data = fetch(f"{NODE_DIST}/{name}");
    got = hashlib.sha256(data).hexdigest();
    if got != sha {
        raise RuntimeError(f"{name}: checksum mismatch (got {got}, SHASUMS256.txt says {sha}); not installed");
    }
    tools = tools_dir();
    tools.mkdir(parents=True, exist_ok=True);
    tmp = tools / ".node-download";
    shutil.rmtree(tmp, ignore_errors=True);
    tmp.mkdir();
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as tf {
        tf.extractall(tmp, filter="data");
    }
    top = tmp / name.removesuffix(".tar.gz");
    if not (top / "bin" / "node").exists() {
        shutil.rmtree(tmp, ignore_errors=True);
        raise RuntimeError(f"{name}: no bin/node inside");
    }
    dst = tools / "node";
    shutil.rmtree(dst, ignore_errors=True);
    top.rename(dst);
    shutil.rmtree(tmp, ignore_errors=True);
    log(f"Node {name.split('-')[1]} in {dst} (sha256 ok)");
    return dst / "bin";
}

def ensure_node(min_major: int, log: Callable[[str], None] = print) -> Path {
    found = find_node(min_major);
    if found is not None {
        return found;
    }
    log(f"no Node >= {min_major} on PATH; installing Node 22 LTS");
    return download_node(log);
}

def _run_install(argv: list[str], env: dict[str, str], log: Callable[[str], None]) {
    log("$ " + shlex.join(argv));
    out = subprocess.run(argv, env=env, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=1800);
    if out.returncode != 0 {
        tail = "\n".join(((out.stdout or "") + (out.stderr or "")).strip().splitlines()[-15:]);
        raise RuntimeError(f"`{shlex.join(argv)}` failed ({out.returncode}):\n{tail}");
    }
}

def install(p: Pin, log: Callable[[str], None] = print) {
    tools = tools_dir();
    env = with_tools(dict(os.environ));
    if p.method == "npm" {
        node_bin = ensure_node(p.node_min, log);
        npm = node_bin / "npm";
        if not os.access(npm, os.X_OK) {
            npm = Path(shutil.which("npm", path=env["PATH"]) or "npm");
        }
        env["PATH"] = str(node_bin) + os.pathsep + env["PATH"];
        (tools / "npm").mkdir(parents=True, exist_ok=True);
        _run_install([str(npm), "install", "-g", "--prefix", str(tools / "npm"), "--no-fund", "--no-audit",
                      p.install_spec()], env, log);
    } elif p.method == "uv" {
        uv = shutil.which("uv", path=env["PATH"]);
        if not uv {
            raise RuntimeError(f"{p.agent} installs with uv, which is not on PATH: "
                               + "install it (https://docs.astral.sh/uv/: curl -LsSf https://astral.sh/uv/install.sh | sh)");
        }
        env["UV_TOOL_DIR"] = str(tools / "uv" / "tools");
        env["UV_TOOL_BIN_DIR"] = str(tools / "uv" / "bin");
        env["UV_PYTHON_INSTALL_DIR"] = str(tools / "uv" / "python");
        argv: list[str] = [uv, "tool", "install", "--force"];
        if p.python {
            argv += ["--python", p.python];
        }
        _run_install(argv + [p.install_spec()], env, log);
    } else {
        raise ValueError(f"{p.agent}: unknown install method {p.method!r}");
    }
}

"""Install `agent` at its pin unless the binary a build would run already is
that version. Idempotent."""
def ensure(agent: str, log: Callable[[str], None] = print) -> Check {
    c = check(agent);
    if c.ok {
        log(f"{c.agent}: {c.version} at {c.path}: ok");
        return c;
    }
    log(f"{c.agent}: {c.why()}; installing {c.pin.install_spec()} into {tools_dir()}");
    install(c.pin, log);
    c = check(agent);
    if not c.ok {
        raise RuntimeError(f"{c.agent}: installed {c.pin.install_spec()}, but the binary found is {c.why()}");
    }
    log(f"{c.agent}: {c.version} at {c.path}: installed");
    return c;
}

# ---- sign-in ------------------------------------------------------------------------

"""An agent's own sign-in: the command that waits for the human, and the one
that says whether it is done."""
obj LoginFlow {
    has argv: list[str],
        status: list[str],
        title: str;
}

glob LOGINS: dict[str, LoginFlow] = {
    "codex": LoginFlow(argv=["login", "--device-auth"], status=["login", "status"], title="Codex (ChatGPT)"),
    "claude-code": LoginFlow(argv=["auth", "login", "--claudeai"], status=["auth", "status"],
                             title="Claude Code (Claude subscription)")
};

def has_login(agent: str) -> bool {
    return canonical(agent) in LOGINS;
}

def session_name(agent: str) -> str {
    return f"agent-bench-login-{canonical(agent)}";
}

"""Where codex keeps the login a builder copies: the directory of its
`auth_file` option (default ~/.codex)."""
def codex_home(spec: BuilderSpec | None) -> str {
    f = str((spec.options if spec is not None else {}).get("auth_file", "~/.codex/auth.json"));
    return str(Path(os.path.expanduser(f)).parent);
}

"""The environment for an agent's sign-in and status: the user-space
installs on PATH; codex pointed at the login builds copy; Claude Code without
an API key, so its status is about the login."""
def login_env(agent: str, spec: BuilderSpec | None = None) -> dict[str, str] {
    env = with_tools(dict(os.environ));
    a = canonical(agent);
    if a == "codex" {
        env["CODEX_HOME"] = codex_home(spec);
    } elif a == "claude-code" {
        env.pop("ANTHROPIC_API_KEY", None);
        for k in ("CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT", "CLAUDE_CODE_SSE_PORT") {
            env.pop(k, None);
        }
    }
    return env;
}

"""Whether the status output says signed in (with the login builds use: for
codex a ChatGPT login, not an API key)."""
def parse_status(agent: str, out: str, rc: int) -> bool {
    a = canonical(agent);
    if a == "codex" {
        return rc == 0 and re.search(r"^Logged in using ChatGPT", out, re.M) is not None;
    }
    if a == "claude-code" {
        i = out.find("{");
        if i < 0 {
            return False;
        }
        try {
            d = json.loads(out[i:out.rfind("}") + 1]);
        } except ValueError {
            return False;
        }
        return isinstance(d, dict) and (d as Json).get("loggedIn") is True;
    }
    return False;
}

"""True or False, or None when it cannot be told (not installed, no login)."""
def logged_in(agent: str, spec: BuilderSpec | None = None) -> bool | None {
    a = canonical(agent);
    if a not in LOGINS {
        return None;
    }
    path = resolve(pin_for(a).bin);
    if not path {
        return None;
    }
    if a == "codex" and not (Path(codex_home(spec)) / "auth.json").is_file() {
        return False;
    }
    try {
        out = subprocess.run([path, *LOGINS[a].status], capture_output=True, text=True, timeout=60,
                             env=login_env(a, spec), stdin=subprocess.DEVNULL);
    } except (OSError, subprocess.TimeoutExpired) {
        return None;
    }
    return parse_status(a, (out.stdout or "") + "\n" + (out.stderr or ""), out.returncode);
}

"""The sign-in URL and one-time code in a sign-in's terminal output."""
def extract(agent: str, text: str) -> tuple[str, str] {
    t = ANSI_RE.sub("", text);
    a = canonical(agent);
    url = "";
    code = "";
    if a == "claude-code" {
        m = re.search(r"visit:\s*(https://\S+)", t);
        if m {
            url = str(m.group(1));
        }
    }
    urls = [str(u).rstrip(".,)") for u in URL_RE.findall(t)];
    if not url and urls {
        prefer = [u for u in urls if "auth.openai.com" in u or "claude." in u or "anthropic.com" in u];
        url = prefer[0] if prefer else urls[0];
    }
    if a == "codex" {
        after = t[t.find(url) + len(url):] if url and url in t else t;
        c = CODE_RE.search(after) or CODE_RE.search(t);
        code = str(c.group(1)) if c else "";
    }
    return (url, code);
}

"""Holds a sign-in process on a TTY that outlives this command: a detached
tmux session. Tests use a stand-in with the same methods."""
obj Tmux {
    def available -> bool {
        return shutil.which("tmux") is not None;
    }

    def exists(name: str) -> bool {
        return subprocess.run(["tmux", "has-session", "-t", f"={name}"], capture_output=True).returncode == 0;
    }

    """Run argv in a new detached session, in exactly `env`. The pane stays up
    for 15 minutes after the process ends, so its last words can still be read."""
    def start(name: str, argv: list[str], env: dict[str, str], cwd: str) {
        # A running tmux server gives new sessions its own (possibly older)
        # environment, so the session sources ours from a private file; the
        # values stay out of every process's command line.
        d = bench_home() / "login";
        d.mkdir(parents=True, exist_ok=True);
        envf = d / f"{name}.env";
        envf.touch(mode=0o600);
        os.chmod(envf, 0o600);
        lines: list[str] = [];
        for (k, v) in env.items() {
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k) {
                lines.append(f"export {k}={shlex.quote(v)}");
            }
        }
        envf.write_text("\n".join(lines) + "\n");
        # What env leaves out (e.g. Claude Code's API key) is unset in the session too.
        gone = [k for k in os.environ if k not in env] + [k for k in ("ANTHROPIC_API_KEY",) if k not in env];
        drop = " ".join(sorted(set([k for k in gone if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", k)])));
        script = f". {shlex.quote(str(envf))}; rm -f {shlex.quote(str(envf))}; "
            + (f"unset {drop}; " if drop else "") + shlex.join(argv)
            + "; rc=$?; echo; echo \"" + EXIT_MARK + " ($rc)]\"; sleep 900";
        subprocess.run(["tmux", "new-session", "-d", "-s", name, "-x", "500", "-y", "50", "-c", cwd,
                        "sh", "-c", script], check=True, capture_output=True);
    }

    def capture(name: str) -> str {
        out = subprocess.run(["tmux", "capture-pane", "-p", "-J", "-S", "-500", "-t", f"={name}:"],
                             capture_output=True, text=True);
        return out.stdout or "";
    }

    def send(name: str, text: str) {
        subprocess.run(["tmux", "send-keys", "-t", f"={name}:", "-l", text], check=True, capture_output=True);
        subprocess.run(["tmux", "send-keys", "-t", f"={name}:", "Enter"], check=True, capture_output=True);
    }

    def kill(name: str) {
        subprocess.run(["tmux", "kill-session", "-t", f"={name}"], capture_output=True);
    }
}

"""The session holder in use (tests replace this)."""
def sessions -> any {
    return Tmux();
}

obj LoginStart {
    has agent: str,
        logged_in: bool = False,
        url: str = "",
        code: str = "",
        session: str = "",
        reused: bool = False;

    """What the human needs, and nothing else."""
    def lines -> list[str] {
        if self.logged_in {
            return [f"{self.agent}: already signed in"];
        }
        title = LOGINS[self.agent].title;
        if self.agent == "codex" {
            return [f"Sign in to {title}:", f"  1. open   {self.url}",
                    f"  2. enter  {self.code}   (expires in 15 minutes)",
                    f"  (waiting in tmux session {self.session})"];
        }
        return [f"Sign in to {title}:", f"  1. open   {self.url}",
                "  2. sign in, copy the code the page shows, then run:",
                f"       agent-bench agents login {self.agent} --code <CODE>",
                f"  (waiting in tmux session {self.session})"];
    }
}

"""Start `agent`'s sign-in, detached, and read its URL and code. A sign-in
already waiting is reused (its code still holds) unless it has ended."""
def start_login(agent: str, spec: BuilderSpec | None = None, timeout: float = 45.0,
                poll: float = 0.5) -> LoginStart {
    a = canonical(agent);
    if a not in LOGINS {
        raise KeyError(f"{agent} has no sign-in here: it uses an API key through its endpoint");
    }
    if logged_in(a, spec) is True {
        return LoginStart(agent=a, logged_in=True);
    }
    path = resolve(pin_for(a).bin);
    if not path {
        raise RuntimeError(f"{a} is not installed: run `agent-bench agents ensure {a}`");
    }
    runner = sessions();
    lf = LOGINS[a];
    if not runner.available() {
        raise RuntimeError("the sign-in runs in a detached tmux session, and tmux is not on PATH: install it "
                           + "(apt install tmux / brew install tmux), or run `"
                           + shlex.join([path, *lf.argv]) + "` yourself");
    }
    name = session_name(a);
    reused = False;
    if runner.exists(name) {
        if EXIT_MARK in runner.capture(name) {
            runner.kill(name);
        } else {
            reused = True;
        }
    }
    if not reused {
        runner.start(name, [path, *lf.argv], login_env(a, spec), str(Path.home()));
    }
    deadline = time.time() + timeout;
    text = "";
    while True {
        text = runner.capture(name);
        (url, code) = extract(a, text);
        if url and (code or a != "codex") {
            return LoginStart(agent=a, url=url, code=code, session=name, reused=reused);
        }
        if EXIT_MARK in text or time.time() > deadline {
            break;
        }
        time.sleep(poll);
    }
    tail = "\n".join(ANSI_RE.sub("", text).strip().splitlines()[-12:]);
    raise RuntimeError(f"{a}: the sign-in gave no URL{' and code' if a == 'codex' else ''}; it printed:\n{tail}");
}

"""Type the code from the sign-in page into the waiting sign-in."""
def send_code(agent: str, code: str) {
    a = canonical(agent);
    runner = sessions();
    name = session_name(a);
    if not runner.available() or not runner.exists(name) {
        raise RuntimeError(f"no {a} sign-in is waiting: run `agent-bench agents login {a}` first");
    }
    runner.send(name, code.strip());
}

"""Poll until signed in (True) or `timeout` seconds pass (False). A finished
sign-in's session is closed."""
def wait_login(agent: str, spec: BuilderSpec | None = None, timeout: float = 1800.0, poll: float = 5.0) -> bool {
    a = canonical(agent);
    deadline = time.time() + timeout;
    while True {
        if logged_in(a, spec) is True {
            runner = sessions();
            if runner.available() and runner.exists(session_name(a)) {
                runner.kill(session_name(a));
            }
            return True;
        }
        if time.time() > deadline {
            return False;
        }
        time.sleep(poll);
    }
}

# ---- preflight ----------------------------------------------------------------------

"""Whether this builder pays with the agent's login (so it must be signed in):
codex with `auth = "chatgpt"`; Claude Code on a subscription (`auth =
"subscription"`, or `inherit` with no ANTHROPIC_API_KEY in the build's
environment)."""
def needs_login(spec: BuilderSpec, env: dict[str, str]) -> bool {
    a = canonical(spec.agent);
    auth = str(spec.options.get("auth", ""));
    if a == "codex" {
        return auth == "chatgpt";
    }
    if a == "claude-code" {
        if auth in ("", "inherit") {
            return not env.get("ANTHROPIC_API_KEY");
        }
        return auth == "subscription";
    }
    return False;
}

"""Whether agent-bench installs and signs in this builder's agent: a pinned
agent with no `bin` of its own."""
def managed(spec: BuilderSpec) -> bool {
    return canonical(spec.agent) in PINS and not spec.options.get("bin");
}

"""Make every builder ready before the first build. Installs what is missing
or off its pin; signs in what needs a login, printing the URL and code and
waiting for the human up to `login_timeout`. With `dry_run`, changes nothing
and waits for nothing. Returns the problems found (dry run) or left (none,
else it raises)."""
def preflight(specs: list[BuilderSpec], env: dict[str, str], dry_run: bool = False,
              log: Callable[[str], None] = print, login_timeout: float = 1800.0,
              poll: float = 5.0) -> list[str] {
    problems: list[str] = [];
    done: list[str] = [];
    for s in specs {
        if not managed(s) {
            if s.options.get("bin") and canonical(s.agent) in PINS {
                log(f"preflight: {s.name}: bin {s.options['bin']} is used as it is (not installed or signed in here)");
            }
            continue;
        }
        a = canonical(s.agent);
        if a in done {
            continue;
        }
        done.append(a);
        c = check(a);
        if c.ok {
            log(f"preflight: {a} {c.version}: ok");
        } elif dry_run {
            problems.append(f"{a}: {c.why()}; would install {c.pin.install_spec()} into {tools_dir()}");
        } else {
            ensure(a, log);
        }
    }
    signed: list[str] = [];
    for s in specs {
        if not managed(s) or not needs_login(s, env) {
            continue;
        }
        a = canonical(s.agent);
        key = a + ":" + (codex_home(s) if a == "codex" else "");
        if key in signed {
            continue;
        }
        signed.append(key);
        state = logged_in(a, s);
        if state is True {
            log(f"preflight: {a}: signed in");
            continue;
        }
        if dry_run {
            problems.append(f"{a}: " + ("not signed in" if state is False else "sign-in unknown (not installed)")
                            + f"; `agent-bench agents login {a}` (needed by builder {s.name})");
            continue;
        }
        st = start_login(a, s);
        if not st.logged_in {
            bar = "=" * 72;
            log("\n".join([bar, f"preflight: builder {s.name} needs {a} signed in.", *st.lines(),
                           f"Waiting up to {int(login_timeout // 60)} min for the sign-in.", bar]));
            if not wait_login(a, s, login_timeout, poll) {
                raise RuntimeError(f"preflight: {a} still not signed in after {int(login_timeout)} s; "
                                   + f"sign in with `agent-bench agents login {a}` and run again");
            }
        }
        log(f"preflight: {a}: signed in");
    }
    return problems;
}
