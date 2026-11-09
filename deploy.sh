#!/usr/bin/env bash
# Deploy na VM da Cloud do LSD: copia o docker-compose.yml e um .env mínimo (só DOCKERHUB_USER, POI_TAG
# e *_WORKERS; nunca o .env local) para LSD_DIR na VM, faz `docker compose pull && up -d` e confere o
# /health das três apps de dentro da VM. As imagens precisam estar publicadas no Docker Hub.
#
# Uso: ./deploy.sh            # deploy
#      ./deploy.sh --status   # só mostra os containers e o /health
#      ./deploy.sh --down     # derruba os containers (mantém o volume da io-bound)
#
# .env: LSD_HOST e LSD_USER (obrigatórios); LSD_SSH_KEY, LSD_SSH_PORT (22), LSD_DIR (poi-docker, relativo
# ao HOME do usuário na VM), LSD_DOCKER ("docker"; use "sudo docker" se o usuário não estiver no grupo docker),
# DOCKERHUB_USER (lucassousapereira), POI_TAG (1.0).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
if [[ -f .env ]]; then set -a; source .env; set +a; fi

: "${LSD_HOST:?defina LSD_HOST no .env}"
: "${LSD_USER:?defina LSD_USER no .env}"
PORT_SSH="${LSD_SSH_PORT:-22}"
DIR="${LSD_DIR:-poi-docker}"
DOCKER="${LSD_DOCKER:-docker}"
USER_HUB="${DOCKERHUB_USER:-lucassousapereira}"
TAG="${POI_TAG:-1.0}"

MODE=deploy
case "${1:-}" in
    "") ;;
    --status) MODE=status ;;
    --down) MODE=down ;;
    -h | --help) sed -n '2,13p' "$0"; exit 0 ;;
    *) echo "argumento desconhecido: $1" >&2; exit 2 ;;
esac

SSH_OPTS=(-p "$PORT_SSH" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[[ -n "${LSD_SSH_KEY:-}" ]] && SSH_OPTS+=(-i "$LSD_SSH_KEY")
DEST="$LSD_USER@$LSD_HOST"
rsh() { ssh "${SSH_OPTS[@]}" "$DEST" "$@"; }
QDIR="$(printf '%q' "$DIR")"
# -f: o diretório do projeto (e o .env lido pelo compose) é o do arquivo, sem depender do cwd
COMPOSE="$DOCKER compose -f $QDIR/docker-compose.yml"

status() {
    rsh "$COMPOSE ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'"
    for port in 8001 8002 8003; do
        printf ':%s/health → ' "$port"
        rsh "curl -fsS --max-time 5 http://127.0.0.1:$port/health" || echo "FALHOU"
        echo
    done
}

case "$MODE" in
    status) status; exit 0 ;;
    down) rsh "$COMPOSE down"; exit 0 ;;
esac

echo "== $DEST:$DIR ($USER_HUB/poi-*:$TAG)"
rsh "uname -m; $DOCKER compose version"
rsh "mkdir -p $QDIR"
scp -q -P "$PORT_SSH" "${SSH_OPTS[@]:2}" docker-compose.yml "$DEST:$DIR/docker-compose.yml"
{
    echo "# gerado pelo deploy.sh"
    echo "DOCKERHUB_USER=$USER_HUB"
    echo "POI_TAG=$TAG"
    for v in CPU_WORKERS MEM_WORKERS IO_WORKERS; do
        if [[ -n "${!v:-}" ]]; then echo "$v=${!v}"; fi
    done
} | rsh "cat > $QDIR/.env"

rsh "$COMPOSE pull && $COMPOSE up -d --no-build --remove-orphans"

echo "== aguardando os healthchecks (até 90 s)"
for _ in $(seq 1 30); do
    states="$(rsh "$COMPOSE ps --format '{{.Health}}'" | sort -u | tr '\n' ' ')"
    [[ "$states" == "healthy " ]] && break
    sleep 3
done
status
echo "Pelo balanceador: curl http://<endereço do poi-atividades>/... (ver DOCKER.md)"
