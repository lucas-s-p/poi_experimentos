# POI: virtualização local (VirtualBox), demanda × provisionamento

Atividade 2 (Demanda, Provisionamento e Desempenho). Grupo: João Henrique Simões Ramalho, Lucas de Sousa Pereira e Wendell Rafael Oliveira Nascimento. A análise completa está no relatório da atividade.

Três aplicações web só de backend (FastAPI + uvicorn), uma **cpu-bound**, uma **memory-bound** e uma **io-bound**, rodando numa VM do VirtualBox (roteiro em `docs/`). Para cada app, 5 cenários de provisionamento (Sub, Sub→Adequada, Adequada, Adequada→Super, Super) × 5 níveis de demanda (25–125% da carga-alvo) × 3 repetições, medindo tempo de resposta, vazão, CPU, memória e disco.

## Pré-requisitos (host Ubuntu)

- VirtualBox 7.2 (repositório da Oracle; o do Ubuntu não compila no kernel 6.17), usuário no grupo `vboxusers`.
- Secure Boot: chave MOK registrada (`sudo mokutil --import /var/lib/shim-signed/mok/MOK.der` + reboot) e `sudo /sbin/vboxconfig`.
- KVM sem VMX ao carregar: `options kvm enable_virt_at_load=0` em `/etc/modprobe.d/`.
- Miniforge (`~/miniforge3`), k6 (`~/.local/bin`), `sshpass`, `rsync`.
- Ambiente de análise do host, usado pelas três apps: `conda env create -f cpu-bound/analysis/environment.yml` (`poi-analysis`).
- Disco base `ubuntu_serve_2204_poi.vdi` fora do repositório; caminho em `.env` (`cp .env.example .env`).

## Preparação da VM

```bash
./vm/setup_vm.sh    # clona o VDI (o original não é alterado), cria a VM com NAT (2222→22, 8080→80, 8001–8003),
                    # instala a chave SSH (senha usada uma vez), sudo sem senha, rsync/nginx/fio e Miniforge
```

`vm/vmctl.sh` liga a VM em headless com o processo fixado nos E-cores (CPUs 4–11; o k6 roda nos P-cores 0–3), aplica vCPU/RAM/limite de disco, espera SSH e checa RAM livre do host. `curl localhost:8080` mostra o nginx do roteiro.

## Como rodar (cada app)

```bash
cd cpu-bound          # ou memory-bound, io-bound
./run_local.sh        # app no host + smoke test
./calibrate.sh        # carga-alvo e cenários (não aplica); ./calibrate.sh --apply
./run_experiment.sh   # experimento completo (~2–2h45), retomável
./run_experiment.sh --quick s3-adequada   # demonstração em sala (~3 min)
conda run -n poi-analysis python analysis/analyze.py
```

Condições exigidas (checadas antes de cada rodada; o experimento aborta ou espera): perfil de energia `performance`, notebook na tomada, host ocioso (outros processos < 0,5 núcleo por 10 s). Recomendado: Docker parado, Chrome fechado, rodar em `tmux` com `systemd-inhibit --what=sleep:idle:handle-lid-switch`. Avisos de ruído (outros processos > 1 núcleo durante a medição) vão para `results/run.log`.

## Resultados

`<app>/results/<cenário>/L<nível>/r<rep>/`: `k6_summary.json`, `k6_raw.csv.gz`, `vm_metrics.csv` (psutil 1 s na VM), `host_metrics.csv`, `vm_events.json` (OOM, workers mortos, reinícios) e `meta.json` (config da VM, afinidade, commit, offset de relógio host↔VM, energia, checagem de ociosidade, swap após reset, bytes gravados). `<app>/results/analysis/`: `summary.csv` (média, IC 95% t-Student n=3, mediana); os gráficos por cenário e comparativos (PNG) são gerados ali pelo `analysis/analyze.py` e não são versionados. Calibração em `<app>/calibration/`. Detalhes de cada app no README dela.

Estrutura comum: `vm/` (VM, experimento, calibração), `common/` (coletor, eventos da VM, análise; os `metrics/` das apps são links para cá).

## Comparação das três apps

| | cpu-bound | memory-bound | io-bound |
|---|---|---|---|
| Requisição | SHA-256 iterado (100k) | 128 MB retidos 400 ms, 4 passes aleatórios | 1 MiB escrito (fsync) + 1 MiB lido do disco |
| Varia | vCPU: 1, 2, **3**, 4, 6 (RAM 2 GB) | RAM: 1152, 1920, **2560**, 3584, 4608 MB (2 vCPU) | banda de disco: 29, 49, **69**, 140, 210 MiB/s (2 vCPU, 1 GB) |
| Carga-alvo (100%) | 45 req/s | 22 req/s | 24 req/s |
| Critério da carga-alvo | média do p95 (3 rodadas) ≤ 2× sem carga | idem | média do **p50** ≤ 2× sem carga (a cauda do fsync deixa p95 ≈ 3–4× p50 mesmo sem fila) |
| Ocupação do recurso limitante na Adequada a 100% | CPU ~49% | memória ~70%, sem swap | banda de disco ~71% do limite |
| Sub em sobrecarga | CPU 100%, vazão trava em ~30 req/s, latência até o timeout (30 s) | thrashing: ~20–25 mil pág/s de swap, vazão útil 0,6–3 req/s, workers mortos pelo healthcheck, 0 OOM | banda trava no limite (~29 MiB/s), vazão = banda / 2 MiB, iowait ~90% |
| Mais recurso que a Adequada | só reduz a % de CPU; latência para em ~34 ms (tempo de serviço) | sem efeito (nada a mais para usar) | sem efeito |
| Efeito que surpreendeu | escala com vCPU longe de linear (desbalanceamento entre workers; custo/req sobe com a carga pelo limite de potência da CPU) | rodadas isoladas presas no limite de concorrência (`MAX_INFLIGHT`) a 125% | limite do `bandwidthctl` deixa passar até ~25% acima do nominal sem fila; só satura com o disco continuamente ocupado |

Em todas, o padrão é o mesmo: com recurso suficiente a latência fica no tempo de serviço; perto do limite do recurso escasso a fila cresce de forma não linear; acima dele a vazão trava na capacidade e a latência vai ao timeout. Provisionar além da Adequada só aumenta a folga.

## Limitações conhecidas

- CPU híbrida (2 P-cores + 8 E-cores, 15 W): a VM fica nos E-cores, que outros processos do host também usam; o custo por requisição varia com o perfil de energia e com o ruído do host (por isso as checagens de energia e de ociosidade).
- O k6 roda no mesmo host que a VM. A afinidade separa os núcleos, mas cache, memória e o limite de potência são compartilhados.
- Só 3 repetições por combinação: o IC 95% fica largo nos pontos de transição (ex.: p95 da cpu-bound com 2 vCPUs a 100% variou de 269 a 748 ms).
- `bandwidthctl`: blocos zerados não são gravados pelo VDI e escapam do limite (as apps escrevem dados aleatórios); com chegadas espaçadas o limite é excedido em até ~25% (`io-bound/README.md`).
- Rodadas descartadas e refeitas ficam em `results/_descartadas_*` (bateria na memory-bound; ruído do host na io-bound), com o motivo em `LEIA.txt`.
