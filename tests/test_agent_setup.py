"""Agents on demand, with fakes only: nothing is installed or signed in for real.

npm, node, uv, codex and claude are shell scripts on a PATH that holds nothing
else; the Node download is a monkeypatched `fetch`; the tmux session holder is
a stand-in that runs the sign-in as a plain subprocess."""

import hashlib
import io
import json
import os
import shutil
import subprocess
import tarfile
import threading
import time
from pathlib import Path

import pytest

from agent_bench.agents import setup as S
from agent_bench.agents.base import BuilderSpec
from agent_bench.cli import main as cli_main
from agent_bench.config import Experiment
from agent_bench.runner import run, to_prepare, builds, Proxy

ROOT = Path(__file__).resolve().parent.parent

# What the real sign-ins print (Ubuntu 22.04, 2026-11-04), as tmux shows them.
CODEX_LOGIN_OUT = """\x1b[1mWelcome to Codex\x1b[0m [v0.166.0]
\x1b[2mOpenAI's command-line coding agent\x1b[0m

Follow these steps to sign in with ChatGPT using device code authorization:

1. Open this link in your browser and sign in to your account
   \x1b[94mhttps://auth.openai.com/codex/device\x1b[0m

2. Enter this one-time code \x1b[2m(expires in 15 minutes)\x1b[0m
   \x1b[94m0NP7-GCWKQ\x1b[0m

\x1b[2mDevice codes are a common phishing target. Never share this code.\x1b[0m
"""
CLAUDE_URL = ("https://claude.ai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
              "&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback"
              "&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference+user%3Asessions%3Aclaude_code"
              "&code_challenge=Qx3bJ0x_bJmYk1kGQd3q9VQ6aH9Y2Kf8yH7m1nqzv1M&code_challenge_method=S256"
              "&state=4e1fJ6m0VvV3Q2b8iQyq1oH0zW4k7yX9cT5rS2aP0uA")
CLAUDE_LOGIN_OUT = f"""Opening browser to sign in…
If the browser didn't open, visit: {CLAUDE_URL}
Paste code here if prompted > """


def script(path: Path, body: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)
    return path


FAKE_NPM = r'''echo "npm $*" >> "$FAKE_LOG"
prefix=""; spec=""
while [ $# -gt 0 ]; do
  case "$1" in
    --prefix) prefix="$2"; shift 2;;
    install|-*) shift;;
    *) spec="$1"; shift;;
  esac
done
case "$spec" in
  @openai/codex@*) bin=codex;;
  @anthropic-ai/claude-code@*) bin=claude;;
  opencode-ai@*) bin=opencode;;
  *) echo "no such package $spec" >&2; exit 1;;
esac
/bin/mkdir -p "$prefix/bin"
printf '#!/bin/sh\necho "%s-cli %s"\n' "$bin" "${spec##*@}" > "$prefix/bin/$bin"
/bin/chmod +x "$prefix/bin/$bin"
'''

FAKE_UV = r'''echo "uv $*" >> "$FAKE_LOG"
for a in "$@"; do spec="$a"; done
/bin/mkdir -p "$UV_TOOL_BIN_DIR"
printf '#!/bin/sh\necho "OpenHands CLI %s"\n' "${spec##*==}" > "$UV_TOOL_BIN_DIR/openhands"
/bin/chmod +x "$UV_TOOL_BIN_DIR/openhands"
'''

FAKE_CODEX = r'''case "$1 $2" in
  "--version "*) echo "codex-cli 0.166.0";;
  "login --device-auth")
    printf '%s' "$FAKE_CODEX_OUT"
    while [ ! -f "$FAKE_STATE/approved" ]; do /bin/sleep 0.1; done
    /bin/mkdir -p "$CODEX_HOME"
    echo '{"auth_mode": "chatgpt"}' > "$CODEX_HOME/auth.json"
    echo "Successfully logged in";;
  "login status")
    if [ -f "$CODEX_HOME/auth.json" ]; then echo "Logged in using ChatGPT"; else echo "Not logged in"; exit 1; fi;;
  *) exit 2;;
esac
'''

