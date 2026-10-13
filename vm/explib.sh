# Funções de experimento compartilhadas pelas 3 apps (deploy, coleta, k6, meta.json).
# Uso: APP_DIR=<dir da app>; source vm/explib.sh

source "$(dirname "${BASH_SOURCE[0]}")/vmctl.sh"
source "$CONDA_ROOT/etc/profile.d/conda.sh"

HOST_PY="$CONDA_ROOT/envs/poi-analysis/bin/python"
EXPTOOLS="$REPO_ROOT/vm/exptools.py"
[[ -x "$HOST_PY" ]] || die "env poi-analysis ausente: conda env create -f $APP_DIR/analysis/environment.yml"
command -v k6 >/dev/null || die "k6 não encontrado no PATH"

ENV_NAME="$(sed -n 's/^name: *//p' "$APP_DIR/environment.yml")"
APP_NAME="$(basename "$APP_DIR")"
REMOTE_DIR="poi/$APP_NAME"                         # relativo ao home do usuário da VM
REMOTE_PY="\$HOME/miniforge3/envs/$ENV_NAME/bin/python"
APP_MATCH="uvicorn app.main:app"

# exp_config [--quick]: carrega app/porta/demanda (APP SERVICE PORT QUERY TARGET_RPS LEVELS ...)
exp_config() {
    local cfg
    cfg="$("$HOST_PY" "$EXPTOOLS" config "$APP_DIR/provisioning.yaml" "$APP_DIR/load/demand.yaml" "$@")"
    eval "$cfg"
    BASE_URL="http://127.0.0.1:$PORT"
}

# Lista de cenários: "id vcpus ram_mb disk_bw unit_extra"
exp_scenarios() { "$HOST_PY" "$EXPTOOLS" scenarios "$APP_DIR/provisioning.yaml" "$@"; }

# deploy_app [unit_extra]: rsync do código, conda env (só se environment.yml mudou), unit systemd, /health.
# unit_extra: diretivas adicionais para [Service], separadas por \x1f (usado no io-bound).
deploy_app() {
    local extra="${1:--}"
    log "Deploy de $APP_NAME"
    vm_ssh "mkdir -p $REMOTE_DIR"
    vm_rsync "$APP_DIR/app" "$APP_DIR/metrics" "$APP_DIR/environment.yml" "$REMOTE_DIR/"
    vm_ssh "bash -s" <<EOF
set -euo pipefail
cd $REMOTE_DIR
h=\$(sha256sum environment.yml | cut -c1-16)
if [[ "\$(cat .env_hash 2>/dev/null)" != "\$h" ]]; then
    ~/miniforge3/bin/conda env update -q -n $ENV_NAME -f environment.yml --prune >/dev/null 2>&1 \
        || ~/miniforge3/bin/conda env create -q -n $ENV_NAME -f environment.yml >/dev/null
    echo "\$h" > .env_hash
fi
EOF
    local extra_lines=""
    [[ "$extra" != "-" ]] && extra_lines="$(tr '\037' '\n' <<<"$extra")"
    vm_ssh "sudo tee /etc/systemd/system/$SERVICE.service >/dev/null" <<EOF
[Unit]
Description=POI $APP_NAME
After=network.target

[Service]
User=$VM_USER
WorkingDirectory=/home/$VM_USER/$REMOTE_DIR
# um worker por vCPU (GIL)
ExecStart=/bin/sh -c 'exec /home/$VM_USER/miniforge3/envs/$ENV_NAME/bin/uvicorn app.main:app --host 0.0.0.0 --port $PORT --workers \$(nproc) --no-access-log --log-level warning'
Restart=always
RestartSec=1
$extra_lines

[Install]
WantedBy=multi-user.target
EOF
    vm_ssh "sudo systemctl daemon-reload && sudo systemctl enable -q $SERVICE && sudo systemctl restart $SERVICE"
    local i
    for i in $(seq 1 60); do
        curl -fs "$BASE_URL/health" >/dev/null && { log "/health ok ($(curl -fs "$BASE_URL/health"))"; return 0; }
        sleep 1
    done
    vm_ssh "sudo journalctl -u $SERVICE -n 30 --no-pager" >&2 || true
    die "/health não respondeu em 60s"
}

