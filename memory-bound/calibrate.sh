#!/usr/bin/env bash
# Calibração da memory-bound (vCPU fixo, varia RAM).
#   ./calibrate.sh          mede e grava a proposta em calibration/proposal.json (não altera a configuração)
#   ./calibrate.sh --summary  refaz o resumo/proposal.json a partir das rodadas já medidas (sem medir)
#   ./calibrate.sh --apply  grava target_rps (load/demand.yaml) e a RAM dos cenários 1-4 (provisioning.yaml)
#
# 1. Super: tempo sem carga (p50 a 0,5 req/s) e custo de CPU por requisição (2 taxas).
# 2. Super: carga-alvo = maior taxa candidata (CANDIDATES, escolhidas por concorrência: ~6, 8 e 10
#    requisições em andamento de 16 vagas) cuja MÉDIA do p95 em 3 rodadas de 60 s fica ≤ 2 × tempo sem
#    carga (mesmo critério da cpu-bound). WS = pico de memória usada a essa taxa: p95 das amostras de 1 s
#    de MemTotal − MemAvailable (sem page cache); a RSS dos workers é reportada junto.
# 3. Adequada = WS / 0,70 (memória ~70% ocupada na carga-alvo), múltiplo de 128 MB.
#    Sub = ~60% de WS (força swap perto da carga-alvo), medido uma vez a 125% da carga para mostrar a
#    pressão de memória (swap, falhas major, OOM, workers mortos). Sem critério de aprovação: o colapso
#    em sobrecarga é o resultado esperado. Intermediários = pontos médios.
# 4. Valida a Adequada na carga-alvo (3 rodadas): média do p95 ≤ limite e swap desprezível.
# Antes de cada rodada espera o host ficar ocioso (host_wait_idle).
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$APP_DIR/../vm/explib.sh"
CAL="$APP_DIR/calibration"
PROPOSAL="$CAL/proposal.json"
CALIB="$HOST_PY $REPO_ROOT/vm/calib.py"
UTIL_TARGET=0.70
SUB_FRACTION=0.60
CANDIDATES="${CANDIDATES:-14 18 22}"   # req/s

