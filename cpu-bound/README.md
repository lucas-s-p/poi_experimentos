# cpu-bound

`GET /work?iterations=N` aplica SHA-256 iterativamente N vezes (custo de CPU proporcional a N, memória e disco desprezíveis). Roda com `uvicorn --workers $(nproc)`: com o GIL, cada worker usa no máximo 1 vCPU.

Cenários (`provisioning.yaml`): variam só vCPU (1, 2, 3, 4, 6), RAM fixa em 2 GB.

**Por que a Adequada roda a ~55–60% de CPU e não a 70%:** a carga-alvo é a maior taxa com p95 ≤ 2× o tempo sem carga. Dois efeitos fazem a latência subir antes de 70%: (1) o custo por requisição cresce com a carga (limite de potência de 15 W da CPU reduz o turbo dos E-cores, mais o overhead do VirtualBox); (2) cada worker do uvicorn tem fila própria e as conexões são distribuídas ao acaso, então um worker acumula fila enquanto outro fica ocioso. Detalhes em `calibration/`.

## Como rodar

Pré-requisito: VM criada com `../vm/setup_vm.sh` (ver README da raiz).

```bash
./run_local.sh                       # app no host (porta 18001) + smoke test
./calibrate.sh                       # mede custo/req e propõe a carga-alvo (não aplica)
./calibrate.sh --apply               # grava target_rps em load/demand.yaml
./run_experiment.sh                  # 5 cenários × 5 níveis × 3 repetições (retomável)
./run_experiment.sh --quick s3-adequada   # demonstração: 1 cenário, 2 níveis, 1 rep de 20 s
conda run -n poi-analysis python analysis/analyze.py
```

## Arquivos

| Caminho | Conteúdo |
|---|---|
| `app/` | FastAPI (`/health`, `/work`) |
| `load/k6_work.js` | carga em taxa constante (`constant-arrival-rate`) |
| `load/demand.yaml` | intensidade (`query`), carga-alvo, níveis, durações, repetições |
| `metrics/collector.py` | coletor psutil (1 s) que roda na VM |
| `calibration/` | saída da calibração (`proposal.json`, `calibrate.log`, rodadas) |
| `results/<cenário>/L<nível>/r<rep>/` | `k6_summary.json`, `k6_raw.csv.gz`, `vm_metrics.csv`, `host_metrics.csv`, `meta.json` |
| `results/run.log` | log do experimento (inclui avisos de CPU do host > 85%) |
| `results/analysis/` | `summary.csv` (média e IC 95%), gráficos por cenário e comparativos |
