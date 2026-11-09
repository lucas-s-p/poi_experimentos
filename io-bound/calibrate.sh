#!/usr/bin/env bash
# Calibração da io-bound (vCPU e RAM fixos, varia o limite de banda do disco).
#   ./calibrate.sh            mede e grava a proposta em calibration/proposal.json (não altera a configuração)
#   ./calibrate.sh --summary  refaz o resumo a partir das rodadas já medidas (sem medir)
#   ./calibrate.sh --apply    grava target_rps (load/demand.yaml) e os limites de disco (provisioning.yaml)
#
#   ./calibrate.sh --resume   continua, reaproveitando as rodadas já medidas em calibration/runs
#
# CRITÉRIO PELO p50 (não p95, como nas outras apps): a latência do fsync no caminho VirtualBox → NVMe do host
# tem p95 ≈ 3–4 × p50 mesmo com uma requisição por vez (calibration/DIAGNOSTICO_fsync.md), então
# "p95 ≤ 2 × p50 sem carga" é inalcançável em qualquer carga. O p50 só sobe com fila. p95/p99 seguem reportados.
#
# 1. Disco sem limite: tempo sem carga (p50 de 60 requisições a 1 req/s) e carga-alvo = maior taxa candidata
#    (CANDIDATES) com MÉDIA do p50 de 3 rodadas de 60 s ≤ 2 × tempo sem carga. B = banda de disco
#    (leitura + escrita, MiB/s, medida na VM) na carga-alvo. O limite do VirtualBox vale para a soma.
# 2. Adequada = B / 0,70; validada na carga-alvo (3 rodadas, média do p50) contra 2 × a MEDIANA do tempo sem
#    carga das 6 medições (sem limite + 5 cenários). O tempo sem carga não depende do limite (o limitador do
#    VirtualBox libera uma rajada inicial; medido: 15,9–22,9 ms sem relação com a banda), então a mediana das
#    6 (~360 requisições) reduz o ruído de uma medição isolada de 60 requisições.
# 3. Sub = 60% de B, medido uma vez a 125% (sem critério de aprovação). Sub→Adequada = ponto médio.
# 4. Super = ~3 × Adequada (valor redondo), validado a 125%; Adequada→Super = ponto médio.
# 5. Tempo sem carga medido nos 5 cenários (calibration/noload.json): separa o efeito do limite no tempo de
#    serviço do efeito de fila (p95 ÷ tempo sem carga do mesmo cenário), usado na análise.
# Cada rodada: reset da VM (serviço, swap, caches, arquivos da app) → host ocioso → warm-up → medição.
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$APP_DIR/../vm/explib.sh"
CAL="$APP_DIR/calibration"
PROPOSAL="$CAL/proposal.json"
CALIB="$HOST_PY $REPO_ROOT/vm/calib.py"
UTIL_TARGET=0.70
SUB_FRACTION=0.60
SUPER_FACTOR=3
CANDIDATES="${CANDIDATES:-3 5 8 12}"   # req/s
NOLOAD_RATE=1
NOLOAD_S=60