FAKE_CLAUDE = r'''case "$1 $2" in
  "--version "*) echo "2.1.318 (Claude Code)";;
  "auth login")
    printf '%s' "$FAKE_CLAUDE_OUT"
    read code
    if [ "$code" = "good-code#state" ]; then : > "$FAKE_STATE/claude-ok"; echo "Login successful."; exit 0; fi
    echo "OAuth error: invalid code"; exit 1;;
  "auth status")
    if [ -f "$FAKE_STATE/claude-ok" ]; then echo '{"loggedIn": true, "authMethod": "claude.ai"}'
    else echo '{"loggedIn": false, "authMethod": "none"}'; exit 1; fi;;
  *) exit 2;;
esac
'''


class FakeSessions:
    """The tmux stand-in: the sign-in as a subprocess, its output as the pane."""

    def __init__(self, tmp: Path):
        self.tmp = tmp
        self.procs = {}
        self.started = []
        self.sent = []
        self.tmux = True

    def available(self):
        return self.tmux

    def exists(self, name):
        return name in self.procs

    def start(self, name, argv, env, cwd):
        self.started.append((name, list(argv)))
        log = (self.tmp / f"{name}.pane").open("w")
        self.procs[name] = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT,
                                            env=env, cwd=cwd, text=True)

    def capture(self, name):
        text = (self.tmp / f"{name}.pane").read_text()
        p = self.procs[name]
        if p.poll() is not None:
            text += f"\n{S.EXIT_MARK} ({p.returncode})]\n"
        return text

    def send(self, name, text):
        self.sent.append((name, text))
        p = self.procs[name]
        p.stdin.write(text + "\n")
        p.stdin.flush()

    def kill(self, name):
        p = self.procs.pop(name)
        if p.poll() is None:
            p.kill()
        p.wait()

    def close(self):
        for name in list(self.procs):
            self.kill(name)


@pytest.fixture()
def env(tmp_path, monkeypatch):
    """An empty machine: only fakebin on PATH, a throwaway HOME and AGENT_BENCH_HOME."""
    fakebin = tmp_path / "fakebin"
    fakebin.mkdir()
    state = tmp_path / "state"
    state.mkdir()
    (tmp_path / "user").mkdir()
    monkeypatch.setenv("ORIG_PATH", os.environ.get("PATH", ""))
    monkeypatch.setenv("PATH", str(fakebin))
    monkeypatch.setenv("HOME", str(tmp_path / "user"))
    monkeypatch.setenv("AGENT_BENCH_HOME", str(tmp_path / "ab"))
    monkeypatch.setenv("FAKE_LOG", str(tmp_path / "calls.log"))
    monkeypatch.setenv("FAKE_STATE", str(state))
    monkeypatch.setenv("FAKE_CODEX_OUT", CODEX_LOGIN_OUT)
    monkeypatch.setenv("FAKE_CLAUDE_OUT", CLAUDE_LOGIN_OUT)
    monkeypatch.delenv("ANTHROPIC_API_KEY", raising=False)
    for k in list(os.environ):
        if k.startswith("AGENT_BENCH_PIN_"):
            monkeypatch.delenv(k)
    sessions = FakeSessions(tmp_path)
    monkeypatch.setattr(S, "sessions", lambda: sessions)

    def no_network(url):
        raise AssertionError(f"unexpected download {url}")
    monkeypatch.setattr(S, "fetch", no_network)
    yield {"bin": fakebin, "state": state, "tmp": tmp_path, "sessions": sessions, "tools": tmp_path / "ab" / "tools"}
    sessions.close()


def calls(env) -> list[str]:
    f = env["tmp"] / "calls.log"
    return f.read_text().splitlines() if f.exists() else []


