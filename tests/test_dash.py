"""The shared dashboard: the join token, sealing (and what the page must reject),
the snapshot a machine publishes, and several machines publishing to one repo
without touching each other's files, including the history squash."""

import json
import os
import subprocess
import time
from pathlib import Path

import pytest

import agent_bench.dash as dash

pytest.importorskip("cryptography")


def _now_iso(offset: float = 0.0) -> str:
    from datetime import datetime, timezone
    return datetime.fromtimestamp(time.time() + offset, timezone.utc).isoformat(timespec="seconds")


def test_token_round_trip(tmp_path):
    key = os.urandom(32)
    tok = dash.make_token("me/data", key, "-----BEGIN KEY-----\nabc\n-----END KEY-----\n")
    assert tok.startswith("abdash1.")
    t = dash.read_token(tok)
    assert t["repo"] == "me/data" and dash._unb64u(t["key"]) == key
    f = tmp_path / "tok"
    f.write_text(tok + "\n")
    assert dash.read_token(f"@{f}")["repo"] == "me/data"
    with pytest.raises(ValueError):
        dash.read_token("nope")


def test_seal_binds_key_and_file():
    key = os.urandom(32)
    fid = dash.file_id(key, "box")
    assert fid != dash.file_id(key, "clarity1") and len(fid) == 24
    assert fid != dash.file_id(os.urandom(32), "box")  # names are not guessable without the key
    text = dash.seal(key, fid, {"machine": "box", "n": 1})
    assert dash.unseal(key, fid, text) == {"machine": "box", "n": 1}
    with pytest.raises(Exception):
        dash.unseal(os.urandom(32), fid, text)        # another key: rejected
    with pytest.raises(Exception):
        dash.unseal(key, dash.file_id(key, "x"), text)  # moved to another machine's file: rejected


def _run(root: Path, run_id: str, started: str, runner_pid: int | None) -> Path:
    r = root / run_id
    r.mkdir(parents=True)
    (r / "manifest.json").write_text(json.dumps({
        "run_id": run_id, "experiment": "/x/exp/e.toml", "started": started,
        "agent_versions": {"codex": "codex-cli 0.166.0"},
        "config": {"protocol": "one-shot", "lanes": 1}}))
    plan = [{"build": f"t{i}__jac__codex__r1", "task": f"t{i}", "arm": "jac", "builder": "codex", "rep": 1}
            for i in range(3)]
    (r / "plan.json").write_text(json.dumps(plan))
    if runner_pid:
        (r / "runner.pid").write_text(str(runner_pid))
    return r


def test_snapshot_states_and_tokens(tmp_path):
    root = tmp_path / "runs"
    _run(root, "old", _now_iso(-7200), None)
    r = _run(root, "new", _now_iso(-60), os.getpid())
    done = r / "t0__jac__codex__r1"
    done.mkdir()
    (done / "build.json").write_text(json.dumps({"started": _now_iso(-50)}))
    (done / "summary.json").write_text(json.dumps({
        "status": "works", "finished": _now_iso(-10), "wall_s": 40.0,
        "tokens": {"builder": {"source": "metered", "calls": 2,
                               "metered": {"input": 10, "cache_read": 100, "cache_write": 0, "output": 5,
                                           "reasoning": 1}},
                   "driver": {"total": 0}},
        "acceptance": {"passed": True, "reasons": [], "metrics": {"cases": 10}},
        "arm_loc": {"lines_added": 42}}))
    running = r / "t1__jac__codex__r1"
    running.mkdir()
    t0 = time.time() - 30
    (running / "build.json").write_text(json.dumps({"started": _now_iso(-30)}))
    (running / "live.json").write_text(json.dumps({"phase": "builder turn 0", "since": t0}))
    rows = [{"ts": t0 + i, "tag": "t1~ab.builder",
             "usage": {"input": 1, "cache_read": 10, "cache_write": 0, "output": 2, "reasoning": 0}}
            for i in range(5)]
    rows.append({"ts": t0 + 6, "tag": "t1~ab.builder", "usage": None})        # a GET /models: no usage
    rows.append({"ts": t0 + 7, "tag": "t1~ab.driver",
                 "usage": {"input": 7, "cache_read": 0, "cache_write": 0, "output": 0}})
    (running / "calls.jsonl").write_text("\n".join(json.dumps(x) for x in rows) + "\n")

    snap = dash.snapshot({"machine": "m1", "roots": [str(root)], "since": _now_iso(-3600)})
    assert snap["machine"] == "m1" and [x["run_id"] for x in snap["runs"]] == ["new"]  # "old" predates since
    run = snap["runs"][0]
    assert run["state"] == "running" and run["agent_versions"] == {"codex": "codex-cli 0.166.0"}
    b = {x["task"]: x for x in run["builds"]}
    assert b["t0"]["state"] == "done" and b["t0"]["accepted"] is True
    assert b["t0"]["tokens"] == {"input": 10, "cache_read": 100, "cache_write": 0, "output": 5, "reasoning": 1,
                                 "total": 115}
    assert b["t0"]["lines_added"] == 42
    assert b["t1"]["state"] == "running" and b["t1"]["phase"] == "builder turn 0"
    assert b["t1"]["tokens"]["total"] == 5 * 13 and b["t1"]["calls"] == 5
    assert b["t1"]["driver_total"] == 7
    assert b["t1"]["timeline"][-1][1] == 65
    assert b["t2"]["state"] == "queued"
    assert snap["host"]["cpus"] >= 1


