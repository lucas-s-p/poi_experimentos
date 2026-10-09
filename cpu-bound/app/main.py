"""cpu-bound: cada requisição aplica SHA-256 iterativamente (custo proporcional a `iterations`)."""
import hashlib
import os
import time

from fastapi import FastAPI, Query

app = FastAPI(title="cpu-bound")


@app.get("/health")
def health():
    return {"status": "ok", "app": "cpu-bound", "pid": os.getpid(), "cpus": os.cpu_count()}


@app.get("/work")
def work(iterations: int = Query(100_000, ge=1, le=50_000_000)):
    t0 = time.perf_counter()
    digest = b"poi"
    for _ in range(iterations):
        # entrada de 32 bytes: o hashlib não libera o GIL, então cada worker usa 1 núcleo
        digest = hashlib.sha256(digest).digest()
    return {
        "iterations": iterations,
        "digest": digest.hex()[:16],
        "service_ms": round((time.perf_counter() - t0) * 1000, 3),
        "pid": os.getpid(),
    }
