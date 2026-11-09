# Docker (Atividade 4)

As três apps da Atividade 2 em containers, publicadas no Docker Hub e implantadas com Docker Compose numa VM da Cloud do LSD, atrás do balanceador `poi-atividades`. O código das apps é o mesmo da VM do VirtualBox; nada da Atividade 2 mudou.

| App | Imagem | Porta | Teste |
|---|---|---|---|
| cpu-bound | `lucassousapereira/poi-cpu` | 8001 | `/work?iterations=100000` |
| memory-bound | `lucassousapereira/poi-mem` | 8002 | `/work?size_mb=128&passes=4&hold_ms=400` |
| io-bound | `lucassousapereira/poi-io` | 8003 | `/work?size_kb=1024` |

Tags: versão (`1.0`) e `latest`, `linux/amd64`. Base `python:3.12-slim` com pip (~140 MB; ~210 MB a memory-bound, por causa do numpy), usuário não-root `poi` (uid 10001), `HEALTHCHECK` em `/health`.

## Arquivos

- `<app>/Dockerfile` e `<app>/requirements.txt` (dependências diretas com versão fixa). O contexto de build é a **raiz do repositório**: `docker build -f cpu-bound/Dockerfile .`.
- `.dockerignore`: whitelist; só entram `*/app/`, `*/requirements.txt` e `docker/entrypoint.sh` (nada de `results/`, `.env`, `.git`, discos de VM, envs conda).
- `docker/entrypoint.sh`: escolhe o número de workers e faz `exec uvicorn app.main:app`, com as mesmas flags do serviço systemd da VM.
- `docker-compose.yml`: os três serviços, `restart: unless-stopped`, healthcheck, volume da io-bound e limites de CPU/memória comentados.
- `build_push.sh` e `deploy.sh`: lêem o `.env` (variáveis na seção "Atividade 4" do `.env.example`).

## Build e publicação

```bash
./build_push.sh                        # build das três (tags 1.0 e latest), sem publicar
docker login -u lucassousapereira      # senha/token interativos; nada é gravado no repositório
./build_push.sh --push                 # build + push das três
./build_push.sh --push io              # só uma
```

`POI_TAG` e `DOCKERHUB_USER` vêm do `.env`. Para outra arquitetura (ex. VM arm64): `PLATFORM=linux/amd64,linux/arm64 ./build_push.sh --push` (buildx, multi-arquitetura).

## Subir localmente

```bash
docker compose pull && docker compose up -d    # imagens do Docker Hub
docker compose up -d --build                   # ou build local
docker compose ps                              # os três "healthy"
curl localhost:8001/health
curl "localhost:8001/work?iterations=100000"
curl "localhost:8002/work?size_mb=128&passes=4&hold_ms=400"
curl "localhost:8003/work?size_kb=1024"        # "disk_write_kb": 1024, "ok": true
docker compose logs | grep poi-entrypoint      # quantos workers cada app subiu
docker compose down                            # (-v também apaga o volume da io-bound)
```

Se a VM do VirtualBox estiver ligada, ela ocupa 8001–8003 no host: use `DOCKER_CPU_PORT`, `DOCKER_MEM_PORT` e `DOCKER_IO_PORT` (ex. 18001–18003).

## Workers e limites

`WORKERS` (no compose: `CPU_WORKERS`, `MEM_WORKERS`, `IO_WORKERS`) fixa o número de workers do uvicorn. Vazia, vale o número de CPUs disponíveis ao container: `min(nproc, ceil(cota/período))`. O `nproc` respeita o cpuset (`--cpuset-cpus`), mas não a cota (`--cpus`, `deploy.resources.limits.cpus`), que o entrypoint lê do cgroup (`cpu.max`). Exemplos medidos: sem limite → 16 (host de 16 CPUs); `--cpus 1.5` → 2; `--cpuset-cpus 0-2` → 3; `WORKERS=3 --cpus 1` → 3.

A memória da memory-bound sob saturação chega a workers × `MAX_INFLIGHT` (8) × 128 MB, ou seja, ~1 GB por worker. Com limite de memória, reduza os workers na mesma proporção (comentário no `docker-compose.yml`).

## io-bound: volume e bytes aleatórios

`/var/tmp/poi-io` (o `DATA_DIR` da app) é um `VOLUME` na imagem e o volume nomeado `poi-io-data` no compose. Os arquivos vão para o sistema de arquivos do host (ext4), não para a camada overlay, e o `fsync` chega ao disco. Para conferir:

```bash
docker compose exec io sh -c 'grep " /var/tmp/poi-io " /proc/self/mountinfo'   # ext4 /dev/..., não overlay
docker compose exec io python -c "from app.main import random_block as r; b=r(1<<20); print(b.count(0)/len(b))"   # ~0,004
```

O conteúdo continua sendo `os.urandom` com um cabeçalho único por requisição. Um arquivo capturado no volume durante uma requisição teve 0,39% de bytes zero e razão de compressão zlib 1,000.

## Deploy na VM do LSD

Pré-requisitos na VM: Docker com o plugin `docker compose`, saída para o Docker Hub e o usuário no grupo `docker` (senão, `LSD_DOCKER="sudo docker"` no `.env`, com aspas). No `.env` local: `LSD_HOST`, `LSD_USER` e, se precisar, `LSD_SSH_KEY`/`LSD_SSH_PORT`.

```bash
./deploy.sh            # copia docker-compose.yml + .env mínimo para ~/poi-docker; compose pull && up -d; /health das três
./deploy.sh --status   # containers e /health
./deploy.sh --down     # derruba (o volume da io-bound fica)
```

Para a VM vão só o `docker-compose.yml` e um `.env` com `DOCKERHUB_USER`, `POI_TAG` e `*_WORKERS`. O `.env` local, com as credenciais da VM do VirtualBox, nunca é enviado. Na VM, os workers seguem as vCPUs dela, como no serviço systemd da Atividade 2.

## Pelo balanceador `poi-atividades`

<!-- preencher com a configuração do balanceador (endereço, listeners/portas → VM:8001–8003, health monitor) -->

```bash
curl http://<balanceador>/health    # ...
```

## Observações

- **`/health` compete pelas vagas do `MAX_INFLIGHT`.** Na memory-bound e na io-bound, o `/health` é um endpoint síncrono como o `/work` e roda no mesmo pool de threads, limitado a `MAX_INFLIGHT=8` por worker. Com todas as vagas ocupadas, ele espera na fila: com 1 worker e 10 `/work` longos em andamento, o `/health` não respondeu em 4 s (ocioso: 3 ms). Sob saturação, isso afeta:
  - **o healthcheck do Docker:** o container é marcado `unhealthy`, mas o Docker **não** reinicia o container por isso (`restart` só age quando o processo morre);
  - **o health monitor do balanceador:** ele pode tirar o backend de rotação durante a saturação.

  É o mesmo comportamento da VM; o código não foi alterado. A cpu-bound não tem esse limite.
- O campo `cpus` do `/health` é `os.cpu_count()`, que no container mostra as CPUs do host, não as do container. O número de workers está no log (`docker compose logs | grep poi-entrypoint`).
- O `psutil` dos `environment.yml` não entra nas imagens: só o coletor de métricas o usa, e ele não faz parte das apps.