def _bare(tmp_path: Path) -> Path:
    bare = tmp_path / "data.git"
    subprocess.run(["git", "init", "-q", "--bare", "-b", "main", str(bare)], check=True)
    return bare


def _join(tmp_path: Path, monkeypatch, name: str, key: bytes, bare: Path, root: Path) -> dict:
    home = tmp_path / f"home-{name}"
    monkeypatch.setenv("AGENT_BENCH_DASH_HOME", str(home))
    cfg = dash.join(dash.make_token("me/data", key, "fake-ssh-key"), name, [str(root)], _now_iso(-3600))
    cfg["remote"] = str(bare)
    (home / "config.json").write_text(json.dumps(cfg))
    assert oct((home / "id_ed25519").stat().st_mode & 0o777) == "0o600"
    assert oct((home / "config.json").stat().st_mode & 0o777) == "0o600"
    return cfg


def _read_back(tmp_path: Path, bare: Path, key: bytes) -> dict:
    co = tmp_path / f"co-{time.time_ns()}"
    subprocess.run(["git", "clone", "-q", str(bare), str(co)], check=True)
    idx = json.loads((co / "index.json").read_text())
    out = {}
    for f in idx["files"]:
        fid = f.removesuffix(".enc")
        d = dash.unseal(key, fid, (co / "machines" / f).read_text().strip())
        out[d["machine"]] = d
    return out


def test_machines_publish_side_by_side(tmp_path, monkeypatch):
    key = os.urandom(32)
    bare = _bare(tmp_path)
    root = tmp_path / "runs"
    root.mkdir()
    _run(root, "r1", _now_iso(-10), None)
    homes = {}
    for name in ("clarity1", "box"):
        cfg = _join(tmp_path, monkeypatch, name, key, bare, root)
        homes[name] = (os.environ["AGENT_BENCH_DASH_HOME"], cfg)
        assert dash.publish_once(cfg) == "pushed"
    # each machine publishes again on top of the other's commit
    for name, (home, cfg) in homes.items():
        monkeypatch.setenv("AGENT_BENCH_DASH_HOME", home)
        assert dash.publish_once(cfg) in ("pushed", "unchanged")
    got = _read_back(tmp_path, bare, key)
    assert set(got) == {"clarity1", "box"}
    assert got["box"]["runs"][0]["run_id"] == "r1"


def test_history_is_squashed(tmp_path, monkeypatch):
    key = os.urandom(32)
    bare = _bare(tmp_path)
    root = tmp_path / "runs"
    root.mkdir()
    monkeypatch.setattr(dash, "SQUASH_AT", 4)
    cfg = _join(tmp_path, monkeypatch, "box", key, bare, root)
    results = []
    for i in range(6):
        _run(root, f"r{i}", _now_iso(-10 + i), None)  # a new run each time: always a change
        results.append(dash.publish_once(cfg))
    assert "squashed" in results
    n = subprocess.run(["git", "--git-dir", str(bare), "rev-list", "--count", "main"],
                       capture_output=True, text=True, check=True).stdout.strip()
    assert int(n) < 4
    assert len(_read_back(tmp_path, bare, key)["box"]["runs"]) == 6
