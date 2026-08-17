#!/usr/bin/env python3
"""Gate for the Respond hold path in src/pulse_hook.py (protocol v1).

Std-lib only. Each case runs against a throwaway PULSE_HOME. The HMAC for
every crafted verdict is computed *here*, from the frozen canonical string
("v1\\n" + request_id + "\\n" + digest + ...), never by calling the hook's own
helper — so a drift in the hook's canonical string turns this gate red.

Covered:
  1.  no secret key            -> no request file, empty stdout, exit 0
  2.  key + valid allow verdict-> decision JSON on stdout, verdict renamed .used
      (full subprocess round-trip, request-file contents and 0600 asserted)
  3.  tampered HMAC            -> not adopted
  4.  digest mismatch (HMAC valid over the wrong digest) -> not adopted
  5.  allow on a truncated request -> not adopted; deny on the same -> adopted
  6.  expired verdict          -> not adopted; skew boundary (+5 min) honored
  7.  same verdict a second time (already .used) -> not adopted
  8.  timeout path (subprocess, PULSE_RESPOND_MAX_HOLD_SECONDS=5)
      -> empty stdout, exit 0, elapsed within hold cap + 2 s
  plus: request-id sanitizing, directory cap (64, oldest deleted)

Red-first discipline: while developing this gate, invert one assertion, run
it, watch the script exit 1, then restore it. Done for this script on
2026-08-17: the case-2 round-trip was inverted to expect behavior "deny",
the run went red as expected, and the assertion was restored to "allow".
Repeat that ritual whenever you touch a case here.

Exit 0 with an OK summary only when every check passes; exit 1 otherwise.
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HOOK = ROOT / "src" / "pulse_hook.py"
sys.path.insert(0, str(ROOT / "src"))

import pulse_hook  # noqa: E402

HOST = "checkhost"
AGENT = "claude"
KEY = b"gate-shared-secret"

FAILURES: list[str] = []
PASSED = 0


def check(name: str, cond: bool, detail: str = "") -> None:
    global PASSED
    if cond:
        PASSED += 1
        print(f"  ok   {name}")
    else:
        FAILURES.append(name)
        print(f"  FAIL {name}" + (f" — {detail}" if detail else ""))


def payload_bytes(request_id: str, command: str = "ls -la /tmp") -> bytes:
    return json.dumps(
        {
            "hook_event_name": "PermissionRequest",
            "session_id": "sess-check",
            "cwd": "/work/project",
            "tool_name": "Bash",
            "tool_input": {"command": command},
            "tool_use_id": request_id,
        }
    ).encode("utf-8")


def canonical(request_id, digest, agent, host, allow, decided, expires) -> bytes:
    # Deliberately re-stated from the frozen protocol, not imported.
    return (
        "v1\n"
        + request_id
        + "\n"
        + digest
        + "\n"
        + agent
        + "\n"
        + host
        + "\n"
        + ("allow" if allow else "deny")
        + "\n"
        + str(decided)
        + "\n"
        + str(expires)
    ).encode("utf-8")


def make_verdict(
    request_id: str,
    digest: str,
    allow: bool,
    decided: int,
    expires: int,
    *,
    key: bytes = KEY,
    agent: str = AGENT,
    host: str = HOST,
    hmac_hex: str | None = None,
) -> dict:
    if hmac_hex is None:
        hmac_hex = hmac.new(
            key, canonical(request_id, digest, agent, host, allow, decided, expires), hashlib.sha256
        ).hexdigest()
    return {
        "v": 1,
        "request_id": request_id,
        "digest": digest,
        "agent": agent,
        "host": host,
        "allow": allow,
        "decided_at_ms": decided,
        "expires_at_ms": expires,
        "hmac": hmac_hex,
    }


class FakeClock:
    """Injectable clock: sleep() advances time so holds run instantly."""

    def __init__(self, start_ms: int = 1_755_000_000_000):
        self.ms = start_ms

    def now(self) -> int:
        return self.ms

    def sleep(self, seconds: float) -> None:
        self.ms += max(1, int(seconds * 1000))


def fresh_home(tag: str, *, key: bytes | None = KEY, hold: str = "5"):
    home = Path(tempfile.mkdtemp(prefix=f"pulse-respond-check-{tag}-"))
    env = dict(os.environ)
    env["PULSE_HOME"] = str(home)
    env["PULSE_HOST"] = HOST
    env["PULSE_RESPOND_MAX_HOLD_SECONDS"] = hold
    if key is not None:
        (home / "respond-secret.key").write_bytes(key + b"\n")
    return home, env


def apply_env(env: dict) -> None:
    """Point the in-process pulse_hook at the same throwaway home."""
    for k in ("PULSE_HOME", "PULSE_HOST", "PULSE_RESPOND_MAX_HOLD_SECONDS"):
        os.environ[k] = env[k]


def run_hook(env: dict, stdin_bytes: bytes):
    started = time.monotonic()
    proc = subprocess.run(
        [sys.executable, str(HOOK), AGENT],
        input=stdin_bytes,
        capture_output=True,
        env=env,
        timeout=120,
    )
    return proc, time.monotonic() - started


def place_verdict(home: Path, name: str, verdict: dict) -> Path:
    vdir = home / "respond.d" / "verdicts"
    vdir.mkdir(parents=True, exist_ok=True)
    path = vdir / f"{name}.json"
    path.write_text(json.dumps(verdict), encoding="utf-8")
    return path


def case_no_key() -> None:
    print("case 1: no secret key -> legacy behavior, no request, no hold")
    home, env = fresh_home("nokey", key=None)
    try:
        proc, elapsed = run_hook(env, payload_bytes("toolu_nokey"))
        check("exit 0", proc.returncode == 0, f"rc={proc.returncode}")
        check("stdout empty", proc.stdout == b"", repr(proc.stdout[:120]))
        requests = list((home / "respond.d" / "requests").glob("*")) if (
            home / "respond.d" / "requests"
        ).exists() else []
        check("no request file written", requests == [], str(requests))
        check("attention tsv still written", (home / "attention.tsv").exists())
        check("returned promptly (no hold)", elapsed < 3.0, f"{elapsed:.1f}s")
    finally:
        shutil.rmtree(home, ignore_errors=True)


def case_allow_roundtrip() -> None:
    print("case 2: key + valid allow verdict -> decision on stdout (subprocess)")
    rid = "toolu_allow_1"
    stdin = payload_bytes(rid)
    digest = hashlib.sha256(stdin).hexdigest()
    home, env = fresh_home("allow")
    try:
        now = int(time.time() * 1000)
        vpath = place_verdict(home, rid, make_verdict(rid, digest, True, now, now + 90_000))
        proc, elapsed = run_hook(env, stdin)
        check("exit 0", proc.returncode == 0, f"rc={proc.returncode}")
        decision = None
        try:
            decision = json.loads(proc.stdout.decode("utf-8"))
        except ValueError:
            pass
        check("stdout is JSON", decision is not None, repr(proc.stdout[:200]))
        hso = (decision or {}).get("hookSpecificOutput", {})
        check("hookEventName", hso.get("hookEventName") == "PermissionRequest", str(hso))
        # Red-first ritual was performed on this assertion: "allow" -> "deny"
        # makes this gate exit 1.
        check("behavior is allow", hso.get("decision", {}).get("behavior") == "allow", str(hso))
        check(
            "message names the host",
            hso.get("decision", {}).get("message") == f"Answered via Pulse from {HOST}",
            str(hso),
        )
        check("verdict consumed exactly once (.used)", not vpath.exists() and vpath.with_name(vpath.name + ".used").exists())
        req_path = home / "respond.d" / "requests" / f"{rid}.json"
        check("request file exists", req_path.exists())
        req = json.loads(req_path.read_text(encoding="utf-8")) if req_path.exists() else {}
        check("request v==1", req.get("v") == 1, str(req.get("v")))
        check("request id verbatim", req.get("request_id") == rid)
        check("request agent/host", req.get("agent") == AGENT and req.get("host") == HOST)
        check(
            "payload_b64 is verbatim stdin",
            base64.b64decode(req.get("payload_b64", "")) == stdin,
        )
        check("digest over those bytes", req.get("digest") == digest)
        check("truncated false", req.get("truncated") is False)
        check(
            "expires = raised + hold cap",
            req.get("expires_at_ms") == req.get("raised_at_ms", 0) + 5000,
            f"raised={req.get('raised_at_ms')} expires={req.get('expires_at_ms')}",
        )
        if req_path.exists():
            mode = req_path.stat().st_mode & 0o777
            check("request file is 0600", mode == 0o600, oct(mode))
        check("answered promptly (first poll)", elapsed < 4.0, f"{elapsed:.1f}s")
    finally:
        shutil.rmtree(home, ignore_errors=True)


def hold_via_import(home: Path, rid: str, stdin: bytes, clock: FakeClock):
    payload = json.loads(stdin.decode("utf-8"))
    return pulse_hook.respond_decision_json(
        AGENT, payload, stdin, "permission", clock_ms=clock.now, sleep=clock.sleep
    )


def case_tampered_hmac() -> None:
    print("case 3: tampered HMAC -> not adopted")
    rid = "toolu_tamper"
    stdin = payload_bytes(rid)
    digest = hashlib.sha256(stdin).hexdigest()
    home, env = fresh_home("tamper")
    try:
        apply_env(env)
        clock = FakeClock()
        good = make_verdict(rid, digest, True, clock.now(), clock.now() + 90_000)
        bad_hex = ("0" if good["hmac"][0] != "0" else "1") + good["hmac"][1:]
        good["hmac"] = bad_hex
        place_verdict(home, rid, good)
        result = hold_via_import(home, rid, stdin, clock)
        check("tampered verdict rejected", result is None, str(result))
    finally:
        shutil.rmtree(home, ignore_errors=True)


def case_digest_mismatch() -> None:
    print("case 4: digest mismatch (HMAC itself valid) -> not adopted")
    rid = "toolu_digest"
    stdin = payload_bytes(rid)
    other_digest = hashlib.sha256(b"something else entirely").hexdigest()
    home, env = fresh_home("digest")
    try:
        apply_env(env)
        clock = FakeClock()
        # HMAC is computed correctly — over the *wrong* digest. Only the
        # digest binding can reject this.
        place_verdict(
            home, rid, make_verdict(rid, other_digest, True, clock.now(), clock.now() + 90_000)
        )
        result = hold_via_import(home, rid, stdin, clock)
        check("wrong-digest verdict rejected", result is None, str(result))
    finally:
        shutil.rmtree(home, ignore_errors=True)


def case_truncated() -> None:
    print("case 5: truncated request -> allow refused, deny still honored")
    rid = "toolu_trunc"
    stdin = payload_bytes(rid)
    digest = hashlib.sha256(stdin).hexdigest()
    home, env = fresh_home("trunc")
    try:
        apply_env(env)
        clock = FakeClock()
        vpath = place_verdict(home, rid, make_verdict(rid, digest, True, clock.now(), clock.now() + 90_000))
        result = pulse_hook.hold_for_verdict(
            vpath, KEY, rid, digest, AGENT, HOST,
            truncated=True, deadline_ms=clock.now() + 5000,
            clock_ms=clock.now, sleep=clock.sleep,
        )
        check("allow on truncated request refused", result is None, str(result))
        clock2 = FakeClock()
        vpath2 = place_verdict(home, rid + "_d", make_verdict(rid, digest, False, clock2.now(), clock2.now() + 90_000))
        result2 = pulse_hook.hold_for_verdict(
            vpath2, KEY, rid, digest, AGENT, HOST,
            truncated=True, deadline_ms=clock2.now() + 5000,
            clock_ms=clock2.now, sleep=clock2.sleep,
        )
        check(
            "deny on truncated request honored",
            isinstance(result2, dict) and result2.get("allow") is False,
            str(result2),
        )
    finally:
        shutil.rmtree(home, ignore_errors=True)


def case_expired() -> None:
    print("case 6: expired verdict -> not adopted; +5 min skew boundary honored")
    rid = "toolu_expired"
    stdin = payload_bytes(rid)
    digest = hashlib.sha256(stdin).hexdigest()
    clock = FakeClock()
    now = clock.now()
    skew = pulse_hook.RESPOND_CLOCK_SKEW_MS
    dead = make_verdict(rid, digest, True, now - 600_000, now - skew - 1)
    check(
        "expired past skew rejected",
        pulse_hook.verify_verdict(dead, KEY, rid, digest, AGENT, HOST, now) is False,
    )
    fresh = make_verdict(rid, digest, True, now - 600_000, now - skew + 1000)
    check(
        "inside skew window still accepted",
        pulse_hook.verify_verdict(fresh, KEY, rid, digest, AGENT, HOST, now) is True,
    )
    future = make_verdict(rid, digest, True, now + skew + 1000, now + skew + 90_000)
    check(
        "decided too far in the future rejected",
        pulse_hook.verify_verdict(future, KEY, rid, digest, AGENT, HOST, now) is False,
    )
    home, env = fresh_home("expired")
    try:
        apply_env(env)
        clock = FakeClock()
        place_verdict(
            home, rid, make_verdict(rid, digest, True, clock.now() - 600_000, clock.now() - skew - 1)
        )
        result = hold_via_import(home, rid, stdin, clock)
        check("expired verdict not adopted end-to-end", result is None, str(result))
    finally:
        shutil.rmtree(home, ignore_errors=True)


def case_second_use() -> None:
    print("case 7: same verdict a second time (already .used) -> not adopted")
    rid = "toolu_once"
    stdin = payload_bytes(rid)
    digest = hashlib.sha256(stdin).hexdigest()
    home, env = fresh_home("once")
    try:
        apply_env(env)
        clock = FakeClock()
        place_verdict(home, rid, make_verdict(rid, digest, True, clock.now(), clock.now() + 900_000))
        first = hold_via_import(home, rid, stdin, clock)
        check("first submission adopted", first is not None and '"allow"' in first, str(first))
        # The verdict now exists only as .used; a second identical hold must
        # time out instead of re-reading it.
        second = hold_via_import(home, rid, stdin, clock)
        check("second submission not adopted", second is None, str(second))
        used = home / "respond.d" / "verdicts" / f"{rid}.json.used"
        check(".used remnant is what remains", used.exists())
    finally:
        shutil.rmtree(home, ignore_errors=True)


def case_timeout() -> None:
    print("case 8: timeout path (subprocess, hold cap 5s)")
    home, env = fresh_home("timeout", hold="5")
    try:
        proc, elapsed = run_hook(env, payload_bytes("toolu_timeout"))
        check("exit 0", proc.returncode == 0, f"rc={proc.returncode}")
        check("stdout empty", proc.stdout == b"", repr(proc.stdout[:120]))
        check("held roughly the cap", 4.0 <= elapsed, f"{elapsed:.1f}s")
        check("finished within cap + 2s", elapsed <= 7.0, f"{elapsed:.1f}s")
        check(
            "request was written for the sync tool",
            (home / "respond.d" / "requests" / "toolu_timeout.json").exists(),
        )
    finally:
        shutil.rmtree(home, ignore_errors=True)


def case_hygiene() -> None:
    print("extra: request-id sanitizing and directory cap")
    nasty = "toolu/../../etc:passwd\n" + "x" * 200
    name = pulse_hook.sanitize_request_id(nasty)
    check("sanitized id charset", all(c.isalnum() or c in "._-" for c in name), name)
    check("sanitized id length <= 120", len(name) <= 120, str(len(name)))
    check("sanitized id has no path parts", "/" not in name and "\n" not in name)
    home, env = fresh_home("cap")
    try:
        rdir = home / "respond.d" / "requests"
        vdir = home / "respond.d" / "verdicts"
        rdir.mkdir(parents=True)
        vdir.mkdir(parents=True)
        now_ms = int(time.time() * 1000)
        for i in range(70):
            p = rdir / f"old_{i:03d}.json"
            p.write_text(json.dumps({"v": 1, "expires_at_ms": now_ms + 60_000}))
            os.utime(p, (time.time() - 70 + i, time.time() - 70 + i))
        pulse_hook.cleanup_respond_dirs(rdir, vdir, now_ms)
        remaining = sorted(p.name for p in rdir.glob("*.json"))
        check("directory capped at 64", len(remaining) == 64, str(len(remaining)))
        check("oldest were the ones deleted", remaining[0] == "old_006.json", remaining[0] if remaining else "")
        stale = rdir / "stale.json"
        stale.write_text(json.dumps({"v": 1, "expires_at_ms": now_ms - 3_600_001}))
        used = vdir / "gone.json.used"
        used.write_text("{}")
        old = time.time() - 3700
        os.utime(used, (old, old))
        pulse_hook.cleanup_respond_dirs(rdir, vdir, now_ms)
        check("request past expiry+1h removed", not stale.exists())
        check("stale .used removed", not used.exists())
    finally:
        shutil.rmtree(home, ignore_errors=True)


def main() -> int:
    print(f"respond_hook_check — hook: {HOOK}")
    case_no_key()
    case_allow_roundtrip()
    case_tampered_hmac()
    case_digest_mismatch()
    case_truncated()
    case_expired()
    case_second_use()
    case_timeout()
    case_hygiene()
    print()
    if FAILURES:
        print(f"FAIL — {len(FAILURES)} of {PASSED + len(FAILURES)} checks failed:")
        for name in FAILURES:
            print(f"  - {name}")
        return 1
    print(f"OK — all {PASSED} checks passed (Respond hold protocol v1)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
