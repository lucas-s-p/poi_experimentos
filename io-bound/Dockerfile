# io-bound (escrita aleatória + fsync, leitura do disco). Contexto de build = raiz do repositório:
#   docker build -f io-bound/Dockerfile -t lucassousapereira/poi-io:1.0 .
# WORKERS (opcional): padrão = CPUs disponíveis ao container (ver docker/entrypoint.sh).
# DATA_DIR é um VOLUME: os arquivos vão para o disco do host, não para a camada overlay do container
# (sem -v, o Docker cria um volume anônimo; no docker-compose.yml é o volume nomeado poi-io-data).
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    POI_APP=io-bound \
    PORT=8003 \
    DATA_DIR=/var/tmp/poi-io

RUN useradd --system --uid 10001 --user-group --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin poi \
    && mkdir -p "$DATA_DIR" && chown poi:poi "$DATA_DIR"

WORKDIR /srv/poi
COPY io-bound/requirements.txt .
RUN pip install -r requirements.txt
COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/poi-entrypoint
COPY io-bound/app ./app

# depois do chown: um volume nomeado vazio herda o dono (poi) do diretório da imagem
VOLUME ["/var/tmp/poi-io"]

USER poi
EXPOSE 8003
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import os, urllib.request as u; u.urlopen('http://127.0.0.1:%s/health' % os.environ['PORT'], timeout=4)"
ENTRYPOINT ["poi-entrypoint"]