def node(env, version="v22.11.0"):
    script(env["bin"] / "node", f'echo "{version}"\n')
    script(env["bin"] / "npm", FAKE_NPM)


# ---- pins and ensure ----------------------------------------------------------------

def test_pins_and_overrides(env, monkeypatch):
    p = S.pins()
    assert p["codex"].install_spec() == "@openai/codex@0.166.0"
    assert p["claude-code"].install_spec() == "@anthropic-ai/claude-code@2.1.318"
    assert p["openhands"].install_spec() == "openhands==1.16.0"
    assert S.pin_for("claude").agent == "claude-code"
    conf = env["tmp"] / "ab" / "agents.toml"
    conf.parent.mkdir(parents=True)
    conf.write_text('[codex]\nversion = "0.170.0"\n[opencode]\nversion = "*"\n')
    monkeypatch.setenv("AGENT_BENCH_PIN_CODEX", "0.171.0")
    p = S.pins()
    assert p["codex"].version == "0.171.0"           # the environment wins over the file
    assert p["opencode"].install_spec() == "opencode-ai"
    assert p["opencode"].matches("9.9.9")


def test_ensure_installs_once(env):
    node(env)
    c = S.ensure("codex", log=lambda m: None)
    assert c.ok and c.version == "0.166.0"
    assert c.path == str(env["tools"] / "npm" / "bin" / "codex")
    npm = [l for l in calls(env) if l.startswith("npm ")]
    assert npm == [f"npm install -g --prefix {env['tools'] / 'npm'} --no-fund --no-audit @openai/codex@0.166.0"]
    S.ensure("codex", log=lambda m: None)                  # idempotent: nothing to do
    assert len(calls(env)) == 1


def test_version_mismatch_reinstalls(env):
    node(env, "v24.1.0")
    script(env["bin"] / "claude", 'echo "2.1.293 (Claude Code)"\n')   # an older claude on PATH
    c = S.check("claude-code")
    assert not c.ok and c.version == "2.1.293" and "pinned 2.1.318" in c.why()
    c = S.ensure("claude", log=lambda m: None)
    assert c.ok and c.path == str(env["tools"] / "npm" / "bin" / "claude")   # the install wins over PATH
    # the install itself off its pin: installed again
    script(env["tools"] / "npm" / "bin" / "claude", 'echo "2.1.300 (Claude Code)"\n')
    S.ensure("claude-code", log=lambda m: None)
    assert len([l for l in calls(env) if "@anthropic-ai/claude-code@2.1.318" in l]) == 2
    assert S.check("claude-code").ok


def test_already_on_path_is_left_alone(env):
    script(env["bin"] / "codex", 'echo "codex-cli 0.166.0"\n')
    c = S.ensure("codex", log=lambda m: None)
    assert c.ok and c.path == str(env["bin"] / "codex")
    assert calls(env) == []                               # no npm, no node needed


def _node_tarball(version: str) -> tuple[str, bytes]:
    top = f"node-{version}-{S.node_platform()}"
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as tf:
        for name, body in (("node", f'#!/bin/sh\necho "{version}"\n'), ("npm", "#!/bin/sh\n" + FAKE_NPM)):
            data = body.encode()
            ti = tarfile.TarInfo(f"{top}/bin/{name}")
            ti.size = len(data)
            ti.mode = 0o755
            tf.addfile(ti, io.BytesIO(data))
    return top + ".tar.gz", buf.getvalue()


def _serve_node(monkeypatch, name, data, sha=None):
    sums = f"{'0' * 64}  node-v22.23.4-aix-ppc64.tar.gz\n{sha or hashlib.sha256(data).hexdigest()}  {name}\n"
    fetched = []

    def fetch(url):
        fetched.append(url)
        if url == f"{S.NODE_DIST}/SHASUMS256.txt":
            return sums.encode()
        if url == f"{S.NODE_DIST}/{name}":
            return data
        raise AssertionError(url)
    monkeypatch.setattr(S, "fetch", fetch)
    return fetched


