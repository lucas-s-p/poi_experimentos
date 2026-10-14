# io-bound

`GET /work?size_kb=1024` escreve um arquivo de `size_kb` com `fsync`, tira o arquivo do page cache (`posix_fadvise(DONTNEED)`), lê de volta do disco e apaga. Por requisição: ~1 MiB escrito + ~1 MiB lido no disco da VM, ~0,004 CPU-s.

Escolhas de projeto:

- **Bytes aleatórios, nunca zeros:** bloco de `os.urandom` por worker (0,39% de bytes zero, nenhuma página de 4 KB zerada) + cabeçalho único por requisição. O disco virtual (VDI) não grava blocos zerados, e escrever zeros escaparia do limite de banda do VirtualBox (ver `../vm/disk_limit_test.sh`).
- **Leitura do disco, não do page cache:** conferido por requisição (`/proc/thread-self/io`: a thread lê exatamente `size_kb` do disco). RAM da VM baixa (1 GB) para o cache ajudar menos. hostiocache do controlador desligado (o disco não passa pelo page cache do host).
- **`size_kb=1024`:** com 256 KB a carga vira de IOPS/fsync e o limite de banda quase não atua; com 4096 KB a carga-alvo ficaria em ~100+ MB/s e o experimento gravaria ~1 TB no SSD do host.
- **`MAX_INFLIGHT=8` por worker (16 vagas):** o excedente espera em fila FIFO no event loop em vez de ir todo para a fila do kernel (sem limite, até 40 por worker, e cada requisição ficaria mais lenta quando o disco estivesse limitado).

Cenários (`provisioning.yaml`): variam só o limite de banda do disco (`VBoxManage bandwidthctl`, leitura + escrita somadas), 2 vCPU e 1 GB fixos.

## Calibração (2026-10-13, perfil `performance`, host ocioso)

| Item | Valor |
|---|---|
| Critério | **média do p50** de 3 rodadas de 60 s ≤ 2 × p50 sem carga (ver abaixo) |
| Tempo sem carga (disco sem limite) | p50 22,9 ms (61 req a 1 req/s) → limite 45,8 ms |
| Busca (disco sem limite) | 3, 5, 8, 12, 16, 20, 24 req/s: todas passam (p50 31–37 ms, %util ≤ 50%) |
| Carga-alvo | **24 req/s** (a maior taxa testada; o joelho está acima) |
| Banda na carga-alvo (B) | 47,9 MiB/s (leitura + escrita na VM) |
| Limites (MiB/s) | Sub 29 (60% de B) · Sub→Adeq 49 · **Adequada 69** (B/0,70) · Adeq→Super 140 · Super 210 (~3× Adequada) |
| Validação da Adequada | média do p50 32,5 ms ≤ 43,1 ms (2 × mediana do tempo sem carga); disco a 71% do limite |
| Sub a 125% (30 req/s) | satura no limite: 29,2 MiB/s (101%), vazão 15,1 req/s (= 29 / 2 MiB), p50 18 s, iowait 94%, 12,6% de falhas |
| Super a 125% | 30 req/s, p50 30 ms, disco a 29% do limite |

**Por que o p50 e não o p95 (como nas outras apps):** a latência do `fsync` no caminho VirtualBox → NVMe do host tem p95 ≈ 3–4 × p50 mesmo com uma requisição por vez (medido criando/apagando e sobrescrevendo arquivos; não é o journal do ext4). "p95 ≤ 2 × p50 sem carga" seria inalcançável em qualquer carga. O p50 só sobe com fila; p95/p99 continuam medidos e reportados. Detalhes em `calibration/DIAGNOSTICO_fsync.md`.

**Tempo sem carga e o limite de banda:** medido nos 6 casos (sem limite + 5 cenários), ficou entre 15,9 e 22,9 ms sem relação com o limite: o limitador do VirtualBox libera uma rajada inicial, e uma requisição isolada de ~2 MiB não é freada. Por isso a validação da Adequada usa a **mediana das 6 medições** (21,5 ms; ~360 requisições) em vez da medição isolada da Adequada (15,9 ms, que reprovaria por 0,6 ms só por ruído). A análise mostra separados (a) o tempo sem carga por cenário e (b) p95 ÷ tempo sem carga do mesmo cenário (efeito de fila), em `results/analysis/comparacao_fila.png`.

Arquivos da calibração: `calibration/summary.txt`, `proposal.json`, `noload.json`, `search.json`, `runs/`; `calibration/runs_alvo12/` guarda as rodadas da primeira versão (carga-alvo 12 req/s, antes de estender a busca).

## Reset entre rodadas

Antes de cada rodada: para o serviço, apaga os arquivos da app (`/var/tmp/poi-io`, sobras de requisições interrompidas), `swapoff/swapon`, `drop_caches`, inicia o serviço e espera o `/health`; depois a checagem de host ocioso e um warm-up de 40 s logo antes da medição. Por rodada, `meta.json` registra os MB gravados no disco da VM (`vm_disk_written`, com e sem warm-up), e o `run.log` mostra o total do experimento.

## Como rodar

```bash
./run_local.sh                       # app no host (porta 18003) + smoke test
./calibrate.sh                       # carga-alvo e limites (não aplica); --resume reaproveita rodadas
./calibrate.sh --apply
./run_experiment.sh                  # 5 cenários × 5 níveis × 3 repetições (retomável)
./run_experiment.sh --quick s3-adequada
conda run -n poi-analysis python analysis/analyze.py
```

## Resultados: o limite do `bandwidthctl` é um teto sob saturação, não um limite rígido

No experimento, o limite configurado só foi respeitado com fila no disco. No Sub (29 MiB/s), banda medida na VM (leitura + escrita, média da janela de 60 s):

| Nível | Demanda | Medido | Observação |
|---|---|---|---|
| 25–50% | 12–24 MiB/s | 12–24 MiB/s | abaixo do limite |
| 75% | 36,6 MiB/s | **36,6 MiB/s** nas 3 rodadas, estável | 1,26 × o limite, sem throttling e sem fila (~0,6 requisição em andamento) |
| 100% (r1) | 48,8 MiB/s | 40,4 → 29,1 → 28,5 (terços da janela) | excede no início e então trava no limite |
| 100% (r2, r3), 125% | 48,8 / 61 MiB/s | 29,0–29,7 MiB/s | exatamente o limite; fila de segundos, iowait > 80% |

Com chegadas espaçadas (open model, poucas requisições em andamento), o limitador do VirtualBox deixa passar até ~25% acima do valor nominal; quando a demanda excede bem o limite e o disco fica continuamente ocupado, a banda trava no valor configurado. (No teste com fio, fluxo contínuo de requisições sem intervalos, o limite foi respeitado: `../vm/disk_limit_test.sh`.) Um "balde de créditos" acumulado nas pausas entre rodadas não explica sozinho o efeito: as 3 rodadas a 75% excederam ~755 MiB cada, mais que o crédito da pausa anterior (~500 MiB), sem esgotar.

Consequência: o colapso do Sub aparece entre 75% e 100% da carga-alvo, e não logo acima de ~60% como os 29 MiB/s nominais indicariam. As medições valem como "o que o `bandwidthctl` do VirtualBox entrega"; a análise mostra a banda efetiva medida por rodada ao lado do limite nominal. A alternativa (limitar dentro da VM com `io.max` do cgroup v2, mais preciso) foi considerada e não usada.
