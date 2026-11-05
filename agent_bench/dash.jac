"""The shared dashboard: every machine publishes its own runs, encrypted, to one
GitHub repo, and a static page decrypts and merges them in the browser.

One join token carries everything a machine needs: the data repo, a 256-bit data
key, and a deploy key that can write to that repo only. A machine that joined
writes one file, `machines/<id>.enc`, where `<id>` is an HMAC of its name under
the data key, so the repo shows neither machine names nor content. Each file is
AES-256-GCM over gzip'd JSON, with the file id as associated data: the page drops
anything the data key did not seal, and a file cannot be passed off as another
machine's. Machines never write each other's files, so any number of them can
publish without coordinating.

    agent-bench dash init --repo OWNER/NAME --ssh-key KEY   # once: makes the token
    agent-bench dash join TOKEN|@FILE --machine NAME --roots DIR...
    agent-bench dash publish [--once] [--every 60]
    agent-bench dash link                                   # the page link, key included
    agent-bench dash snapshot                               # what would be published

The page link carries the data key after `#`, which browsers never send to a
server; anyone with the link can read the dashboard, anyone with the token can
also write to it.
"""

import base64;
import gzip;
import hashlib;
import hmac;
import json;
import os;
import random;
import shutil;
import subprocess;
import time;
import from datetime { datetime, timezone }
import from pathlib { Path }
import from agent_bench.common { Json }
import from agent_bench.monitor { runner_alive }

glob TOKEN_PREFIX: str = "abdash1.";
glob PAGE: str = "https://jayanaka.dev/agent-bench/dash/";
glob AAD_PREFIX: str = "agent-bench-dash/v1/";
glob SQUASH_AT: int = 300;           # commits on main before a publisher squashes it
glob HEARTBEAT_S: int = 600;         # publish at least this often, even with no change
glob MAX_RUNS: int = 40;
glob TIMELINE_POINTS: int = 90;

def dash_home -> Path {
    return Path(os.environ.get("AGENT_BENCH_DASH_HOME", str(Path.home() / ".agent-bench" / "dash")));
}

def _b64u(b: bytes) -> str {
    return base64.urlsafe_b64encode(b).decode().rstrip("=");
}

def _unb64u(s: str) -> bytes {
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4));
}

def now_iso -> str {
    return datetime.now(timezone.utc).isoformat(timespec="seconds");
}

def _parse_iso(s: str | None) -> float {
    if not s {
        return 0.0;
    }
    try {
        return datetime.fromisoformat(str(s)).timestamp();
    } except ValueError {
        return 0.0;
    }
}

# ---- token, config, crypto ---------------------------------------------------------

def make_token(repo: str, key: bytes, ssh_private: str) -> str {
    return TOKEN_PREFIX + _b64u(json.dumps({"repo": repo, "key": _b64u(key), "ssh": ssh_private}).encode());
}

def read_token(token: str) -> Json {
    t = token.strip();
    if t.startswith("@") {
        t = Path(t[1:]).expanduser().read_text().strip();
    }
    if not t.startswith(TOKEN_PREFIX) {
        raise ValueError("not an agent-bench dash token");
    }
    return json.loads(_unb64u(t[len(TOKEN_PREFIX):])) as Json;
}

def load_config -> Json {
    p = dash_home() / "config.json";
    if not p.exists() {
        raise FileNotFoundError(f"not joined: no {p} (run `agent-bench dash join`)");
    }
    return json.loads(p.read_text()) as Json;
}

def data_key(cfg: Json) -> bytes {
    return _unb64u(str(cfg["key"]));
}

def file_id(key: bytes, machine: str) -> str {
    return hmac.new(key, ("agent-bench-dash/machine/" + machine).encode(), hashlib.sha256).hexdigest()[:24];
}

def seal(key: bytes, fid: str, payload: Json) -> str {
    import from cryptography.hazmat.primitives.ciphers.aead { AESGCM }
    nonce = os.urandom(12);
    raw = gzip.compress(json.dumps(payload, separators=(",", ":")).encode(), mtime=0);
    ct = AESGCM(key).encrypt(nonce, raw, (AAD_PREFIX + fid).encode());
    return base64.b64encode(nonce + ct).decode();
}

def unseal(key: bytes, fid: str, text: str) -> Json {
    import from cryptography.hazmat.primitives.ciphers.aead { AESGCM }
    blob = base64.b64decode(text);
    raw = AESGCM(key).decrypt(blob[:12], blob[12:], (AAD_PREFIX + fid).encode());
    return json.loads(gzip.decompress(raw)) as Json;
}

