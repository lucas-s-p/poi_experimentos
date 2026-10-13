"""memory-bound: cada requisição aloca um buffer de `size_mb`, toca todas as páginas e o mantém como
working set ativo por `hold_ms`: `passes` passes de leitura e escrita em posições aleatórias (~1 por
página), distribuídos uniformemente ao longo da retenção (um a cada hold_ms/passes, o último no fim).

O custo é dominado por memória (páginas alocadas e retidas), não por computação: o tempo da requisição
vem sobretudo da retenção, e o custo de CPU é baixo. Com RAM suficiente, a latência é ~constante; com
pouca RAM, as páginas vão para o swap entre os passes e cada passe gera falhas de página major.

- O buffer é preenchido com um valor NÃO nulo: páginas de zeros iriam para o swap como blocos de zeros,
  que o disco virtual (VDI) não grava, deixando a pressão de memória artificialmente barata.
- Os índices aleatórios são gerados uma vez por worker e tamanho (não pesam a CPU de cada requisição).
- A concorrência por worker é limitada (MAX_INFLIGHT threads; o padrão do AnyIO seria 40): o excedente
  espera na fila do event loop sem memória alocada, e o pico da app fica limitado a
  workers × MAX_INFLIGHT × size_mb.
"""
import os
import time
from contextlib import asynccontextmanager
from functools import lru_cache

import anyio.to_thread
import numpy as np
from fastapi import FastAPI, Query

MAX_INFLIGHT = int(os.environ.get("MAX_INFLIGHT", "8"))
MIB = 1024 * 1024
PAGE_WORDS = 4096 // 8
PATTERN = np.int64(0x5A5A5A5A5A5A5A5A)


@asynccontextmanager
async def lifespan(_app):
    anyio.to_thread.current_default_thread_limiter().total_tokens = MAX_INFLIGHT
    yield


app = FastAPI(title="memory-bound", lifespan=lifespan)


@lru_cache(maxsize=8)
def random_index(n: int) -> np.ndarray:
    """~1 posição aleatória por página (n/512 posições), fixa por worker e tamanho."""
    return np.random.default_rng(12345).integers(0, n, size=max(1, n // PAGE_WORDS), dtype=np.int64)


def rss_mb() -> float:
    with open("/proc/self/statm") as f:
        return int(f.read().split()[1]) * 4096 / MIB


@app.get("/health")
def health():
    return {"status": "ok", "app": "memory-bound", "pid": os.getpid(), "cpus": os.cpu_count(),
            "max_inflight_per_worker": MAX_INFLIGHT}


@app.get("/work")
def work(size_mb: int = Query(128, ge=1, le=4096), passes: int = Query(4, ge=1, le=100),
         hold_ms: int = Query(400, ge=0, le=60000)):
    t0, c0 = time.perf_counter(), time.thread_time()
    n = size_mb * MIB // 8
    idx = random_index(n)
    rss0 = rss_mb()
    buf = np.empty(n, dtype=np.int64)
    buf.fill(PATTERN)                      # toca (e aloca de fato) todas as páginas
    rss_held = rss_mb() - rss0
    checksum = 0
    interval = hold_ms / passes / 1000
    for p in range(passes):
        # retenção sem CPU até o próximo passe; passes em ~interval, 2·interval, …, hold_ms
        time.sleep(max(0.0, t0 + (p + 1) * interval - time.perf_counter()))
        checksum ^= int(np.take(buf, idx).sum() & 0xFFFFFFFF)   # leitura aleatória (~1 por página)
        buf[idx] ^= p + 1                                         # escrita aleatória (páginas sujas)
    out = {"size_mb": size_mb, "passes": passes, "hold_ms": hold_ms, "checksum": checksum,
           "service_ms": round((time.perf_counter() - t0) * 1000, 3),
           "cpu_ms": round((time.thread_time() - c0) * 1000, 3),
           "rss_held_mb": round(rss_held, 1), "pid": os.getpid()}
    del buf
    return out
