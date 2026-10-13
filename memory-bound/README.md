# memory-bound

`GET /work?size_mb=128&passes=4&hold_ms=400` aloca um buffer de `size_mb`, preenche todas as páginas e o mantém como working set ativo por `hold_ms`: `passes` passes de leitura e escrita em posições aleatórias (~1 por página), um a cada `hold_ms/passes` (o último no fim da retenção). A memória é liberada ao fim da requisição.

O custo é de memória, não de CPU: na VM, ~400 ms por requisição (quase só retenção), ~0,03 CPU-s/req e 128 MB retidos. A memória usada cresce com as requisições em andamento (≈ taxa × 0,4 s × 128 MB). Com pouca RAM, as páginas vão para o swap entre os passes e cada passe gera falhas de página major; a pressão aparece como swap e latência, não como OOM (a VM tem 13 GB de swap).

Escolhas de projeto:

- **Sem ordenação:** a versão inicial (alocar + preencher + acessos aleatórios + `sort`) gastava ~350 ms de CPU por requisição; com 2 vCPU fixos, a app virava CPU-bound e os cenários de RAM só se diferenciavam no Sub.
- **Buffer preenchido com valor não nulo:** páginas de zeros iriam para o swap como blocos de zeros, que o disco virtual (VDI) não grava; a pressão de memória ficaria artificialmente barata.
- **`MAX_INFLIGHT=8` requisições por worker (16 vagas com 2 workers, teto da app ~2 GB):** com endpoints síncronos, cada worker do uvicorn atenderia até 40 requisições simultâneas (pool padrão do AnyIO) e uma sobrecarga alocaria dezenas de buffers de uma vez. Com o limite, o excedente espera na fila do event loop sem memória alocada. Com 4 por worker, o limite já virava gargalo a 10 req/s com 256 MB; com 8, a carga-alvo e o nível de 125% ficam abaixo das 16 vagas.

Cenários (`provisioning.yaml`): variam só RAM, 2 vCPU fixos. Super = 4608 MB (limitado pela RAM livre do host: RAM da VM + 1,5 GB de folga, checado antes de cada cenário; máximo viável medido ~10,7 GB).

## Calibração (2026-10-13, perfil `performance`, host ocioso)

| Item | Valor |
|---|---|
| Tempo sem carga (p50, 0,5 req/s) | 408 ms → limite p95 = **815 ms** (critério: média do p95 de 3 rodadas, como na cpu-bound) |
| Carga-alvo | **22 req/s** (candidatas 14/18/22 por concorrência; p95 415–417 ms; CPU da VM 24%) |
| Memória usada na carga-alvo (WS) | 1780 MB (MemTotal − MemAvailable, p95 das amostras; RSS dos workers 1470 MB) |
| RAM dos cenários | Sub 1152 · Sub→Adeq 1920 · **Adequada 2560** (WS/0,70) · Adeq→Super 3584 · Super 4608 MB |
| Validação da Adequada | média do p95 439 ms; memória 68–72% ocupada; sem swap |
| Sub a 125% (27,5 req/s) | colapso por thrashing: pswpin ~12,6 mil pág/s, falhas major ~12,6 mil/s, 75% de timeouts; 0 OOM kills, 2 workers mortos pelo healthcheck |

Sub = 60% do WS: cabe a 25%, começa a fazer swap por volta de 50% e entra em thrashing acima disso. Não há critério de aprovação do Sub em sobrecarga: o colapso é o resultado esperado. Detalhes em `calibration/summary.txt`.

## Mortes de workers: healthcheck × OOM

O supervisor do uvicorn faz ping em cada worker e, se ele não responde em 5 s (`timeout_worker_healthcheck`, padrão mantido), manda SIGKILL e sobe outro. Sob thrashing o worker fica travado em falhas de página e é morto assim, sem nenhum OOM no kernel. O uvicorn registra "Child process died" nos dois casos; `vm_events` separa pela lista de vítimas do OOM killer (`journalctl -k`), e a análise mostra as duas contagens por cenário × nível.

## Reset entre rodadas

Antes de cada rodada (`reset_between_reps: true` em `load/demand.yaml`): reinicia o serviço, `swapoff -a && swapon -a`, `drop_caches`, espera o `/health`; depois a checagem de host ocioso e um warm-up de 40 s logo antes da medição. Sem isso, o thrashing de uma rodada contaminaria a seguinte. O swap logo após o reset fica em `meta.json` (`swap_after_reset_mb`, esperado ~0; aviso no `run.log` acima de 50 MB). `vm_events.swap_used_at_start_mb` é o swap no início da medição, já depois do warm-up na mesma carga (no Sub em sobrecarga, o warm-up já leva ao thrashing).

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

## Resultados: rodadas anômalas a 125% (Adequada r3 e Super r3)

Duas rodadas a 125% (27,5 req/s) com RAM folgada tiveram p50 de 1691 ms (Adequada, r3) e 1008 ms (Super, r3), sem swap e com ~40% de CPU; as outras 13 rodadas a 125% nesses cenários ficaram em ~406 ms. Nelas havia 34,7 e 22,7 requisições em andamento (lei de Little), acima das 16 vagas (`MAX_INFLIGHT=8` × 2 workers), contra ~11 nas demais. As conexões keep-alive do k6 se dividem de forma desigual entre os 2 workers; quando um worker enche suas 8 vagas, forma-se fila, o k6 abre mais conexões e o efeito se realimenta. É o limite de concorrência, não a memória (o mesmo desbalanceamento entre workers visto na cpu-bound). Essas rodadas dominam a média e o IC desses pontos; a análise mostra também a mediana das 3 repetições (`*_median` no `summary.csv` e linha pontilhada nos gráficos comparativos), que reflete o comportamento típico. As rodadas não foram refeitas.