jget() { "$HOST_PY" -c 'import json,sys
v=json.loads(sys.argv[1])
for k in sys.argv[2:]: v=v[int(k)] if isinstance(v,list) else v[k]
print(v)' "$@"; }
round128() { "$HOST_PY" -c 'import math,sys;print(max(512, math.ceil(float(sys.argv[1])/128)*128))' "$1"; }

if [[ "${1:-}" == "--apply" ]]; then
    [[ -f "$PROPOSAL" ]] || die "rode ./calibrate.sh antes"
    P="$(cat "$PROPOSAL")"
    target=$(jget "$P" target_rps)
    sed -i "s/^target_rps:.*/target_rps: $target             # calibrate.sh $(date +%F)/" "$APP_DIR/load/demand.yaml"
    for id in s1-sub s2-sub-adeq s3-adequada s4-adeq-super; do
        ram=$(jget "$P" ram_mb "$id")
        sed -i -E "s/(\{id: $id, .*ram_mb: )[0-9]+\}/\1$ram}/" "$APP_DIR/provisioning.yaml"
    done
    log "target_rps = $target e RAM dos cenários gravados"; grep -E "target_rps|ram_mb" "$APP_DIR/load/demand.yaml" "$APP_DIR/provisioning.yaml"
    exit 0
fi

exp_config --calib
SUMMARY_ONLY=""; [[ "${1:-}" == "--summary" ]] && SUMMARY_ONLY=1
if [[ -z "$SUMMARY_ONLY" ]]; then
    mkdir -p "$CAL"; rm -rf "$CAL/runs"
    exec > >(tee "$CAL/calibrate.log") 2>&1
fi
COMMIT="$(repo_commit)"

mapfile -t SCEN < <(exp_scenarios)
read -r SUP_ID SUP_CPUS SUP_MEM _ _ <<<"${SCEN[-1]}"
VCPUS="$SUP_CPUS"

# calib_run <nome> <rate> <duração> [warm-up]
calib_run() {
    local name="$1" rate="$2" dur="$3" warm="${4:-0}" dir="$CAL/runs/$1"
    host_wait_idle "calib $name" || exit 1
    (( warm > 0 )) && run_k6 "$rate" "$warm"
    run_measure "$dir" "$rate" "$dur"
    "$HOST_PY" "$EXPTOOLS" meta --out "$dir/meta.json" --app "$APP_NAME" --scenario "calib-$name" \
        --level 0 --rep 1 --target-rps 0 --rate "$rate" --query "$QUERY" --duration "$dur" \
        --vm-config "$(vm_config_json)" --commit "$COMMIT" --t-start "$T_START" --t-end "$T_END" \
        --clock-offset "${CLOCK% *}" --clock-rtt "${CLOCK#* }" --host-metrics "$dir/host_metrics.csv" \
        --idle "$IDLE_JSON" --events "$dir/vm_events.json"
    local ev; ev="$("$HOST_PY" "$EXPTOOLS" events "$dir/vm_events.json")"
    log "[$name] $rate req/s: $(k6_brief "$dir/k6_summary.json") | $(vm_brief "$dir/vm_metrics.csv")${ev:+ | EVENTOS: $ev}"
}

write_summary() {
"$HOST_PY" - "$CAL" "$PROPOSAL" "$SEARCH" "$TARGET" "$SUB" "$S2" "$ADQ" "$S4" "$SUP_MEM" "$C" "$QUERY" <<'EOF'
import json, subprocess, sys
cal, out, search = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
target = float(sys.argv[4]); sub, s2, adq, s4, sup = map(int, sys.argv[5:10]); c = float(sys.argv[10])
query = sys.argv[11]
measure = lambda d: json.loads(subprocess.check_output([sys.executable, cal + "/../../vm/calib.py", "measure", f"{cal}/runs/{d}"]))
noload = measure("noload")
val = [measure(f"adequada-r{k}") for k in (1, 2, 3)]
subm = measure(f"sub-{sub}")
limit = search["p95_limit_ms"]
mean_p95 = sum(m["p95_ms"] for m in val) / 3
prop = {
    "query": query, "noload_p50_ms": search["noload_p50_ms"], "noload_p95_ms": round(noload["p95_ms"], 1),
    "p95_limit_ms": limit, "cpu_s_per_req": round(c, 4), "search": search["search"],
    "target_rps": target, "working_set_mb": search["target"]["mem_used_p95_mb"],
    "ram_mb": {"s1-sub": sub, "s2-sub-adeq": s2, "s3-adequada": adq, "s4-adeq-super": s4, "s5-super": sup},
    "sub_check_125pct": {k: round(subm[k], 2) if isinstance(subm[k], float) else subm[k]
                         for k in ("rate_rps", "throughput_rps", "p50_ms", "p95_ms", "p99_ms", "mem_used_p95_mb",
                                   "mem_total_mb", "app_rss_p95_mb", "swap_used_max_mb", "pswpin_pg_s", "pswpout_pg_s",
                                   "pgmajfault_s", "oom_kills", "worker_deaths", "worker_deaths_healthcheck", "worker_deaths_oom",
                                   "dropped", "failed_rate")},
    "adequada_validation": [{k: round(m[k], 2) if isinstance(m[k], float) else m[k]
                             for k in ("throughput_rps", "vm_util", "p50_ms", "p95_ms", "p99_ms", "mem_used_p95_mb",
                                       "mem_total_mb", "swap_io_pg_s", "oom_kills", "dropped")} for m in val],
    "adequada_mean_p95_ms": round(mean_p95, 1), "adequada_ok": mean_p95 <= limit,
}
json.dump(prop, open(out, "w"), indent=2, default=lambda o: o.item())

print("\n================ PROPOSTA (não aplicada) ================")
print(f"Intensidade: {query} | tempo sem carga p50 {prop['noload_p50_ms']} ms (p95 {prop['noload_p95_ms']}) → limite p95 {limit} ms")
print(f"CPU-s/req {prop['cpu_s_per_req']}")
print("\nBusca da carga-alvo no Super (3 × 60 s por taxa):")
print(f"{'taxa':>6} {'p95 (r1/r2/r3)':>18} {'média':>6} {'util':>5} {'mem usada p95':>13} {'RSS app p95':>11} {'em andamento':>12}  ok")
for r in search["search"]:
    print(f"{r['rate_rps']:>6} {'/'.join(map(str, r['p95_ms'])):>18} {r['mean_p95_ms']:>6} {r['vm_util']:>5.0%} "
          f"{r['mem_used_p95_mb']:>10} MB {r['app_rss_p95_mb']:>8} MB {r['inflight']:>12}  {'OK' if r['ok'] else '-'}")
print(f"\nCarga-alvo: {target} req/s | memória usada na carga-alvo (WS, MemTotal−MemAvailable p95): {prop['working_set_mb']} MB "
      f"| RSS dos workers p95: {search['target']['app_rss_p95_mb']} MB")
print("RAM proposta: " + ", ".join(f"{k} {v} MB" for k, v in prop["ram_mb"].items()))
s = prop["sub_check_125pct"]
print(f"\nSub ({sub} MB) a 125% ({s['rate_rps']} req/s): vazão {s['throughput_rps']} req/s, "
      f"p50 {s['p50_ms']:.0f} / p95 {s['p95_ms']:.0f} / p99 {s['p99_ms']:.0f} ms, falhas {s['failed_rate']:.1%}, descartadas {s['dropped']}")
print(f"   memória usada p95 {s['mem_used_p95_mb']:.0f}/{s['mem_total_mb']:.0f} MB, RSS app p95 {s['app_rss_p95_mb']:.0f} MB, "
      f"swap usado (máx) {s['swap_used_max_mb']:.0f} MB")
print(f"   pswpin {s['pswpin_pg_s']:.0f} pág/s, pswpout {s['pswpout_pg_s']:.0f} pág/s, falhas de página major {s['pgmajfault_s']:.0f}/s, "
      f"OOM kills {s['oom_kills']}, workers mortos {s['worker_deaths']} "
      f"(healthcheck {s['worker_deaths_healthcheck']}, OOM {s['worker_deaths_oom']})")
print(f"\nValidação da Adequada ({adq} MB) a {target} req/s:")
for k, m in enumerate(prop["adequada_validation"], 1):
    print(f"  r{k}: vazão {m['throughput_rps']}, util CPU {m['vm_util']:.0%}, p50 {m['p50_ms']:.0f} / p95 {m['p95_ms']:.0f} / p99 {m['p99_ms']:.0f} ms, "
          f"mem {m['mem_used_p95_mb']:.0f}/{m['mem_total_mb']:.0f} MB ({m['mem_used_p95_mb']/m['mem_total_mb']:.0%}), swap {m['swap_io_pg_s']:.0f} pág/s, OOM {m['oom_kills']}")
print(f"  média do p95 = {prop['adequada_mean_p95_ms']} ms → {'OK' if prop['adequada_ok'] else 'FALHA'} (limite {limit} ms)")
print("\nPara aplicar: ./calibrate.sh --apply")
EOF
}

cost_mean() { "$HOST_PY" -c 'import json,sys,subprocess
ms=[json.loads(subprocess.check_output([sys.executable,sys.argv[1],"measure",d])) for d in sys.argv[2:]]
print(sum(m["cpu_s_per_req"] for m in ms)/len(ms))' "$REPO_ROOT/vm/calib.py" "$CAL/runs/cost5" "$CAL/runs/cost10"; }

if [[ -n "$SUMMARY_ONLY" ]]; then
    SEARCH="$(cat "$CAL/search.json")"
    TARGET=$(jget "$SEARCH" target rate_rps); WS=$(jget "$SEARCH" target mem_used_p95_mb)
    ADQ=$(round128 "$(echo "$WS / $UTIL_TARGET" | bc -l)")
    SUB=$(round128 "$(echo "$WS * $SUB_FRACTION" | bc -l)")
    S2=$(round128 "$(echo "($SUB + $ADQ) / 2" | bc -l)")
    S4=$(round128 "$(echo "($ADQ + $SUP_MEM) / 2" | bc -l)")
    C=$(cost_mean)
    [[ -d "$CAL/runs/sub-$SUB" ]] || die "rodada do Sub ($SUB MB) não encontrada em $CAL/runs"
    write_summary
    exit 0
fi

log "=== Calibração $APP_NAME ($QUERY), $VCPUS vCPU"
host_check_power || exit 1

# --- 1-2. Super ------------------------------------------------------------------
log "Super: $SUP_ID ($SUP_MEM MB)"
apply_scenario "$VCPUS" "$SUP_MEM" - -
calib_run noload 0.5 60 10
S0=$(jget "$($CALIB measure "$CAL/runs/noload")" p50_ms)
log "Tempo sem carga p50 = $(printf %.0f "$S0") ms → limite p95 = $(printf %.0f "$(echo "2 * $S0" | bc -l)") ms"
calib_run cost5 5 40 10
calib_run cost10 10 40 10
C=$(cost_mean)
CAPC=$(echo "$VCPUS / $C" | bc -l)
log "CPU-s/req = $(printf %.3f "$C") → capacidade de CPU ≈ $(printf %.2f "$CAPC") req/s"

RATES="$CANDIDATES"
log "Busca da carga-alvo no Super: taxas $RATES req/s, 3 × 60 s cada"
for rate in $RATES; do
    for rep in 1 2 3; do
        warm=0; (( rep == 1 )) && warm="$WARMUP_S"
        calib_run "search-$rate-r$rep" "$rate" 60 "$warm"
    done
done
SEARCH=$($CALIB mem-search --runs "$CAL/runs" --rates "$RATES" --reps 3)
echo "$SEARCH" >"$CAL/search.json"
[[ "$(jget "$SEARCH" target)" != "None" ]] || die "nenhuma taxa candidata cumpriu o critério; ver $CAL/search.json"
TARGET=$(jget "$SEARCH" target rate_rps); WS=$(jget "$SEARCH" target mem_used_p95_mb)
LIMIT=$(jget "$SEARCH" p95_limit_ms)
ADQ=$(round128 "$(echo "$WS / $UTIL_TARGET" | bc -l)")
SUB=$(round128 "$(echo "$WS * $SUB_FRACTION" | bc -l)")
log "Carga-alvo = $TARGET req/s; pico de memória usada (WS) = $WS MB → Adequada = $ADQ MB, Sub inicial = $SUB MB"

# --- 3. Sub a 125% (pressão de memória; sem critério de aprovação) -----------------------
RATE125=$(printf %.2f "$(echo "$TARGET * 1.25" | bc -l)")
log "Sub: $SUB MB, a 125% ($RATE125 req/s)"
apply_scenario "$VCPUS" "$SUB" - -
calib_run "sub-$SUB" "$RATE125" 60 "$WARMUP_S"
S2=$(round128 "$(echo "($SUB + $ADQ) / 2" | bc -l)")
S4=$(round128 "$(echo "($ADQ + $SUP_MEM) / 2" | bc -l)")

# --- 4. Validação da Adequada ------------------------------------------------------------
log "Validação da Adequada: $ADQ MB a $TARGET req/s, 3 × 60 s"
apply_scenario "$VCPUS" "$ADQ" - -
for rep in 1 2 3; do
    warm=0; (( rep == 1 )) && warm="$WARMUP_S"
    calib_run "adequada-r$rep" "$TARGET" 60 "$warm"
done

write_summary
