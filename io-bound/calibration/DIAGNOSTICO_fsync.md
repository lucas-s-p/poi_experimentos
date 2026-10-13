# Calibração interrompida (2026-10-13 19:02): critério p95 ≤ 2 × p50 sem carga inalcançável

Disco sem limite, size_kb=1024: tempo sem carga (1 req/s, 61 req) p50 23 ms, p95 33 ms → limite 46 ms.
Menor taxa candidata, 3 req/s (0,07 requisição em andamento, %util 8–9%): p95 56 / 78 / 82 ms (média 72 ms).
As taxas maiores não foram medidas (interrompido).

Teste direto na VM (1 MB, 3/s, sem sobreposição; serviço parado):

| Padrão | p50 | p95 | p99 |
|---|---|---|---|
| cria + fsync + apaga (app) | 18,8 / 23,1 ms | 77,3 / 56,1 ms | 90,0 / 63,4 ms |
| sobrescreve + fsync | 16,6 ms | 76,4 ms | 88,8 ms |
| sobrescreve + fdatasync | 24,8 ms | 113,9 ms | 129,6 ms |

A cauda (p95 ≈ 3–4 × p50) existe com uma requisição por vez e não depende do journal do ext4
(criar/apagar × sobrescrever): vem da camada VirtualBox → NVMe do host.