# apply_scenario <vcpus> <ram_mb> <disk_bw|-> <unit_extra|->: desliga, checa RAM do host, aplica, liga, deploy.
apply_scenario() {
    local cpus="$1" mem="$2" bw="$3" extra="$4"
    [[ "$bw" == "-" ]] && bw=""
    vm_stop
    host_check_ram "$mem" || exit 1
    vm_set_resources "$cpus" "$mem" "$bw"
    vm_start
    vm_wait_ssh 180 || die "SSH não respondeu"
    deploy_app "$extra"
}

# clock_offset: "offset rtt" (s), offset = VM - host; melhor de 5 amostras (menor RTT)
clock_offset() {
    local best_rtt=999 best_off=0 t0 tv t1 rtt i
    for i in 1 2 3 4 5; do
        t0=$(date +%s.%N); tv=$(vm_ssh 'date +%s.%N'); t1=$(date +%s.%N)
        rtt=$(echo "$t1 - $t0" | bc -l)
        if (( $(echo "$rtt < $best_rtt" | bc -l) )); then
            best_rtt=$rtt; best_off=$(echo "$tv - ($t0 + $t1) / 2" | bc -l)
        fi
    done
    printf '%.6f %.6f\n' "$best_off" "$best_rtt"
}

# run_k6 <rate> <duração_s> [summary.json] [raw.csv.gz]: k6 fixado em K6_CPUSET
run_k6() {
    local rate="$1" dur="$2" summary="${3:-}" raw="${4:-}"
    local outs=()
    [[ -n "$raw" ]] && outs=(--out "csv=$raw")
    taskset -c "$K6_CPUSET" k6 run -q --no-color --no-usage-report "${outs[@]}" \
        -e BASE_URL="$BASE_URL" -e QUERY="$QUERY" -e RATE="$rate" -e DURATION="${dur}s" \
        -e MAX_VUS="$MAX_VUS" -e SUMMARY="$summary" \
        "$APP_DIR/load/k6_work.js" >/dev/null 2>&1 || true   # k6 sai ≠0 se thresholds falham; não é erro aqui
}

# host_wait_idle: 10 s com outros processos do host (fora a VM) < IDLE_MAX_PCT de 1 núcleo.
# Se falhar, espera 30 s e tenta de novo, por até 10 min; depois aborta.
# Define IDLE_JSON (para o meta.json). Docker rodando só gera aviso.
IDLE_MAX_PCT=50
host_wait_idle() {
    local tag="$1" start=$SECONDS attempt=0 other top docker
    while :; do
        attempt=$((attempt + 1))
        read -r other top docker < <("$HOST_PY" "$EXPTOOLS" idlecheck --exclude "VBoxHeadless --startvm $VM_NAME" --seconds 10)
        (( docker == 1 )) && log "AVISO [$tag]: Docker (dockerd/containerd) está rodando no host"
        if (( $(echo "$other < $IDLE_MAX_PCT" | bc -l) )); then
            (( attempt > 1 )) && log "[$tag] host ocioso após $attempt tentativas (outros ${other}% de 1 núcleo)"
            IDLE_JSON="{\"attempts\": $attempt, \"other_pct_1core\": $other, \"top\": \"$top\", \"threshold_pct_1core\": $IDLE_MAX_PCT}"
            return 0
        fi
        log "[$tag] host ocupado: outros ${other}% de 1 núcleo (maior: $top); tentativa $attempt, nova checagem em 30 s"
        (( SECONDS - start >= 600 )) && { log "ERRO [$tag]: host não ficou ocioso em 10 min"; return 1; }
        sleep 30
    done
}

