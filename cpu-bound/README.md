# cpu-bound

`GET /work?iterations=N` aplica SHA-256 iterativamente N vezes (custo de CPU proporcional a N, memória e disco desprezíveis). Roda com `uvicorn --workers $(nproc)`: com o GIL, cada worker usa no máximo 1 vCPU.

Cenários (`provisioning.yaml`): variam só vCPU (1, 2, 3, 4, 6), RAM fixa em 2 GB.

## Calibração (2026-10-13, perfil `performance`, host ocioso)

| Item | Valor |
|---|---|
| Intensidade | `iterations=100000` |
| Tempo sem carga (p50, 1 req/s) | 34,5 ms (Super), 33,8 ms (Adequada); p95 sem carga 46,5 ms |
| Limite | p95 ≤ 2 × 34,5 = **69,1 ms** |
| Critério | **média do p95 de 3 rodadas de 60 s** ≤ limite, sem descartes |
| Adequada | 3 vCPU |
| Carga-alvo (100%) | **45 req/s** (média do p95 67,8 ms; 48 req/s → 73,1 ms; 50,5 → 78,4 ms) |

Média de n=3, e não cada rodada: o p95 de rodadas idênticas varia ±5 ms (a 48 req/s, de 66 a 83 ms), a mesma ordem da folga até o limite; por rodada, o resultado dependeria do acaso. Rodadas e logs em `calibration/` (`*_balanced*` e `*_performance_ruido*` são as tentativas anteriores, com outro perfil e com o host ruidoso).

**Por que a Adequada roda a ~45–50% de CPU e não a 70%:** dois efeitos fazem a latência subir antes de 70%: (1) o custo por requisição cresce com a carga (0,031 → 0,036 CPU-s/req de 27% para 52% de utilização, pelo limite de potência de 15 W da CPU, que reduz o turbo dos E-cores, mais o overhead do VirtualBox); (2) cada worker do uvicorn tem fila própria e as conexões são distribuídas ao acaso, então um worker acumula fila enquanto outro fica ocioso.

O experimento exige perfil `performance`, notebook na tomada e host ocioso (outros processos < 0,5 núcleo por 10 s antes de cada rodada); ver README da raiz.

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