def test_no_node_downloads_node(env, monkeypatch):
    script(env["bin"] / "node", 'echo "v18.19.0"\n')         # too old for Claude Code (>= 22)
    name, data = _node_tarball("v22.23.4")
    fetched = _serve_node(monkeypatch, name, data)
    msgs = []
    c = S.ensure("claude-code", log=msgs.append)
    assert c.ok
    assert fetched == [f"{S.NODE_DIST}/SHASUMS256.txt", f"{S.NODE_DIST}/{name}"]
    assert (env["tools"] / "node" / "bin" / "node").exists()
    assert any("sha256 ok" in m for m in msgs)
    # the downloaded Node's npm did the install, and is reused next time
    assert calls(env)[0].startswith("npm install -g --prefix")
    S.ensure("codex", log=lambda m: None)
    assert len(fetched) == 2
    # builds find node (for npm launchers) and the agents through the tool PATH
    path = S.with_tools({"PATH": str(env["bin"])})["PATH"].split(":")
    assert path[:3] == [str(env["tools"] / d / "bin") for d in ("npm", "uv", "node")]


def test_node_checksum_mismatch_installs_nothing(env, monkeypatch):
    name, data = _node_tarball("v22.23.4")
    _serve_node(monkeypatch, name, data, sha="ab" * 32)
    with pytest.raises(RuntimeError, match="checksum mismatch"):
        S.ensure("codex", log=lambda m: None)
    assert not (env["tools"] / "node").exists()
    assert not (env["tools"] / "npm" / "bin" / "codex").exists()
    assert calls(env) == []


def test_openhands_installs_with_uv(env):
    script(env["bin"] / "uv", FAKE_UV)
    c = S.ensure("openhands", log=lambda m: None)
    assert c.ok and c.path == str(env["tools"] / "uv" / "bin" / "openhands")
    assert calls(env) == ["uv tool install --force --python 3.12 openhands==1.16.0"]


def test_ensure_cli(env, capsys):
    node(env)
    assert cli_main(["agents", "ensure", "codex", "opencode"]) == 0
    capsys.readouterr()
    assert cli_main(["agents", "status", "--json"]) == 0
    rows = {r["agent"]: r for r in json.loads(capsys.readouterr().out)}
    assert rows["codex"]["ok"] == "yes" and rows["opencode"]["installed"] == "1.19.5"
    assert rows["claude-code"]["installed"] == "not installed" and rows["openhands"]["signed_in"] == "-"
    assert cli_main(["agents", "ensure"]) == 2


# ---- sign-in ------------------------------------------------------------------------

def test_extract_codex():
    assert S.extract("codex", CODEX_LOGIN_OUT) == ("https://auth.openai.com/codex/device", "0NP7-GCWKQ")


def test_extract_claude():
    url, code = S.extract("claude", CLAUDE_LOGIN_OUT)
    assert url == CLAUDE_URL and code == ""


def test_status_parsing():
    assert S.parse_status("codex", "Logged in using ChatGPT\n", 0)
    assert not S.parse_status("codex", "Logged in using an API key - sk-***\n", 0)
    assert not S.parse_status("codex", "Not logged in\n", 1)
    assert S.parse_status("claude", '{\n  "loggedIn": true,\n  "authMethod": "claude.ai"\n}\n', 0)
    assert not S.parse_status("claude", '{"loggedIn": false}', 1)


def test_codex_login(env):
    script(env["bin"] / "codex", FAKE_CODEX)
    assert S.logged_in("codex") is False
    st = S.start_login("codex", timeout=10, poll=0.1)
    assert (st.url, st.code) == ("https://auth.openai.com/codex/device", "0NP7-GCWKQ")
    assert "  2. enter  0NP7-GCWKQ   (expires in 15 minutes)" in st.lines()
    # asking again while it waits reuses the same sign-in (same code)
    again = S.start_login("codex", timeout=10, poll=0.1)
    assert again.reused and again.code == st.code and len(env["sessions"].started) == 1
    assert not S.wait_login("codex", timeout=0.3, poll=0.1)
    (env["state"] / "approved").touch()                     # the human enters the code
    assert S.wait_login("codex", timeout=10, poll=0.1)
    assert (env["tmp"] / "user" / ".codex" / "auth.json").exists()
    assert not env["sessions"].exists(S.session_name("codex"))   # closed when done
    assert S.start_login("codex").logged_in