def view_link(cfg: Json) -> str {
    return f"{cfg.get('page') or PAGE}#k={cfg['key']}&r={cfg['repo']}";
}

def _write_private(p: Path, text: str) {
    p.parent.mkdir(parents=True, exist_ok=True);
    fd = os.open(str(p), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600);
    with os.fdopen(fd, "w") as f {
        f.write(text);
    }
    os.chmod(p, 0o600);
}

"""Write the join state for this machine: the data key and deploy key (mode 0600)
and which runs directories to publish, from `since` on."""
def join(token: str, machine: str, roots: list[str], since: str | None = None) -> Json {
    t = read_token(token);
    home = dash_home();
    _write_private(home / "id_ed25519", str(t["ssh"]).rstrip() + "\n");
    cfg: Json = {
        "repo": t["repo"], "key": t["key"], "machine": machine,
        "roots": [str(Path(r).expanduser().resolve()) for r in roots],
        "since": since or now_iso(), "page": PAGE
    };
    _write_private(home / "config.json", json.dumps(cfg, indent=2));
    return cfg;
}

# ---- what a machine publishes -------------------------------------------------------

def _read_json(p: Path) -> any {
    try {
        return json.loads(p.read_text());
    } except (OSError, ValueError) {
        return None;
    }
}

def _tok(u: Json | None) -> Json {
    d = u or {};
    out: Json = {k: int(d.get(k) or 0) for k in ("input", "cache_read", "cache_write", "output", "reasoning")};
    out["total"] = out["input"] + out["cache_read"] + out["cache_write"] + out["output"];
    return out;
}

"""Per-role token totals, call count and a cumulative builder-token timeline from
a build's proxy ledger (calls.jsonl), for a build that is still running."""
def ledger_view(bdir: Path, t0: float) -> Json {
    roles: dict[str, Json] = {};
    pts: list[list[float]] = [];
    cum = 0;
    p = bdir / "calls.jsonl";
    if p.exists() {
        for line in p.read_text(errors="replace").splitlines() {
            try {
                r = json.loads(line) as Json;
            } except ValueError {
                continue;
            }
            u = r.get("usage");
            if not u {
                continue;
            }
            role = str(r.get("tag", "")).rsplit(".", 1)[-1] or "builder";
            k = _tok(u as Json);
            acc = roles.setdefault(role, {**_tok(None), "calls": 0});
            for f in ("input", "cache_read", "cache_write", "output", "reasoning", "total") {
                acc[f] = int(acc[f]) + int(k[f]);
            }
            acc["calls"] = int(acc["calls"]) + 1;
            if role == "builder" {
                cum += int(k["total"]);
                pts.append([round(float(r.get("ts", t0)) - t0, 1), cum]);
            }
        }
    }
    if len(pts) > TIMELINE_POINTS {
        step = len(pts) / TIMELINE_POINTS;
        pts = [pts[int(i * step)] for i in range(TIMELINE_POINTS - 1)] + [pts[-1]];
    }
    return {"roles": roles, "timeline": pts};
}

glob _DONE_CACHE: dict[str, list[any]] = {};

