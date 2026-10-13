"""io-bound: cada requisição escreve um arquivo de `size_kb` com fsync, descarta-o do page cache,
lê de volta do disco e apaga.

- Conteúdo aleatório (os.urandom, gerado uma vez por worker e tamanho) com um cabeçalho único por
  requisição: nunca zeros. O disco virtual (VDI) não grava blocos zerados, e escrever zeros escaparia
  do limite de banda do VirtualBox (bandwidthctl).
- fsync garante a escrita no disco; posix_fadvise(DONTNEED) tira o arquivo do page cache antes da
  leitura, para que ela venha do disco e não da RAM.
- Bytes lidos/escritos pela thread da requisição (/proc/thread-self/io) vão na resposta.
- Concorrência por worker limitada a MAX_INFLIGHT threads (padrão do AnyIO seria 40).
"""
import itertools
import os
import time
from contextlib import asynccontextmanager
from functools import lru_cache

import anyio.to_thread
from fastapi import FastAPI, Query

MAX_INFLIGHT = int(os.environ.get("MAX_INFLIGHT", "8"))
DATA_DIR = os.environ.get("DATA_DIR", "/var/tmp/poi-io")
CHUNK = 1024 * 1024
_counter = itertools.count()


@asynccontextmanager
async def lifespan(_app):
    os.makedirs(DATA_DIR, exist_ok=True)
    anyio.to_thread.current_default_thread_limiter().total_tokens = MAX_INFLIGHT
    yield


app = FastAPI(title="io-bound", lifespan=lifespan)


@lru_cache(maxsize=8)
def random_block(size: int) -> bytes:
    return os.urandom(size)


def thread_io():
    with open("/proc/thread-self/io") as f:
        d = dict(line.split(": ") for line in f.read().splitlines())
    return int(d["read_bytes"]), int(d["write_bytes"])


@app.get("/health")
def health():
    return {"status": "ok", "app": "io-bound", "pid": os.getpid(), "cpus": os.cpu_count(),
            "max_inflight_per_worker": MAX_INFLIGHT, "data_dir": DATA_DIR}


@app.get("/work")
def work(size_kb: int = Query(1024, ge=4, le=262144)):
    size = size_kb * 1024
    t0, c0 = time.perf_counter(), time.thread_time()
    r0, w0 = thread_io()
    seq = next(_counter)
    path = os.path.join(DATA_DIR, f"{os.getpid()}-{seq}.bin")
    header = f"{os.getpid()}:{seq}:{time.time_ns()}".encode().ljust(64, b"#")
    body = memoryview(random_block(size))

    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.write(fd, header)
        for off in range(len(header), size, CHUNK):
            os.write(fd, body[off:min(off + CHUNK, size)])
        os.fsync(fd)
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
    finally:
        os.close(fd)
    t_write = time.perf_counter()

    fd = os.open(path, os.O_RDONLY)
    try:
        os.posix_fadvise(fd, 0, 0, os.POSIX_FADV_DONTNEED)
        nread, first = 0, b""
        while chunk := os.read(fd, CHUNK):
            if not first:
                first = chunk[:64]
            nread += len(chunk)
    finally:
        os.close(fd)
        os.unlink(path)
    r1, w1 = thread_io()
    t1 = time.perf_counter()
    return {"size_kb": size_kb, "ok": nread == size and first == header,
            "service_ms": round((t1 - t0) * 1000, 3), "write_ms": round((t_write - t0) * 1000, 3),
            "read_ms": round((t1 - t_write) * 1000, 3), "cpu_ms": round((time.thread_time() - c0) * 1000, 3),
            "disk_read_kb": (r1 - r0) // 1024, "disk_write_kb": (w1 - w0) // 1024, "pid": os.getpid()}
