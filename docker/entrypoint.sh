#!/bin/sh
# Entrypoint comum das três imagens: sobe app.main:app com uvicorn, as mesmas flags do serviço systemd
# da VM (vm/explib.sh), na porta $PORT.
#
# Número de workers (um por CPU, por causa do GIL):
#   - WORKERS definida e não vazia: usa esse valor;
#   - senão, CPUs disponíveis ao container = min(nproc, ceil(cota / período)).
#     O nproc respeita o cpuset (--cpuset-cpus), mas não a cota de CPU (--cpus, deploy.resources.limits.cpus),
#     que é lida do cgroup: cpu.max (v2) ou cpu.cfs_quota_us / cpu.cfs_period_us (v1).
# Argumentos extras são repassados ao uvicorn.
set -eu

# ceil(cota / período) do cgroup do container; vazio se não houver cota
cpu_quota() {
    if [ -r /sys/fs/cgroup/cpu.max ]; then
        read -r quota period </sys/fs/cgroup/cpu.max
    elif [ -r /sys/fs/cgroup/cpu/cpu.cfs_quota_us ] && [ -r /sys/fs/cgroup/cpu/cpu.cfs_period_us ]; then
        quota=$(cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us)
        period=$(cat /sys/fs/cgroup/cpu/cpu.cfs_period_us)
    else
        return 0
    fi
    case "$quota" in max | -1 | "") return 0 ;; esac
    echo $(((quota + period - 1) / period))
}

ncpu=$(nproc)
quota=$(cpu_quota)
if [ -n "${WORKERS:-}" ]; then
    case "$WORKERS" in
        *[!0-9]* | 0*) echo "poi-entrypoint: WORKERS='$WORKERS' inválido (inteiro >= 1)" >&2; exit 2 ;;
    esac
    workers=$WORKERS
    origem="WORKERS"
else
    workers=$ncpu
    origem="nproc"
    if [ -n "$quota" ] && [ "$quota" -lt "$workers" ]; then
        workers=$quota
        origem="cota de CPU do cgroup"
    fi
    [ "$workers" -ge 1 ] || workers=1
fi

echo "poi-entrypoint: ${POI_APP:-app} na porta ${PORT}: ${workers} workers (${origem}; nproc=${ncpu}, cota=${quota:-sem})" >&2
exec uvicorn app.main:app --host 0.0.0.0 --port "$PORT" --workers "$workers" \
    --no-access-log --log-level info "$@"