def build_view(bdir: Path, item: Json) -> Json {
    v: Json = {k: item.get(k) for k in ("build", "task", "arm", "builder", "rep")};
    meta = _read_json(bdir / "build.json") or {};
    started = _parse_iso(meta.get("started"));
    v["started"] = meta.get("started");
    summ = bdir / "summary.json";
    if summ.exists() {
        key = str(summ);
        mt = summ.stat().st_mtime;
        hit = _DONE_CACHE.get(key);
        if hit and hit[0] == mt {
            return hit[1];
        }
        s = (_read_json(summ) or {}) as Json;
        b = ((s.get("tokens") or {}).get("builder") or {}) as Json;
        acc = s.get("acceptance") or None;
        led = ledger_view(bdir, started or 0.0);
        v.update({
            "state": "done", "status": s.get("status"), "finished": s.get("finished"),
            "accepted": (acc.get("passed") if acc else None),
            "reasons": ((acc.get("reasons") or [])[:3] if acc else []),
            "metrics": (acc.get("metrics") if acc else None),
            "tokens": _tok(b.get("metered") or b.get("self_reported")),
            "token_source": b.get("source"), "calls": b.get("calls"),
            "driver_total": int((((s.get("tokens") or {}).get("driver") or {}).get("total")) or 0),
            "wall_s": s.get("wall_s"), "lines_added": ((s.get("arm_loc") or {}).get("lines_added")),
            "tool_calls": ((((s.get("analysis") or {}).get("tool_counts") or {}).get("builder") or {}).get("total")),
            "timeline": led["timeline"]
        });
        _DONE_CACHE[key] = [mt, v];
        return v;
    }
    if not bdir.exists() {
        v["state"] = "queued";
        return v;
    }
    live = _read_json(bdir / "live.json") or {};
    led = ledger_view(bdir, started or time.time());
    role_b: Json = led["roles"].get("builder") or {**_tok(None), "calls": 0};
    v.update({
        "state": "running" if live else "starting",
        "phase": live.get("phase"), "phase_since": live.get("since"),
        "tokens": {k: role_b[k] for k in ("input", "cache_read", "cache_write", "output", "reasoning", "total")},
        "calls": role_b["calls"],
        "driver_total": int((led["roles"].get("driver") or {}).get("total") or 0),
        "wall_s": round(time.time() - started, 1) if started else None,
        "timeline": led["timeline"]
    });
    return v;
}

def run_view(rdir: Path, man: Json) -> Json {
    plan = _read_json(rdir / "plan.json") or [];
    builds = [build_view(rdir / str(e["build"]), e as Json) for e in plan];
    cfg = (man.get("config") or {}) as Json;
    alive = runner_alive(rdir);
    return {
        "run_id": man.get("run_id") or rdir.name, "dir": rdir.name,
        "experiment": Path(str(man.get("experiment") or "")).name,
        "started": man.get("started"),
        "state": "running" if alive else ("done" if all([b.get("state") == "done" for b in builds]) else "stopped"),
        "protocol": cfg.get("protocol"), "lanes": cfg.get("lanes"),
        "agent_versions": man.get("agent_versions") or {},
        "builds": builds
    };
}

def host_view -> Json {
    h: Json = {"cpus": os.cpu_count()};
    try {
        h["load"] = [round(x, 2) for x in os.getloadavg()];
    } except OSError {
        h["load"] = None;
    }
    mi = Path("/proc/meminfo");
    if mi.exists() {
        m: dict[str, int] = {};
        for line in mi.read_text().splitlines() {
            parts = line.split();
            if len(parts) >= 2 {
                m[parts[0].rstrip(":")] = int(parts[1]);
            }
        }
        h["mem_total_gb"] = round(m.get("MemTotal", 0) / 1048576, 1);
        h["mem_avail_gb"] = round(m.get("MemAvailable", 0) / 1048576, 1);
    }
    du = shutil.disk_usage(str(Path.home()));
    h["disk_free_gb"] = round(du.free / 1e9, 1);
    return h;
}

def _started_key(r: Json) -> str {
    return str(r.get("started") or "");
}

"""Everything this machine publishes: its runs started at or after `since`."""
def snapshot(cfg: Json) -> Json {
    since = _parse_iso(cfg.get("since"));
    runs: list[Json] = [];
    for rdir_root in cfg.get("roots") or [] {
        for man_p in sorted(Path(str(rdir_root)).glob("*/manifest.json")) {
            man = (_read_json(man_p) or {}) as Json;
            if _parse_iso(man.get("started")) < since {
                continue;
            }
            runs.append(run_view(man_p.parent, man));
        }
    }
    runs.sort(key=_started_key, reverse=True);
    return {"v": 1, "machine": cfg["machine"], "at": now_iso(), "host": host_view(), "runs": runs[:MAX_RUNS]};
}

# ---- publishing --------------------------------------------------------------------

def _git(args: list[str], check: bool = True) -> subprocess.CompletedProcess[str] {
    home = dash_home();
    env = dict(os.environ);
    env["GIT_SSH_COMMAND"] = (f"ssh -i {home / 'id_ed25519'} -o IdentitiesOnly=yes "
                              "-o StrictHostKeyChecking=accept-new -o BatchMode=yes");
    env["GIT_TERMINAL_PROMPT"] = "0";
    return subprocess.run(["git", "-C", str(home / "repo"), *args], capture_output=True, text=True,
                          env=env, check=check, timeout=120);
}

