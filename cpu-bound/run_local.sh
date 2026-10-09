#!/usr/bin/env bash
# Roda a app localmente (host) e faz um smoke test: /health, /work, coletor e k6 curto.
# Porta local 18001 (a 8001 do host é o forward NAT da VM).
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$APP_DIR/../vm/vmctl.sh"
source "$CONDA_ROOT/etc/profile.d/conda.sh"

ENV_NAME="$(sed -n 's/^name: *//p' "$APP_DIR/environment.yml")"
PORT="${PORT:-18001}"
QUERY="$(python3 -c 'import sys,re;print(re.search(r"^query:\s*(\S+)",open(sys.argv[1]).read(),re.M).group(1))' "$APP_DIR/load/demand.yaml")"
TMP="$(mktemp -d)"

conda env list | grep -q "^$ENV_NAME " || conda env create -q -f "$APP_DIR/environment.yml"
conda activate "$ENV_NAME"

cleanup() { kill "$APP_PID" "$COL_PID" 2>/dev/null || true; wait 2>/dev/null || true; rm -rf "$TMP"; }
trap cleanup EXIT

cd "$APP_DIR"
uvicorn app.main:app --host 127.0.0.1 --port "$PORT" --workers 2 --log-level warning &
APP_PID=$!
python metrics/collector.py --out "$TMP/metrics.csv" --match "uvicorn app.main:app" &
COL_PID=$!

for _ in $(seq 1 30); do curl -fs "http://127.0.0.1:$PORT/health" >/dev/null && break; sleep 0.5; done
echo "== /health";            curl -fsS "http://127.0.0.1:$PORT/health"; echo
echo "== /work?$QUERY";       curl -fsS "http://127.0.0.1:$PORT/work?$QUERY"; echo

echo "== k6: 5 req/s por 10s"
k6 run -q --no-color -e BASE_URL="http://127.0.0.1:$PORT" -e QUERY="$QUERY" -e RATE=5 \
    -e DURATION=10s -e SUMMARY="$TMP/summary.json" "$APP_DIR/load/k6_work.js" >/dev/null
python3 - "$TMP/summary.json" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))["metrics"]
d = m["http_req_duration"]["values"]
print(f"reqs={m['http_reqs']['values']['count']}  falhas={m['http_req_failed']['values']['rate']:.1%}  "
      f"p50={d['p(50)']:.1f}ms  p95={d['p(95)']:.1f}ms  p99={d['p(99)']:.1f}ms")
EOF

kill "$COL_PID"; wait "$COL_PID" 2>/dev/null || true
echo "== coletor: $(($(wc -l <"$TMP/metrics.csv") - 1)) amostras"
python3 - "$TMP/metrics.csv" <<'EOF'
import csv, sys
rows = list(csv.DictReader(open(sys.argv[1])))
print("   pico:", {k: max(float(r[k]) for r in rows) for k in ("cpu_pct", "app_nproc", "app_cpu_pct", "app_rss_mb")})
EOF
echo "OK"
