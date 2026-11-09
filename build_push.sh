#!/usr/bin/env bash
# Build das imagens das três apps com as tags <DOCKERHUB_USER>/poi-<app>:<POI_TAG> e :latest.
# Só publica no Docker Hub com --push (faça antes `docker login -u <usuário>`, senha ou token interativos;
# nenhuma credencial fica no repositório).
#
# Uso: ./build_push.sh [--push] [cpu] [mem] [io]      (sem apps = as três)
# .env (opcional): DOCKERHUB_USER (lucassousapereira), POI_TAG (1.0), PLATFORM (linux/amd64).
# PLATFORM com mais de uma arquitetura (ex. linux/amd64,linux/arm64) usa buildx e exige --push.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
if [[ -f .env ]]; then set -a; source .env; set +a; fi

USER_HUB="${DOCKERHUB_USER:-lucassousapereira}"
TAG="${POI_TAG:-1.0}"
PLATFORM="${PLATFORM:-linux/amd64}"
declare -A DIR=([cpu]=cpu-bound [mem]=memory-bound [io]=io-bound)

PUSH=0
APPS=()
for arg in "$@"; do
    case "$arg" in
        --push) PUSH=1 ;;
        cpu | mem | io) APPS+=("$arg") ;;
        -h | --help) sed -n '2,9p' "$0"; exit 0 ;;
        *) echo "argumento desconhecido: $arg (use --push, cpu, mem, io)" >&2; exit 2 ;;
    esac
done
((${#APPS[@]})) || APPS=(cpu mem io)

MULTI=0
[[ "$PLATFORM" == *,* ]] && MULTI=1
if ((MULTI && !PUSH)); then
    echo "PLATFORM=$PLATFORM tem várias arquiteturas: o buildx só consegue publicar (use --push)." >&2
    exit 2
fi

REV="$(git rev-parse --short HEAD 2>/dev/null || echo desconhecido)"
[[ -n "$(git status --porcelain 2>/dev/null)" ]] && REV="$REV-dirty"

for app in "${APPS[@]}"; do
    repo="$USER_HUB/poi-$app"
    args=(--platform "$PLATFORM" -f "${DIR[$app]}/Dockerfile" -t "$repo:$TAG" -t "$repo:latest"
          --label "org.opencontainers.image.title=poi-$app"
          --label "org.opencontainers.image.version=$TAG"
          --label "org.opencontainers.image.revision=$REV"
          --label "org.opencontainers.image.source=https://github.com/lucas-s-p/poi_experimentos")
    echo "== $repo:$TAG (+ latest), $PLATFORM, commit $REV"
    if ((MULTI)); then
        docker buildx build "${args[@]}" --push .
    else
        docker build "${args[@]}" .
        if ((PUSH)); then
            docker push "$repo:$TAG"
            docker push "$repo:latest"
        fi
    fi
done

if ((!MULTI)); then
    echo
    docker images --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep -E "^$USER_HUB/poi-(cpu|mem|io):($TAG|latest)\b" | sort
fi
((PUSH)) || echo "Imagens prontas localmente. Para publicar: docker login -u $USER_HUB && ./build_push.sh --push"