jget() { "$HOST_PY" -c 'import json,sys
v=json.loads(sys.argv[1])
for k in sys.argv[2:]: v=v[int(k)] if isinstance(v,list) else v[k]
print(v)' "$@"; }
ceil_int() { "$HOST_PY" -c 'import math,sys;print(max(1, math.ceil(float(sys.argv[1]))))' "$1"; }
round_nice() { "$HOST_PY" -c 'import math,sys;v=float(sys.argv[1]);s=5 if v<100 else 10;print(int(math.ceil(v/s)*s))' "$1"; }

if [[ "${1:-}" == "--apply" ]]; then
    [[ -f "$PROPOSAL" ]] || die "rode ./calibrate.sh antes"
    P="$(cat "$PROPOSAL")"
    target=$(jget "$P" target_rps)
    sed -i "s/^target_rps:.*/target_rps: $target             # calibrate.sh $(date +%F)/" "$APP_DIR/load/demand.yaml"
    for id in s1-sub s2-sub-adeq s3-adequada s4-adeq-super s5-super; do
        bw=$(jget "$P" disk_bw "$id")
        sed -i -E "s/(\{id: $id, .*disk_bw: )[0-9]+M\}/\1${bw}M}/" "$APP_DIR/provisioning.yaml"
    done
    log "target_rps = $target e limites de disco gravados"; grep -E "target_rps|disk_bw" "$APP_DIR/load/demand.yaml" "$APP_DIR/provisioning.yaml"
    exit 0
fi

exp_config --calib
SUMMARY_ONLY=""; [[ "${1:-}" == "--summary" ]] && SUMMARY_ONLY=1
RESUME=""; [[ "${1:-}" == "--resume" ]] && RESUME=1
if [[ -z "$SUMMARY_ONLY" ]]; then
    mkdir -p "$CAL"; [[ -n "$RESUME" ]] || rm -rf "$CAL/runs"
    exec > >(tee -a "$CAL/calibrate.log") 2>&1
fi
COMMIT="$(repo_commit)"
read -r _ VCPUS RAM _ _ <<<"$(exp_scenarios | head -1)"

# calib_run <nome> <rate> <duração> [warm-up]: reset → host ocioso → [warm-up] → medição
calib_run() {
    local name="$1" rate="$2" dur="$3" warm="${4:-0}" dir="$CAL/runs/$1"
    if [[ -f "$dir/meta.json" ]]; then log "[$name] já medida; reaproveitando"; return 0; fi
    rm -rf "$dir"
    vm_reset_state
    host_wait_idle "calib $name" || exit 1
    run_measure "$dir" "$rate" "$dur" "$warm"
    "$HOST_PY" "$EXPTOOLS" meta --out "$dir/meta.json" --app "$APP_NAME" --scenario "calib-$name" \
        --level 0 --rep 1 --target-rps 0 --rate "$rate" --query "$QUERY" --duration "$dur" \
        --vm-config "$(vm_config_json)" --commit "$COMMIT" --t-start "$T_START" --t-end "$T_END" \
        --clock-offset "${CLOCK% *}" --clock-rtt "${CLOCK#* }" --host-metrics "$dir/host_metrics.csv" \
        --idle "$IDLE_JSON" --events "$dir/vm_events.json" --vm-metrics "$dir/vm_metrics.csv" \
        ${SWAP_AFTER_RESET:+--swap-after-reset "$SWAP_AFTER_RESET"}
    local ev; ev="$("$HOST_PY" "$EXPTOOLS" events "$dir/vm_events.json")"
    log "[$name] $rate req/s: $(k6_brief "$dir/k6_summary.json") | $(vm_brief "$dir/vm_metrics.csv")${ev:+ | EVENTOS: $ev}"
}
noload() {  # noload <cenário>: p50 de ~60 requisições a 1 req/s
    calib_run "noload-$1" "$NOLOAD_RATE" "$NOLOAD_S" 5
}
p50_of() { jget "$($CALIB measure "$CAL/runs/$1")" p50_ms; }

write_summary() {
"$HOST_PY" - "$CAL" "$PROPOSAL" "$QUERY" "$TARGET" "$B" "$SUB" "$S2" "$ADQ" "$S4" "$SUP" <<'EOF'
import json, subprocess, sys
cal, out, query = sys.argv[1], sys.argv[2], sys.argv[3]
target, B = float(sys.argv[4]), float(sys.argv[5]); sub, s2, adq, s4, sup = map(int, sys.argv[6:11])
measure = lambda d: json.loads(subprocess.check_output([sys.executable, cal + "/../../vm/calib.py", "measure", f"{cal}/runs/{d}"]))
search = json.load(open(f"{cal}/search.json"))
ids = {"s1-sub": sub, "s2-sub-adeq": s2, "s3-adequada": adq, "s4-adeq-super": s4, "s5-super": sup}
noload = {"sem-limite": measure("noload-sem-limite")}
noload.update({k: measure(f"noload-{k}") for k in ids})
nl = {k: {"p50_ms": round(v["p50_ms"], 1), "p95_ms": round(v["p95_ms"], 1), "reqs": v["reqs"]} for k, v in noload.items()}
json.dump(nl, open(f"{cal}/noload.json", "w"), indent=2)
pick = lambda m, ks: {k: (round(m[k], 3) if isinstance(m[k], float) else m[k]) for k in ks}
K = ("rate_rps", "throughput_rps", "p50_ms", "p95_ms", "p99_ms", "failed_rate", "dropped", "vm_util", "disk_mb_per_req",
     "oom_kills", "worker_deaths_healthcheck", "worker_deaths_oom")
def disk(d):
    meta = json.load(open(f"{cal}/runs/{d}/meta.json"))
    import pandas as pd
    v = pd.read_csv(f"{cal}/runs/{d}/vm_metrics.csv"); t = v.timestamp - meta["clock_offset_s"]
    w = v[(t >= meta["t_start"] + 1) & (t <= meta["t_end"])]
    return {"disk_mb_s": round(w.disk_read_mb_s.mean() + w.disk_write_mb_s.mean(), 2),
            "disk_util_pct": round(w.disk_util_pct.mean(), 1), "iowait_pct": round(w.cpu_iowait_pct.mean(), 1),
            "vm_disk_written_mb": (meta.get("vm_disk_written") or {}).get("with_warmup_mb")}
val = [dict(pick(measure(f"adequada-r{k}"), K), **disk(f"adequada-r{k}")) for k in (1, 2, 3)]
import statistics
noload_ref = statistics.median(v["p50_ms"] for v in noload.values())
adq_limit = 2 * noload_ref
mean_p95 = sum(v["p95_ms"] for v in val) / 3
mean_p50 = sum(v["p50_ms"] for v in val) / 3
subm = dict(pick(measure(f"sub-125"), K), **disk("sub-125"))
supm = dict(pick(measure(f"super-125"), K), **disk("super-125"))
prop = {
    "query": query, "search_noload_p50_ms": search["noload_p50_ms"], "search_p95_limit_ms": search["p95_limit_ms"],
    "search": search["search"], "target_rps": target, "disk_mb_s_at_target": round(B, 2),
    "disk_bw": ids, "noload_by_scenario": nl,
    "criterion": "média do p50 de 3 rodadas ≤ 2 × p50 sem carga (cauda do fsync impede o critério pelo p95); "
                 "na Adequada, p50 sem carga = mediana das 6 medições",
    "noload_reference_p50_ms": round(noload_ref, 1),
    "adequada_validation": val, "adequada_p50_limit_ms": round(adq_limit, 1),
    "adequada_mean_p50_ms": round(mean_p50, 1), "adequada_mean_p95_ms": round(mean_p95, 1),
    "adequada_ok": mean_p50 <= adq_limit,
    "sub_125pct": subm, "super_125pct": supm,
    "super_p50_over_noload": round(supm["p50_ms"] / noload["s5-super"]["p50_ms"], 2),
    "super_p95_over_noload": round(supm["p95_ms"] / noload["s5-super"]["p50_ms"], 2),
}
json.dump(prop, open(out, "w"), indent=2, default=lambda o: o.item())

print("\n================ PROPOSTA (não aplicada) ================")
print(f"Intensidade: {query}")
print(f"Critério: {prop['criterion']}")
print(f"Disco sem limite: tempo sem carga p50 {search['noload_p50_ms']} ms → limite (p50) {search['p95_limit_ms']} ms")
print(f"{'taxa':>6} {'p50 (r1/r2/r3)':>16} {'média p50':>9} {'p95 (r1/r2/r3)':>16} {'média p95':>9} {'disco MiB/s':>11} {'MiB/req':>8} {'em andamento':>12}  ok")
for r in search["search"]:
    print(f"{r['rate_rps']:>6} {'/'.join(map(str, r['p50_ms'])):>16} {r['mean_crit_ms']:>9} {'/'.join(map(str, r['p95_ms'])):>16} {r['mean_p95_ms']:>9} {r['disk_mb_s']:>11} {r['disk_mb_per_req']:>8} {r['inflight']:>12}  {'OK' if r['ok'] else '-'}")
print(f"\nCarga-alvo: {target} req/s | banda de disco na carga-alvo (B): {B:.1f} MiB/s")
print("Limites (MiB/s): " + ", ".join(f"{k} {v}" for k, v in ids.items()))
print("\nTempo sem carga por cenário (p50 / p95 de ~60 req a 1 req/s):")
for k, v in nl.items():
    print(f"  {k:14} {v['p50_ms']:7.1f} / {v['p95_ms']:7.1f} ms")
print(f"\nValidação da Adequada ({adq} MiB/s) a {target} req/s, limite (média do p50) = 2 × {noload_ref:.1f} "
      f"(mediana do tempo sem carga das 6 medições) = {adq_limit:.1f} ms:")
for k, m in enumerate(val, 1):
    print(f"  r{k}: vazão {m['throughput_rps']}, p50 {m['p50_ms']:.0f} / p95 {m['p95_ms']:.0f} / p99 {m['p99_ms']:.0f} ms, "
          f"disco {m['disk_mb_s']} MiB/s ({m['disk_mb_s']/adq:.0%} do limite), %util {m['disk_util_pct']}, iowait {m['iowait_pct']}%")
print(f"  média do p50 = {prop['adequada_mean_p50_ms']} ms → {'OK' if prop['adequada_ok'] else 'FALHA'} (média do p95 = {prop['adequada_mean_p95_ms']} ms, reportada)")
for name, m, lim in (("Sub", subm, sub), ("Super", supm, sup)):
    print(f"\n{name} ({lim} MiB/s) a 125% ({m['rate_rps']} req/s): vazão {m['throughput_rps']}, p50 {m['p50_ms']:.0f} / p95 {m['p95_ms']:.0f} / p99 {m['p99_ms']:.0f} ms, "
          f"falhas {m['failed_rate']:.1%}, descartadas {m['dropped']}, disco {m['disk_mb_s']} MiB/s ({m['disk_mb_s']/lim:.0%} do limite), "
          f"%util {m['disk_util_pct']}, iowait {m['iowait_pct']}%, mortes healthcheck/OOM {m['worker_deaths_healthcheck']}/{m['worker_deaths_oom']}")
print(f"Super a 125% ÷ tempo sem carga do Super: p50 {prop['super_p50_over_noload']}×, p95 {prop['super_p95_over_noload']}×")
print("\nPara aplicar: ./calibrate.sh --apply")
EOF
}

derive() {  # a partir de search.json: carga-alvo, B e os limites
    SEARCH="$(cat "$CAL/search.json")"
    [[ "$(jget "$SEARCH" target)" != "None" ]] || die "nenhuma taxa candidata cumpriu o critério; ver $CAL/search.json"
    TARGET=$(jget "$SEARCH" target rate_rps); B=$(jget "$SEARCH" target disk_mb_s)
    ADQ=$(ceil_int "$(echo "$B / $UTIL_TARGET" | bc -l)")
    SUB=$(ceil_int "$(echo "$B * $SUB_FRACTION" | bc -l)")
    S2=$(ceil_int "$(echo "($SUB + $ADQ) / 2" | bc -l)")
    SUP=$(round_nice "$(echo "$ADQ * $SUPER_FACTOR" | bc -l)")
    S4=$(ceil_int "$(echo "($ADQ + $SUP) / 2" | bc -l)")
    RATE125=$(printf %.2f "$(echo "$TARGET * 1.25" | bc -l)")
}

if [[ -n "$SUMMARY_ONLY" ]]; then derive; write_summary; exit 0; fi

log "=== Calibração $APP_NAME ($QUERY), $VCPUS vCPU, $RAM MB"
host_check_power || exit 1

# --- 1. Disco sem limite: tempo sem carga e carga-alvo -------------------------------------
apply_scenario "$VCPUS" "$RAM" - -
noload sem-limite
log "Busca da carga-alvo (disco sem limite): taxas $CANDIDATES req/s, 3 × 60 s cada"
for rate in $CANDIDATES; do
    for rep in 1 2 3; do calib_run "search-$rate-r$rep" "$rate" 60 "$WARMUP_S"; done
done
$CALIB mem-search --runs "$CAL/runs" --rates "$CANDIDATES" --reps 3 --noload noload-sem-limite --metric p50 >"$CAL/search.json"
derive
log "Carga-alvo = $TARGET req/s; banda B = $B MiB/s → Sub $SUB, Sub→Adeq $S2, Adequada $ADQ, Adeq→Super $S4, Super $SUP MiB/s"

# --- 2. Adequada ------------------------------------------------------------------------------
apply_scenario "$VCPUS" "$RAM" "${ADQ}M" -
noload s3-adequada
for rep in 1 2 3; do calib_run "adequada-r$rep" "$TARGET" 60 "$WARMUP_S"; done
# --- 3. Sub ---------------------------------------------------------------------------------------
apply_scenario "$VCPUS" "$RAM" "${SUB}M" -
noload s1-sub
calib_run sub-125 "$RATE125" 60 "$WARMUP_S"
# --- 4. Intermediários (só tempo sem carga) ---------------------------------------------------------
apply_scenario "$VCPUS" "$RAM" "${S2}M" -;  noload s2-sub-adeq
apply_scenario "$VCPUS" "$RAM" "${S4}M" -;  noload s4-adeq-super
# --- 5. Super finito ------------------------------------------------------------------------------
apply_scenario "$VCPUS" "$RAM" "${SUP}M" -
noload s5-super
calib_run super-125 "$RATE125" 60 "$WARMUP_S"

write_summary
