#!/usr/bin/env bash
# Calibração da cpu-bound.
#   ./calibrate.sh          mede e grava a proposta em calibration/proposal.json (não altera a configuração)
#   ./calibrate.sh --apply  grava o target_rps da proposta em load/demand.yaml
#
# 1. Cenário Super: tempo sem carga (1 req/s) e custo de CPU por requisição (2 taxas, 30% e 50% da capacidade estimada).
# 2. Carga-alvo = 70% da capacidade da Adequada (cenário do meio): target = 0,70 × vCPU_adequada / (CPU-s/req).
# 3. Validação na Adequada com a carga-alvo: p95 ≤ 2 × p50 sem carga; se falhar, reduz 10% (até 3 vezes).
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$APP_DIR/../vm/explib.sh"
CAL="$APP_DIR/calibration"
PROPOSAL="$CAL/proposal.json"
CALIB="$HOST_PY $REPO_ROOT/vm/calib.py"

if [[ "${1:-}" == "--apply" ]]; then
    [[ -f "$PROPOSAL" ]] || die "rode ./calibrate.sh antes"
    target=$("$HOST_PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["target_rps"])' "$PROPOSAL")
    sed -i "s/^target_rps:.*/target_rps: $target           # calibrate.sh $(date +%F)/" "$APP_DIR/load/demand.yaml"
    log "target_rps = $target gravado em load/demand.yaml"
    exit 0
fi

exp_config --calib
mkdir -p "$CAL"; rm -rf "$CAL/runs"
exec > >(tee "$CAL/calibrate.log") 2>&1
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"

mapfile -t SCEN < <(exp_scenarios)
read -r SUP_ID SUP_CPUS SUP_MEM SUP_BW SUP_EXTRA <<<"${SCEN[-1]}"
read -r ADQ_ID ADQ_CPUS ADQ_MEM ADQ_BW ADQ_EXTRA <<<"${SCEN[2]}"
ALL_CPUS="$(printf '%s\n' "${SCEN[@]}" | awk '{print $2}' | paste -sd' ')"

# calib_run <nome> <rate> <duração> [warm-up]
calib_run() {
    local name="$1" rate="$2" dur="$3" warm="${4:-0}" dir="$CAL/runs/$1"
    (( warm > 0 )) && run_k6 "$rate" "$warm"
    run_measure "$dir" "$rate" "$dur"
    "$HOST_PY" "$EXPTOOLS" meta --out "$dir/meta.json" --app "$APP_NAME" --scenario "calib-$name" \
        --level 0 --rep 1 --target-rps 0 --rate "$rate" --query "$QUERY" --duration "$dur" \
        --vm-config "$(vm_config_json)" --commit "$COMMIT" --t-start "$T_START" --t-end "$T_END" \
        --clock-offset "${CLOCK% *}" --clock-rtt "${CLOCK#* }" --host-metrics "$dir/host_metrics.csv"
    log "[$name] $rate req/s: $(k6_brief "$dir/k6_summary.json") | $(vm_brief "$dir/vm_metrics.csv")"
}
jget() { "$HOST_PY" -c 'import json,sys;print(json.loads(sys.argv[1])[sys.argv[2]])' "$1" "$2"; }

log "=== Calibração $APP_NAME ($QUERY)"
log "Super: $SUP_ID ($SUP_CPUS vCPU) | Adequada: $ADQ_ID ($ADQ_CPUS vCPU)"
apply_scenario "$SUP_CPUS" "$SUP_MEM" "$SUP_BW" "$SUP_EXTRA"

calib_run noload 1 30 5
S0=$(jget "$($CALIB measure "$CAL/runs/noload")" p50_ms)
CAP=$(echo "$SUP_CPUS * 1000 / $S0" | bc -l)
log "Tempo sem carga p50 = ${S0} ms → capacidade estimada do Super ≈ $(printf %.1f "$CAP") req/s"

R1=$(printf %.1f "$(echo "$CAP * 0.3" | bc -l)"); R2=$(printf %.1f "$(echo "$CAP * 0.5" | bc -l)")
calib_run cost30 "$R1" 40 10
calib_run cost50 "$R2" 40 10

PROP=$($CALIB propose-cpu --noload "$CAL/runs/noload" --cost "$CAL/runs/cost30" "$CAL/runs/cost50" \
        --adequada-vcpus "$ADQ_CPUS" --levels "$LEVELS" --scenarios "$ALL_CPUS")
TARGET=$(jget "$PROP" target_rps)
log "CPU-s/req = $(jget "$PROP" cpu_s_per_req) → carga-alvo proposta = $TARGET req/s (70% de $ADQ_CPUS vCPU)"

# validação na Adequada
apply_scenario "$ADQ_CPUS" "$ADQ_MEM" "$ADQ_BW" "$ADQ_EXTRA"
calib_run adequada-noload 1 20 5
LIMIT=$(echo "2 * $S0" | bc -l)
VALID=""
for try in 1 2 3; do
    calib_run "adequada-$try" "$TARGET" 60 15
    M=$($CALIB measure "$CAL/runs/adequada-$try")
    P95=$(jget "$M" p95_ms); UTIL=$(jget "$M" vm_util)
    if (( $(echo "$P95 <= $LIMIT" | bc -l) )); then
        VALID="adequada-$try"; log "Validação ok: p95 $(printf %.0f "$P95") ms ≤ $(printf %.0f "$LIMIT") ms, utilização $(printf %.0f "$(echo "$UTIL*100" | bc -l)")%"
        break
    fi
    log "p95 $(printf %.0f "$P95") ms > $(printf %.0f "$LIMIT") ms; reduzindo carga-alvo em 10%"
    TARGET=$(echo "scale=1; $TARGET * 0.9 / 1" | bc -l)
done

"$HOST_PY" - "$PROP" "$TARGET" "$CAL" "$VALID" "$PROPOSAL" "$QUERY" <<'EOF'
import json, sys, subprocess
prop, target, cal, valid, out, query = json.loads(sys.argv[1]), float(sys.argv[2]), *sys.argv[3:]
measure = lambda d: json.loads(subprocess.check_output([sys.executable, cal + "/../../vm/calib.py", "measure", f"{cal}/runs/{d}"]))
prop["query"] = query
prop["target_rps"] = target
prop["validated"] = bool(valid)
if valid:
    m = measure(valid)
    prop["validation"] = {k: round(m[k], 3) for k in ("rate_rps", "throughput_rps", "vm_util", "p50_ms", "p95_ms", "p99_ms", "failed_rate")}
prop["adequada_noload_p50_ms"] = round(measure("adequada-noload")["p50_ms"], 1)
c = prop["cpu_s_per_req"]
prop["predicted_util"] = {v: {lv: round(target * int(lv) / 100 * c / int(v), 2) for lv in lvs}
                          for v, lvs in prop["predicted_util"].items()}
json.dump(prop, open(out, "w"), indent=2)

print("\n================ PROPOSTA (não aplicada) ================")
print(f"Intensidade: {query}")
print(f"Tempo sem carga (Super):    p50 {prop['noload_p50_ms']} ms, p95 {prop['noload_p95_ms']} ms")
print(f"Tempo sem carga (Adequada): p50 {prop['adequada_noload_p50_ms']} ms")
for r in prop["cost_runs"]:
    print(f"  custo @ {r['rate_rps']} req/s: util VM {r['vm_util']:.0%}, {r['cpu_s_per_req']} CPU-s/req (app {r['app_cpu_s_per_req']})")
print(f"Custo médio: {c} CPU-s/req → {prop['capacity_rps_per_vcpu']} req/s por vCPU")
print(f"Adequada: {prop['adequada_vcpus']} vCPU | carga-alvo (100%): {target} req/s")
if valid:
    v = prop["validation"]
    print(f"Validação na Adequada: vazão {v['throughput_rps']:.1f} req/s, util {v['vm_util']:.0%}, "
          f"p50 {v['p50_ms']:.0f} / p95 {v['p95_ms']:.0f} / p99 {v['p99_ms']:.0f} ms (limite p95 {prop['p95_limit_ms']} ms)")
else:
    print("Validação FALHOU nas 3 tentativas")
print("\nUtilização prevista (ρ = taxa × custo / vCPU):")
lv = list(next(iter(prop["predicted_util"].values())).keys())
print("vCPU  " + "".join(f"{l:>7}%" for l in lv))
for v, row in prop["predicted_util"].items():
    print(f"{v:>4}  " + "".join(f"{row[l]:>8.2f}" for l in lv))
print(f"\nPara aplicar: ./calibrate.sh --apply")
EOF
