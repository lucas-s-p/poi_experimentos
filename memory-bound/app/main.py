"""memory-bound: cada requisição aloca um buffer de `size_mb`, preenche, faz acessos aleatórios e ordena.

A memória de uma requisição é liberada ao final dela. A concorrência por worker é limitada
(MAX_INFLIGHT threads): sem isso, cada worker atenderia até 40 requisições simultâneas (pool padrão
do AnyIO) e uma sobrecarga alocaria dezenas de buffers de uma vez. Com o limite, o excedente espera
na fila do event loop (sem memória alocada) e o pico de memória da app fica limitado a
workers × MAX_INFLIGHT × ~1,25 × size_mb.
"""
import os
import time
from contextlib import asynccontextmanager

import anyio.to_thread
import numpy as np
from fastapi import FastAPI, Query

MAX_INFLIGHT = int(os.environ.get("MAX_INFLIGHT", "4"))
MIB = 1024 * 1024


@asynccontextmanager
async def lifespan(_app):
    anyio.to_thread.current_default_thread_limiter().total_tokens = MAX_INFLIGHT
    yield


app = FastAPI(title="memory-bound", lifespan=lifespan)


@app.get("/health")
def health():
    return {"status": "ok", "app": "memory-bound", "pid": os.getpid(), "cpus": os.cpu_count(),
            "max_inflight_per_worker": MAX_INFLIGHT}


@app.get("/work")
def work(size_mb: int = Query(128, ge=1, le=4096)):
    t0 = time.perf_counter()
    n = size_mb * MIB // 8
    rng = np.random.default_rng()
    # aloca e preenche com valores aleatórios (todas as páginas tocadas; nada de páginas zeradas compartilhadas)
    buf = rng.integers(0, 2**62, size=n, dtype=np.int64)
    # acessos aleatórios: leitura (gather) e escrita (scatter) em n/8 posições → falhas de cache/TLB
    idx = rng.integers(0, n, size=n // 8)
    checksum = int(buf[idx].sum() & 0xFFFFFFFF)
    buf[idx] ^= 1
    # ordenação (in-place)
    buf.sort()
    out = {"size_mb": size_mb, "checksum": checksum, "median": int(buf[n // 2]),
           "service_ms": round((time.perf_counter() - t0) * 1000, 3), "pid": os.getpid()}
    del buf, idx
    return out