def _ensure_clone(cfg: Json) {
    repo = dash_home() / "repo";
    if (repo / ".git").exists() {
        return;
    }
    repo.mkdir(parents=True, exist_ok=True);
    _git(["init", "-q", "-b", "main"]);
    _git(["remote", "add", "origin", str(cfg.get("remote") or f"git@github.com:{cfg['repo']}.git")]);
}

def _commit(msg: str) {
    _git(["-c", "user.name=agent-bench-dash", "-c", "user.email=agent-bench-dash@users.noreply.github.com",
          "commit", "-q", "-m", msg]);
}

"""Write this machine's sealed file on top of the current main and push. On a
rejected push (another machine got there first) start over from the new main;
past SQUASH_AT commits, replace main's history with one commit (force-with-lease,
so a concurrent push is never lost: that publisher just retries)."""
def publish_once(cfg: Json, snap: Json | None = None) -> str {
    _ensure_clone(cfg);
    key = data_key(cfg);
    fid = file_id(key, str(cfg["machine"]));
    sealed = seal(key, fid, snap if snap is not None else snapshot(cfg));
    pushed: subprocess.CompletedProcess[str] | None = None;
    repo = dash_home() / "repo";
    for attempt in range(6) {
        f = _git(["fetch", "-q", "--depth", "1", "origin", "main"], check=False);
        remote = "";
        if f.returncode == 0 {
            _git(["reset", "-q", "--hard", "FETCH_HEAD"]);
            remote = _git(["rev-parse", "HEAD"]).stdout.strip();
        } elif "couldn't find remote ref" not in f.stderr {
            raise RuntimeError(f"git fetch: {f.stderr.strip()}");
        }
        (repo / "machines").mkdir(exist_ok=True);
        (repo / "machines" / f"{fid}.enc").write_text(sealed + "\n");
        files = sorted([p.name for p in (repo / "machines").glob("*.enc")]);
        (repo / "index.json").write_text(json.dumps({"v": 1, "files": files}, indent=1) + "\n");
        _git(["add", "-A"]);
        if not _git(["status", "--porcelain"]).stdout.strip() {
            return "unchanged";
        }
        # The fetch is shallow, so the history length rides in the commit
        # message ("update #N"), counted from the last squash.
        n = 0;
        if remote {
            subj = _git(["log", "-1", "--format=%s"], check=False).stdout.strip();
            tail = subj.rsplit("#", 1)[-1];
            n = int(tail) if tail.isdigit() else 0;
        }
        squash = bool(remote) and n + 1 >= SQUASH_AT;
        if squash {
            _git(["checkout", "-q", "--orphan", "squash"]);
            _commit("dashboard data, history squashed #0");
            pushed = _git(["push", "-q", f"--force-with-lease=main:{remote}", "origin", "HEAD:main"], check=False);
            _git(["checkout", "-q", "-B", "main"]);
        } else {
            _commit(f"update #{n + 1}");
            pushed = _git(["push", "-q", "origin", "HEAD:main"], check=False);
        }
        if pushed is not None and pushed.returncode == 0 {
            return "squashed" if squash else "pushed";
        }
        time.sleep(1 + random.random() * 3 * (attempt + 1));
    }
    raise RuntimeError(f"git push kept failing: {pushed.stderr.strip() if pushed else ''}");
}

def _fingerprint(snap: Json) -> str {
    s = dict(snap);
    s.pop("at", None);
    s.pop("host", None);
    return hashlib.sha256(json.dumps(s, sort_keys=True).encode()).hexdigest();
}

"""Publish now and then every `every` seconds while any run is active (else every
HEARTBEAT_S), skipping a publish when nothing but the clock changed."""
def publish_loop(every: int, once: bool) -> int {
    last_fp = "";
    last_at = 0.0;
    while True {
        cfg = load_config();
        snap = snapshot(cfg);
        active = any([r.get("state") == "running" for r in snap["runs"]]);
        fp = _fingerprint(snap);
        due = fp != last_fp or time.time() - last_at >= HEARTBEAT_S;
        if due {
            try {
                res = publish_once(cfg, snap);
                last_fp = fp;
                last_at = time.time();
                print(f"[{time.strftime('%H:%M:%S')}] {res}: {len(snap['runs'])} run(s)", flush=True);
            } except Exception as e {
                print(f"[{time.strftime('%H:%M:%S')}] publish failed: {e}", flush=True);
            }
        }
        if once {
            return 0;
        }
        time.sleep(every if active else min(HEARTBEAT_S, max(every, 120)));
    }
}