def test_claude_login_with_code_cli(env, capsys):
    script(env["bin"] / "claude", FAKE_CLAUDE)
    assert cli_main(["agents", "login", "claude"]) == 0
    out = capsys.readouterr().out
    assert CLAUDE_URL in out
    assert "agent-bench agents login claude-code --code <CODE>" in out
    assert cli_main(["agents", "login", "claude", "--code", "good-code#state", "--timeout", "10"]) == 0
    assert env["sessions"].sent == [("agent-bench-login-claude-code", "good-code#state")]
    assert "claude-code: signed in" in capsys.readouterr().out
    assert S.logged_in("claude-code") is True


def test_login_errors(env, capsys):
    script(env["bin"] / "claude", FAKE_CLAUDE)
    assert cli_main(["agents", "login", "claude", "--code", "x"]) == 1      # nothing waiting
    assert "run `agent-bench agents login claude-code` first" in capsys.readouterr().err
    env["sessions"].tmux = False
    assert cli_main(["agents", "login", "claude"]) == 1
    assert "tmux is not on PATH" in capsys.readouterr().err
    assert cli_main(["agents", "login", "openhands"]) == 0
    assert "no sign-in" in capsys.readouterr().out


# ---- preflight ----------------------------------------------------------------------

def _exp(tmp: Path, builders: str, protocol: str = "one-shot") -> Experiment:
    f = tmp / "exp.toml"
    f.write_text(f'''
run_id = "pf"
runs_dir = "{tmp / 'runs'}"
tasks = ["{ROOT / 'examples/tasks/wordfreq'}"]
arms = ["{ROOT / 'examples/arms/stdlib.toml'}"]
protocol = "{protocol}"
min_free_gb = 0
{builders}
''')
    return Experiment.load(f)


CODEX_CHATGPT = '''
[[builders]]
name = "cx"
agent = "codex"
model = "gpt-6.1-sol"
options = { auth = "chatgpt" }
'''


def test_preflight_waits_for_sign_in_then_proceeds(env, monkeypatch):
    node(env)
    script(env["tmp"] / "real-codex", FAKE_CODEX)
    exp = _exp(env["tmp"], CODEX_CHATGPT + '''
[[builders]]
name = "oc"
agent = "opencode"
model = "m"
''')
    specs = to_prepare(exp, builds(exp, Proxy(exp=exp)))
    assert [s.name for s in specs] == ["cx", "oc"]
    msgs = []
    # codex installs (the fake npm puts a codex there), which is then swapped
    # for the fake that signs in; the human approves a second later
    orig_install = S.install

    def install_then_fake(p, log=print):
        orig_install(p, log)
        if p.agent == "codex":
            (env["tools"] / "npm" / "bin" / "codex").write_text((env["tmp"] / "real-codex").read_text())
    monkeypatch.setattr(S, "install", install_then_fake)
    threading.Timer(1.0, lambda: (env["state"] / "approved").touch()).start()
    t0 = time.time()
    assert S.preflight(specs, {}, log=msgs.append, login_timeout=20, poll=0.1) == []
    text = "\n".join(msgs)
    assert "https://auth.openai.com/codex/device" in text and "0NP7-GCWKQ" in text
    assert "preflight: codex: signed in" in text
    assert 0.9 < time.time() - t0 < 15
    assert S.check("opencode").ok and S.check("codex").ok