# Coletores: VM (psutil via SSH) e host (mesmo script, para CPU do host e do k6)
collectors_start() {
    COL_REMOTE="/tmp/poi_${APP_NAME}_metrics.csv"
    COL_REMOTE_PID=$(vm_ssh "rm -f $COL_REMOTE; setsid nohup $REMOTE_PY $REMOTE_DIR/metrics/collector.py --out $COL_REMOTE --match '$APP_MATCH' >/dev/null 2>&1 < /dev/null & echo \$!")
    # host: k6, processo da VM e o maior "outro" processo (ruído), fixado nos P-cores como o k6
    taskset -c "$K6_CPUSET" "$HOST_PY" "$APP_DIR/metrics/collector.py" --out "$1/host_metrics.csv" \
        --match "k6 run" --group "vm=VBoxHeadless --startvm $VM_NAME" --top &
    COL_HOST_PID=$!
    sleep 2   # primeira amostra
}

collectors_stop() {
    sleep 1
    vm_ssh "kill $COL_REMOTE_PID; while kill -0 $COL_REMOTE_PID 2>/dev/null; do sleep 0.2; done"
    kill "$COL_HOST_PID" 2>/dev/null; wait "$COL_HOST_PID" 2>/dev/null || true
    vm_fetch "$COL_REMOTE" "$1/vm_metrics.csv"
}

# run_measure <dir> <rate> <duração_s>: coletor on → k6 → coletor off → copia. Exporta T_START/T_END/CLOCK.
run_measure() {
    local dir="$1" rate="$2" dur="$3"
    mkdir -p "$dir"
    CLOCK=$(clock_offset)
    collectors_start "$dir"
    T_START=$(date +%s.%N)
    run_k6 "$rate" "$dur" "$dir/k6_summary.json" "$dir/k6_raw.csv.gz"
    T_END=$(date +%s.%N)
    collectors_stop "$dir"
    [[ -s "$dir/k6_summary.json" ]] || die "k6 não gerou resumo em $dir"
}

# Resumo de uma rodada para o log: "reqs falhas% p50 p95 p99 vazão"
k6_brief() {
    "$HOST_PY" - "$1" <<'EOF'
import json, sys
m = json.load(open(sys.argv[1]))["metrics"]
d = m["http_req_duration"]["values"]
print(f"reqs={m['http_reqs']['values']['count']} vazão={m['http_reqs']['values']['rate']:.1f}/s "
      f"falhas={m['http_req_failed']['values']['rate']:.1%} drop={m.get('dropped_iterations', {}).get('values', {}).get('count', 0)} "
      f"p50={d['p(50)']:.0f}ms p95={d['p(95)']:.0f}ms p99={d['p(99)']:.0f}ms")
EOF
}

# vm_brief <vm_metrics.csv> <vcpus>: CPU média e memória
vm_brief() {
    "$HOST_PY" - "$1" <<'EOF'
import sys, pandas as pd
d = pd.read_csv(sys.argv[1])
print(f"vm_cpu={d.cpu_pct.mean():.0f}% app_cpu={d.app_cpu_pct.mean():.0f}% mem_used={d.mem_used_mb.mean():.0f}MB swap={d.swap_used_mb.max():.0f}MB")
EOF
}

