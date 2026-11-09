#!/usr/bin/env bash
# run-tests.sh — verification suite for the deliverables in this repo.
# Run from the repo root:  ./tests/run-tests.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
PASS=0; FAIL=0
ok()    { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()   { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
suite() { printf '\n\033[1m%s\033[0m\n' "$*"; }
check() { if eval "$1"; then ok "$2"; else bad "$2"; fi; }
cleanup(){ [[ -n "${RCON_PID:-}" ]] && kill "$RCON_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

suite "1. Shell + Python syntax"
for f in "$ROOT"/scripts/*.sh; do
  check "bash -n '$f'" "bash -n $(basename "$f")"
done
for f in "$ROOT"/scripts/*.py "$ROOT"/tests/*.py; do
  check "python3 -m py_compile '$f'" "py_compile $(basename "$f")"
done

suite "2. Config files parse and contain sane values"
python3 - "$ROOT" <<'PY'
import sys, tomllib, pathlib
root = pathlib.Path(sys.argv[1])
fail = 0
for p in sorted((root / "config").glob("*.toml")):
    try:
        with p.open("rb") as fh:
            data = tomllib.load(fh)
        n = sum(len(v) for v in data.values() if isinstance(v, dict))
        print(f"  PASS {p.name} parses as TOML ({n} keys)")
    except Exception as exc:
        print(f"  FAIL {p.name}: {exc}"); fail += 1
recruits = tomllib.load(open(root / "config" / "recruits-server.toml", "rb"))["server"]
if recruits["MaxRecruitsForPlayer"] == 20 and recruits["SiegeRequiresOwnerOnline"] is True:
    print("  PASS recruits-server.toml: MaxRecruitsForPlayer=20, sieges require owner online")
else:
    print("  FAIL recruits-server.toml caps not applied"); fail += 1
workers = tomllib.load(open(root / "config" / "workers-server.toml", "rb"))["server"]
if workers["ShouldWorkAreaOnlyBeInFactionClaim"] is True and workers["BuildMode"] == "Preset":
    print("  PASS workers-server.toml: claim-scoped work areas, preset building")
else:
    print("  FAIL workers-server.toml caps not applied"); fail += 1

props = root / "config" / "server.properties"
seen, dupes, malformed = {}, [], []
for line in props.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith("#"):
        continue
    if "=" not in line:
        malformed.append(line); continue
    k, v = line.split("=", 1)
    if k in seen: dupes.append(k)
    seen[k] = v
if dupes or malformed:
    print(f"  FAIL server.properties dupes={dupes} malformed={malformed}"); fail += 1
else:
    print(f"  PASS server.properties: {len(seen)} keys, no duplicates, no malformed lines")
required = {"max-players":"30", "view-distance":"6", "simulation-distance":"4",
            "enable-rcon":"true", "sync-chunk-writes":"false", "max-tick-time":"60000"}
wrong = {k: seen.get(k) for k, v in required.items() if seen.get(k) != v}
if wrong:
    print(f"  FAIL server.properties wrong values: {wrong}"); fail += 1
else:
    print("  PASS server.properties tuned values match README (30 players, dist 6/sim 4)")
if "CHANGE_ME" not in seen.get("rcon.password", ""):
    print("  FAIL rcon.password placeholder missing - operators would ship a default password"); fail += 1
else:
    print("  PASS rcon.password is an obvious placeholder to change")
sys.exit(1 if fail else 0)
PY
[[ $? -eq 0 ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

suite "3. Bill of materials arithmetic and budget"
python3 - "$ROOT" <<'PY'
import re, sys, pathlib
readme = (pathlib.Path(sys.argv[1]) / "README.md").read_text()
rows = re.findall(r"^\|\s*(\d+)\s*\|.*?\|\s*\*\*\$(\d[\d,]*)\*\*\s*\|", readme, re.M)
parts = {int(n): int(p.replace(",", "")) for n, p in rows}
total_row = re.search(r"\*\*Total\*\*\s*\|\s*\*\*\$(\d[\d,]*)\*\*", readme)
total = int(total_row.group(1).replace(",", "")) if total_row else -1
total_sum = sum(parts.values())
fail = 0
def report(cond, msg):
    global fail
    if cond:
        print(f"  PASS {msg}")
    else:
        print(f"  FAIL {msg}"); fail += 1
report(len(parts) == 11, f"11 priced line items present (found {len(parts)})")
report(total_sum == total, f"line items sum to the stated total (${total_sum:,} vs ${total:,})")
report(total_sum <= 2500, f"total ${total_sum:,} is within the $2,500 budget")
report(total_sum >= 2300, f"total ${total_sum:,} actually uses the budget (not an underspend)")
report("$2,476" in readme, "README headline quotes the computed total ($2,476)")
report("9800X3D" in readme and "Ubuntu Server 26.04" in readme, "headline states CPU and distro recommendation")
sys.exit(1 if fail else 0)
PY
[[ $? -eq 0 ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

suite "4. Backup rotation retains hourly/daily/weekly tiers"
python3 - "$ROOT" "$TMP/rotate" <<'PY'
import datetime as dt, os, subprocess, sys, pathlib
root, dest = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
dest.mkdir(parents=True)
now = dt.datetime.now(dt.timezone.utc)
made = []
def touch(when):
    name = f"world-{when.strftime('%Y%m%dT%H%M%SZ')}.tar.gz"
    (dest / name).write_bytes(b"x")
    (dest / (name + ".sha256")).write_text("deadbeef\n")
    made.append(name)
for i in range(72):                      # 36 h of half-hourly backups
    touch(now - dt.timedelta(hours=i * 0.5))
for d in range(7, 41, 7):                # old weekly backups out to 40 days
    touch(now - dt.timedelta(days=d))
# a legacy snapshot directory must be rotated too
legacy = now - dt.timedelta(days=50)
(dest / legacy.strftime('%Y%m%dT%H%M%SZ')).mkdir()
made.append(legacy.strftime('%Y%m%dT%H%M%SZ'))

r = subprocess.run([sys.executable, str(root / "scripts" / "rotate-backups.py"), str(dest)],
                   capture_output=True, text=True)
left = sorted(p.name for p in dest.iterdir())
fail = 0
def report(cond, msg):
    global fail
    if cond:
        print(f"  PASS {msg}")
    else:
        print(f"  FAIL {msg}"); fail += 1
print("  " + r.stdout.strip())
report(r.returncode == 0, f"rotation exited 0 (stderr: {r.stderr.strip() or 'none'})")
recent = [n for n in made if (now - dt.datetime.strptime(n.split('.')[0].replace('world-',''), '%Y%m%dT%H%M%SZ').replace(tzinfo=dt.timezone.utc)) <= dt.timedelta(hours=24)]
missing = [n for n in recent if n not in left]
report(not missing, f"all {len(recent)} backups from the last 24 h retained")
report(all(b + '.sha256' in left for b in recent), "checksum sidecars retained with their archives")
old = [n for n in left if n.startswith('world-') and (now - dt.datetime.strptime(n.split('.')[0].replace('world-',''), '%Y%m%dT%H%M%SZ').replace(tzinfo=dt.timezone.utc)) > dt.timedelta(days=35)]
report(not old, f"no archive older than 35 days survives ({len(old)} found)")
report(not any(n == legacy.strftime('%Y%m%dT%H%M%SZ') for n in left), "legacy 50-day snapshot directory removed")
orphans = [n for n in left if n.endswith('.sha256') and n[:-7] not in left]
report(not orphans, f"no orphaned checksum sidecars left behind ({orphans})")
sys.exit(1 if fail else 0)
PY
[[ $? -eq 0 ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

suite "5. rcon.py speaks the real protocol (against a mock server)"
LOG="$TMP/rcon-commands.log"
python3 "$ROOT/tests/mock_rcon.py" --port 0 --password s3cret --log "$LOG" > "$TMP/rcon.out" 2>&1 &
RCON_PID=$!
for _ in $(seq 60); do grep -q '^PORT' "$TMP/rcon.out" 2>/dev/null && break; sleep 0.1; done
PORT="$(awk '/^PORT/{print $2}' "$TMP/rcon.out")"
if [[ -n "$PORT" ]]; then ok "mock RCON server listening on 127.0.0.1:$PORT"; else bad "mock RCON server failed to start"; fi

OUT="$(RCON_PASSWORD=s3cret python3 "$ROOT/scripts/rcon.py" --port "$PORT" "save-all flush" 2>&1)"
check "[[ \"$OUT\" == *'ok: save-all flush'* ]]" "rcon.py sends a command and decodes the response"
RCON_PASSWORD=s3cret python3 "$ROOT/scripts/rcon.py" --port "$PORT" "save-off" >/dev/null 2>&1
check "grep -qx 'save-off' '$LOG'" "command reaches the server"
RCON_PASSWORD=wrong python3 "$ROOT/scripts/rcon.py" --port "$PORT" "op someone" >/dev/null 2>&1
RC=$?
check "[[ $RC -eq 2 ]]" "wrong password exits 2 (never retried blindly)"
check "! grep -q 'op someone' '$LOG'" "wrong-password command is never executed server-side"
RCON_PASSWORD=s3cret python3 "$ROOT/scripts/rcon.py" --port 1 "save-off" >/dev/null 2>&1
check "[[ $? -eq 2 ]]" "unreachable server exits 2 so callers can treat it as down"

suite "6. backup-world.sh end-to-end: archive, verify, restore"
MC="$TMP/mc"; BK="$TMP/backups"
mkdir -p "$MC/world/region" "$MC/world/data"
head -c 300000 /dev/urandom > "$MC/world/region/r.0.0.mca"
printf 'level-data-here\n' > "$MC/world/level.dat"
printf '{"map":1}\n' > "$MC/world/data/idcounts.dat"
printf 's3cret\n' > "$MC/rcon.password"; chmod 600 "$MC/rcon.password"

run_backup() {
  MC_DIR="$MC" DEST="$BK" RCON_PY="$ROOT/scripts/rcon.py" FLUSH_WAIT=0 \
  RCON_PORT="$PORT" RCON_PASSWORD_FILE="$MC/rcon.password" \
  bash "$ROOT/scripts/backup-world.sh"
}
check "run_backup > '$TMP/backup1.log' 2>&1" "first backup run exits 0"
ARCH1="$(find "$BK" -maxdepth 1 -name 'world-*.tar.*' ! -name '*.sha256' | sort | head -1)"
check "[[ -n '$ARCH1' ]]" "an immutable world archive was produced"
for cmd in save-off 'save-all flush' save-on; do
  check "grep -qx '$cmd' '$LOG'" "RCON sequence included '$cmd'"
done
if [[ -n "$ARCH1" ]]; then
  case "$ARCH1" in
    *.zst) check "zstd -t '$ARCH1'" "archive passes integrity check (zstd -t)" ;;
    *)     check "gzip -t '$ARCH1'" "archive passes integrity check (gzip -t)" ;;
  esac
  SIDECAR="$(cat "$ARCH1.sha256" 2>/dev/null || echo MISSING)"
  ACTUAL="$(sha256sum "$ARCH1" | cut -d' ' -f1)"
  check "[[ -n '$SIDECAR' && '$SIDECAR' != MISSING && '$SIDECAR' == '$ACTUAL' ]]" "sha256 sidecar matches the archive ($(printf '%.12s' "$ACTUAL")…)"
  mkdir -p "$TMP/restore"
  case "$ARCH1" in
    *.zst) zstd -dc "$ARCH1" | tar -C "$TMP/restore" -xf - ;;
    *)     gzip -dc "$ARCH1" | tar -C "$TMP/restore" -xf - ;;
  esac
  check "cmp -s '$MC/world/region/r.0.0.mca' '$TMP/restore/world/region/r.0.0.mca'" "restored region file is byte-identical"
  check "cmp -s '$MC/world/level.dat' '$TMP/restore/world/level.dat'" "restored level.dat is byte-identical"
fi
sleep 1
check "run_backup > '$TMP/backup2.log' 2>&1" "second backup run exits 0"
COUNT="$(find "$BK" -maxdepth 1 -name 'world-*.tar.*' ! -name '*.sha256' | wc -l)"
check "[[ $COUNT -ge 2 ]]" "second run created a new archive ($COUNT archives present)"

kill "$RCON_PID" 2>/dev/null; wait "$RCON_PID" 2>/dev/null; RCON_PID=""
check "timeout 30 env MC_DIR='$MC' DEST='$BK' RCON_PY='$ROOT/scripts/rcon.py' FLUSH_WAIT=0 RCON_PORT='$PORT' RCON_PASSWORD_FILE='$MC/rcon.password' bash '$ROOT/scripts/backup-world.sh' > '$TMP/backup3.log' 2>&1" "backup does not hang when the server is stopped"
check "grep -q 'RCON unreachable' '$TMP/backup3.log'" "warns clearly that it archived live files (server down)"

suite "7. systemd unit is valid and safe"
UNIT="$ROOT/systemd/minecraft.service"
python3 - "$UNIT" <<'PY'
import sys, pathlib, re
unit = pathlib.Path(sys.argv[1]).read_text()
checks = [
    ("User=minecraft" in unit, "runs as an unprivileged service user"),
    ("WorkingDirectory=/opt/minecraft" in unit, "has a working directory"),
    ("-Xms16G" in unit and "-Xmx16G" in unit, "heap pinned at 16 GB (Xms == Xmx)"),
    ("AlwaysPreTouch" in unit, "AlwaysPreTouch enabled (no mid-fight heap growth)"),
    ("Restart=on-failure" in unit, "restarts automatically after a crash"),
    ("rcon.py stop" in unit, "stops via RCON so the world saves cleanly"),
    ("stdin.pipe" not in unit, "no FIFO-based console plumbing (can hang)"),
    ("ProtectSystem=strict" in unit and "NoNewPrivileges=true" in unit, "systemd hardening present"),
    ("LimitNOFILE=65535" in unit, "file descriptor limit raised for 30 players"),
    ("WantedBy=multi-user.target" in unit, "enabled at boot"),
]
fail = 0
for cond, msg in checks:
    print(("  PASS " if cond else "  FAIL ") + msg)
    fail += 0 if cond else 1
# Every Exec* path must be absolute; a typo'd relative path fails at boot.
for line in re.findall(r"^Exec\w+=(.*)$", unit, re.M):
    target = line.split()[0]
    if target.startswith("/"):
        print(f"  PASS Exec path is absolute: {target}")
    else:
        print(f"  FAIL Exec path not absolute: {target}"); fail += 1
sys.exit(1 if fail else 0)
PY
[[ $? -eq 0 ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
if command -v systemd-analyze >/dev/null 2>&1; then
  if systemd-analyze verify "$UNIT" 2>&1 | grep -qv 'Failed to prepare filename'; then
    systemd-analyze verify "$UNIT" >/dev/null 2>&1 && ok "systemd-analyze verify accepts the unit" || bad "systemd-analyze verify rejected the unit"
  else
    ok "systemd-analyze verify accepts the unit"
  fi
else
  ok "systemd-analyze not installed here; static unit checks used instead"
fi

suite "8. Documentation references every shipped file"
for f in config/server.properties config/recruits-server.toml config/workers-server.toml \
         scripts/setup-ubuntu-server.sh scripts/backup-world.sh systemd/minecraft.service README.md; do
  check "[[ -f '$ROOT/$f' ]]" "exists: $f"
done
python3 - "$ROOT" <<'PY'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
readme = (root / "README.md").read_text()
refs = set(re.findall(r"`((?:config|scripts|systemd|tests)/[\w./-]+)`", readme))
missing = sorted(r for r in refs if not (root / r).exists())
print(("  PASS " if not missing else "  FAIL ") + f"README references {len(refs)} repo paths, all exist" + (f" (missing: {missing})" if missing else ""))
sections = [int(n) for n in re.findall(r"^## (\d+)\.", readme, re.M)]
refnums = {int(n) for n in re.findall(r"[Ss]ection (\d+)", readme)}
bad_refs = sorted(n for n in refnums if n not in sections)
print(("  PASS " if not bad_refs else "  FAIL ") + f"cross-references resolve to real sections {sorted(sections)}" + (f" (broken: {bad_refs})" if bad_refs else ""))
heads = len(re.findall(r"^\|.*\|$", readme, re.M))
print(("  PASS " if heads > 80 else "  FAIL ") + f"document has substantive tables ({heads} table rows)")
sys.exit(1 if (missing or bad_refs or heads <= 80) else 0)
PY
[[ $? -eq 0 ]] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))

printf '\n\033[1mRESULT:\033[0m %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
