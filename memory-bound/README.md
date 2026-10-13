# memory-bound

`GET /work?size_mb=128&passes=4&hold_ms=400` aloca um buffer de `size_mb`, preenche todas as páginas e o mantém como working set ativo por `hold_ms`: `passes` passes de leitura e escrita em posições aleatórias (~1 por página), um a cada `hold_ms/passes` (o último no fim da retenção). A memória é liberada ao fim da requisição.

O custo é de memória, não de CPU: na VM, ~400 ms por requisição (quase só retenção), ~0,03 CPU-s/req e 128 MB retidos. A memória usada cresce com as requisições em andamento (≈ taxa × 0,4 s × 128 MB). Com pouca RAM, as páginas vão para o swap entre os passes e cada passe gera falhas de página major; a pressão aparece como swap e latência, não como OOM (a VM tem 13 GB de swap).

Escolhas de projeto:

- **Sem ordenação:** a versão inicial (alocar + preencher + acessos aleatórios + `sort`) gastava ~350 ms de CPU por requisição; com 2 vCPU fixos, a app virava CPU-bound e os cenários de RAM só se diferenciavam no Sub.
- **Buffer preenchido com valor não nulo:** páginas de zeros iriam para o swap como blocos de zeros, que o disco virtual (VDI) não grava; a pressão de memória ficaria artificialmente barata.
- **`MAX_INFLIGHT=8` requisições por worker (16 vagas com 2 workers, teto da app ~2 GB):** com endpoints síncronos, cada worker do uvicorn atenderia até 40 requisições simultâneas (pool padrão do AnyIO) e uma sobrecarga alocaria dezenas de buffers de uma vez. Com o limite, o excedente espera na fila do event loop sem memória alocada. Com 4 por worker, o limite já virava gargalo a 10 req/s com 256 MB; com 8, a carga-alvo e o nível de 125% ficam abaixo das 16 vagas.

Cenários (`provisioning.yaml`): variam só RAM, 2 vCPU fixos. Super = 4608 MB (limitado pela RAM livre do host: RAM da VM + 1,5 GB de folga, checado antes de cada cenário; máximo viável medido ~10,7 GB). Sub, intermediários e Adequada vêm da calibração.

## Como rodar

Pré-requisito: VM criada com `../vm/setup_vm.sh` (ver README da raiz).

```bash
./run_local.sh                       # app no host (porta 18002) + smoke test
./calibrate.sh                       # carga-alvo e RAM dos cenários (não aplica)
./calibrate.sh --apply               # grava target_rps e a RAM dos cenários
./run_experiment.sh                  # 5 cenários × 5 níveis × 3 repetições (retomável)
./run_experiment.sh --quick s3-adequada
conda run -n poi-analysis python analysis/analyze.py
```

Por rodada, `meta.json` registra OOM kills (kernel), workers mortos e reiniciados pelo uvicorn e reinícios do serviço pelo systemd (`vm_events`); o coletor registra swap in/out e falhas de página major. A análise mostra esses eventos e a pressão de memória em painéis próprios.

## Arquivos

Mesma estrutura da cpu-bound: `app/`, `load/` (k6 e `demand.yaml`), `metrics/` (links para `../common/`), `calibration/`, `results/<cenário>/L<nível>/r<rep>/`, `results/analysis/`.