# experiment_main [--quick <cenario>]: experimento completo da app (idempotente, retomável)
experiment_main() {
    local quick="" only=""
    if [[ "${1:-}" == "--quick" ]]; then
        [[ -n "${2:-}" ]] || die "uso: $0 [--quick <cenario>]"
        quick=1; only="$2"
    elif [[ -n "${1:-}" ]]; then
        die "uso: $0 [--quick <cenario>]"
    fi
    exp_config ${quick:+--quick}

    local base="$APP_DIR/results"
    [[ -n "$quick" ]] && base="$APP_DIR/results/quick"
    mkdir -p "$base"
    RUN_LOG="$base/run.log"
    exec > >(tee -a "$RUN_LOG") 2>&1
    local commit; commit="$(git -C "$REPO_ROOT" rev-parse --short HEAD)$(git -C "$REPO_ROOT" diff --quiet HEAD -- "$APP_DIR" || echo '-dirty')"
    log "=== $APP_NAME: experimento ${quick:+(quick $only) }commit $commit; alvo $TARGET_RPS req/s; níveis $LEVELS %; $REPS × ${DURATION_S}s"
    host_check_power || exit 1

    local scen=() line
    mapfile -t scen < <(exp_scenarios ${only:+--only "$only"})
    (( ${#scen[@]} )) || die "cenário não encontrado: $only"

    for line in "${scen[@]}"; do
        local id cpus mem bw extra
        read -r id cpus mem bw extra <<<"$line"

        # pula o cenário inteiro se tudo já foi concluído (evita reiniciar a VM)
        local pending=0 lvl rep
        for lvl in $LEVELS; do for rep in $(seq 1 "$REPS"); do
            [[ -f "$base/$id/$(printf 'L%03d' "$lvl")/r$rep/meta.json" ]] || pending=1
        done; done
        if (( pending == 0 )); then log "[$id] já concluído; pulando"; continue; fi

        log "[$id] cenário: ${cpus} vCPU, ${mem} MB, disco ${bw}"
        host_check_power || exit 1
        apply_scenario "$cpus" "$mem" "$bw" "$extra"
        local vmcfg; vmcfg="$(vm_config_json)"

        for lvl in $LEVELS; do
            local ldir="$base/$id/$(printf 'L%03d' "$lvl")"
            local rate; rate=$(echo "scale=3; $TARGET_RPS * $lvl / 100" | bc -l)
            local done_all=1
            for rep in $(seq 1 "$REPS"); do [[ -f "$ldir/r$rep/meta.json" ]] || done_all=0; done
            (( done_all )) && { log "[$id L$lvl] já concluído"; continue; }

            log "[$id L$lvl] warm-up ${WARMUP_S}s a $rate req/s"
            run_k6 "$rate" "$WARMUP_S"
            for rep in $(seq 1 "$REPS"); do
                local rdir="$ldir/r$rep"
                [[ -f "$rdir/meta.json" ]] && continue
                rm -rf "$rdir"
                # a checagem de host ocioso (10 s) faz parte da pausa entre repetições
                (( PAUSE_S > 10 )) && sleep $((PAUSE_S - 10))
                host_wait_idle "$id L$lvl r$rep" || exit 1
                run_measure "$rdir" "$rate" "$DURATION_S"
                "$HOST_PY" "$EXPTOOLS" meta --out "$rdir/meta.json" --app "$APP_NAME" --scenario "$id" \
                    --level "$lvl" --rep "$rep" --target-rps "$TARGET_RPS" --rate "$rate" --query "$QUERY" \
                    --duration "$DURATION_S" --vm-config "$vmcfg" --commit "$commit" \
                    --t-start "$T_START" --t-end "$T_END" \
                    --clock-offset "${CLOCK% *}" --clock-rtt "${CLOCK#* }" \
                    --host-metrics "$rdir/host_metrics.csv" --idle "$IDLE_JSON" ${quick:+--quick}
                read -r hmean hmax hover omax oover otop < <("$HOST_PY" "$EXPTOOLS" hoststats "$rdir/host_metrics.csv")
                log "[$id L$lvl r$rep] $(k6_brief "$rdir/k6_summary.json") | $(vm_brief "$rdir/vm_metrics.csv") | host_cpu=${hmean}% (máx ${hmax}%)"
                if (( hover > 0 )); then
                    log "AVISO [$id L$lvl r$rep]: CPU do host passou de 85% em $hover amostra(s) (máx ${hmax}%); medição pode estar contaminada"
                fi
                if (( oover > 0 )); then
                    log "AVISO [$id L$lvl r$rep]: outros processos do host passaram de 1 núcleo em $oover s (máx ${omax}%; $otop); disputam os E-cores com a VM"
                fi
            done
        done
    done
    log "=== $APP_NAME: concluído. Resultados em $base"
}
