# memory-bound (buffer numpy retido, acessos aleatórios). Contexto de build = raiz do repositório:
#   docker build -f memory-bound/Dockerfile -t lucassousapereira/poi-mem:1.0 .
# WORKERS (opcional): padrão = CPUs disponíveis ao container (ver docker/entrypoint.sh).
# MAX_INFLIGHT (padrão 8 no código): requisições simultâneas por worker; pico ≈ workers × MAX_INFLIGHT × size_mb.
FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    POI_APP=memory-bound \
    PORT=8002

RUN useradd --system --uid 10001 --user-group --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin poi

WORKDIR /srv/poi
COPY memory-bound/requirements.txt .
RUN pip install -r requirements.txt
COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/poi-entrypoint
COPY memory-bound/app ./app

USER poi
EXPOSE 8002
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=3 \
    CMD python -c "import os, urllib.request as u; u.urlopen('http://127.0.0.1:%s/health' % os.environ['PORT'], timeout=4)"
ENTRYPOINT ["poi-entrypoint"]