def test_preflight_times_out(env):
    script(env["bin"] / "codex", FAKE_CODEX)
    exp = _exp(env["tmp"], CODEX_CHATGPT)
    with pytest.raises(RuntimeError, match="still not signed in"):
        S.preflight(to_prepare(exp, builds(exp, Proxy(exp=exp))), {}, log=lambda m: None, login_timeout=0.5,
                    poll=0.1)


def test_dry_run_reports_without_installing_or_waiting(env, capsys):
    script(env["bin"] / "codex", FAKE_CODEX)                 # installed, not signed in
    exp = _exp(env["tmp"], CODEX_CHATGPT + '''
[[builders]]
name = "oh"
agent = "openhands"
model = "m"
''', protocol="reviewed")
    specs = to_prepare(exp, builds(exp, Proxy(exp=exp)))
    assert [s.agent for s in specs] == ["codex", "openhands", "claude-code"]   # + the reviewed driver
    t0 = time.time()
    run(exp, dry_run=True)
    assert time.time() - t0 < 30
    out = capsys.readouterr().out
    assert "preflight (dry run): not ready:" in out
    assert "codex: not signed in; `agent-bench agents login codex`" in out
    assert "openhands: not installed; would install openhands==1.16.0" in out
    assert "claude-code: not installed; would install @anthropic-ai/claude-code@2.1.318" in out
    assert "claude-code: sign-in unknown (not installed)" in out   # the driver pays with the login
    assert calls(env) == [] and env["sessions"].started == []
    run(exp, dry_run=True, check_agents=False)               # --no-preflight
    assert "preflight" not in capsys.readouterr().out


def test_bin_option_is_not_managed(env):
    exp = _exp(env["tmp"], '''
[[builders]]
name = "cc"
agent = "claude-code"
model = "m"
options = { bin = "/bin/false", auth = "subscription" }
''')
    msgs = []
    assert S.preflight(to_prepare(exp, builds(exp, Proxy(exp=exp))), {}, log=msgs.append) == []
    assert "used as it is" in msgs[0] and env["sessions"].started == []


def test_needs_login():
    spec = lambda agent, **o: BuilderSpec(name="b", agent=agent, options=o)  # noqa: E731
    assert S.needs_login(spec("codex", auth="chatgpt"), {})
    assert not S.needs_login(spec("codex"), {})
    assert S.needs_login(spec("claude-code", auth="subscription"), {"ANTHROPIC_API_KEY": "k"})
    assert S.needs_login(spec("claude-code"), {})
    assert not S.needs_login(spec("claude-code"), {"ANTHROPIC_API_KEY": "k"})
    assert not S.needs_login(spec("claude-code", auth="api-key"), {})
    assert not S.needs_login(spec("opencode"), {})


@pytest.mark.skipif(shutil.which("tmux") is None, reason="tmux not installed")
def test_real_tmux_holds_the_sign_in(env, monkeypatch):
    """The real session holder, with the fake codex: the sign-in outlives the
    call, its pane gives the URL and code, and it is closed once signed in."""
    script(env["bin"] / "codex", FAKE_CODEX)
    monkeypatch.setenv("PATH", f"{env['bin']}:{os.environ.get('ORIG_PATH', '/usr/bin:/bin:/usr/local/bin')}")
    monkeypatch.setattr(S, "sessions", lambda: S.Tmux())
    name = f"agent-bench-test-{os.getpid()}-codex"
    monkeypatch.setattr(S, "session_name", lambda agent: name)
    try:
        st = S.start_login("codex", timeout=20, poll=0.2)
        assert (st.url, st.code) == ("https://auth.openai.com/codex/device", "0NP7-GCWKQ")
        assert S.Tmux().exists(name)
        assert not list((env["tmp"] / "ab" / "login").glob("*.env"))   # the env file is gone once read
        (env["state"] / "approved").touch()
        assert S.wait_login("codex", timeout=20, poll=0.2)
        assert not S.Tmux().exists(name)
    finally:
        S.Tmux().kill(name)
