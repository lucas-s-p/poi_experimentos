# Reproduzir do zero

Guia para quem só tem este repositório e o `poi-vm.ova`: vai do download até o `--quick` rodando e os gráficos gerados, e diz como mostrar as três apps ao professor. Vale para um notebook Ubuntu qualquer e para o LCC3 (sem sudo, VirtualBox já instalado).

Precisa de: Ubuntu 22.04 ou 24.04, 4 CPUs ou mais, 8 GB de RAM ou mais, ~15 GB livres no disco onde a VM ficar e internet.

## 1. Baixar o OVA

Link do Drive: https://drive.google.com/drive/folders/16j4yrRGr1wkLsd-qxlXXWga5pkxegOg4 (baixe o `poi-vm.ova`)

```bash
cd ~/Downloads                    # onde o navegador salvou
unzip poi-vm*.zip 2>/dev/null     # só se o Drive entregar um .zip
ls -lh poi-vm.ova                 # ~2,2 GB
sha256sum poi-vm.ova              # deve dar 8bd0860f397e5ad4db25e7241481aa59a195274c79190f0ae101479489f570df
```

O `.ova` não precisa ser descompactado: o VirtualBox importa direto. A VM vem com Ubuntu 22.04, Miniforge, as três apps instaladas como serviços (`poi-cpu`, `poi-mem`, `poi-io`), nginx e os redirecionamentos de porta.

## 2. Clonar o repositório

Use `git clone`. O zip do GitHub quebra os links simbólicos de `*/metrics/`, e sem o `.git` o commit não é registrado nos resultados.

```bash
git clone https://github.com/lucas-s-p/poi_experimentos.git
cd poi_experimentos
```

## 3. VirtualBox

- **LCC3:** já está instalado. Confira com `VBoxManage --version` e pule para o passo 4.
- **Notebook próprio, com sudo:**

  ```bash
  sudo ./install_virtualbox.sh
  ```

  O script faz o que foi feito no host dos experimentos: repositório da Oracle, `virtualbox-7.2`, grupo `vboxusers`, `options kvm enable_virt_at_load=0` (kernel 6.12 ou mais novo) e, com Secure Boot, a chave MOK e o `vboxconfig`. Com Secure Boot, ele pede uma senha temporária. Depois:
  1. Reinicie. Na tela azul, escolha *Enroll MOK* → *Continue* → *Yes*, digite a senha e reinicie.
  2. Rode `sudo ./install_virtualbox.sh` de novo.

  No fim, faça logout e login (por causa do grupo `vboxusers`).

## 4. Importar a VM

Use o nome `poi-vm`, que é o que os scripts esperam. No LCC3, a pasta da VM tem que ser `/tmp`, como no roteiro.

**Pela interface:** *Arquivo → Importar Appliance…* e depois:
1. Escolha o `poi-vm.ova` e clique em *Próximo*.
2. Confira o nome `poi-vm`.
3. Em *Pasta Base da Máquina*, use `/tmp` no LCC3 (no notebook, pode deixar o padrão).
4. Em *Política de endereço MAC*, deixe *Incluir apenas endereços MAC de placas NAT*.
5. Clique em *Finalizar*. Leva alguns minutos.

**Pelo terminal (equivalente):**

```bash
VBoxManage import ~/Downloads/poi-vm.ova --vsys 0 --vmname poi-vm --basefolder /tmp
```

O `/tmp` do LCC3 é apagado quando a máquina reinicia. Se isso acontecer, importe de novo.

## 5. Preparar o host (sem sudo)

```bash
./bootstrap.sh                                   # notebook
./bootstrap.sh --workdir /tmp/poi-work           # LCC3: arquivos de trabalho também no /tmp
./bootstrap.sh --workdir /tmp/poi-work --conda-root /tmp/miniforge3   # LCC3 com cota de HOME pequena (~2 GB de conda)
```

O script:
- confere os pacotes do sistema (`rsync`, `bc`, `curl`, `util-linux`, `iproute2`, `git`) e, se faltar algum, imprime o `sudo apt install` para alguém rodar;
- instala o Miniforge e o k6 v2.3.0 no seu HOME;
- cria os envs `poi-analysis` (scripts e análise) e `poi-tools` (tmux);
- gera a chave `~/.ssh/poi_vm_ed25519`;
- cria o `.env` sem afinidade de CPU.

Pode rodar de novo quantas vezes quiser. Se perguntar pelo VDI, aperte Enter: partindo do OVA ele não é usado.

## 6. Conferir a VM

```bash
./vm/setup_vm.sh --existing
```

O script:
- confere e corrige o NAT, o cache de I/O do host e o grupo de banda `io_limit`;
- diz se alguma das portas 2222, 8080, 8001, 8002 ou 8003 está ocupada no host (e por quem);
- liga a VM em segundo plano e instala a sua chave SSH (a senha `osboxes.org` é usada uma vez, sem `sshpass`);
- confere o nginx e os três serviços.

O final esperado:

```
nginx via NAT (localhost:8080): HTTP 200
poi-cpu: enabled, active; localhost:8001/health → {"status":"ok","app":"cpu-bound",...}
poi-mem: enabled, active; localhost:8002/health → {"status":"ok","app":"memory-bound",...}
poi-io: enabled, active; localhost:8003/health → {"status":"ok","app":"io-bound",...}
VM pronta.
```

## 7. Ligar a VM pela interface (como no roteiro)

O `setup_vm.sh` deixou a VM ligada sem janela. Para usar a interface, desligue-a primeiro:

```bash
bash -c 'source vm/vmctl.sh && vm_stop'
```

No VirtualBox, selecione `poi-vm`, clique em *Iniciar* e depois em *Início normal*. Entre com o login `osboxes` e a senha `osboxes.org`. Dentro da VM:

```bash
sudo systemctl status nginx       # active (running)
curl localhost:80                 # página "Welcome to nginx!"
```

**Redirecionamento de portas:** em *Configurações → Rede → Adaptador 1 (NAT) → Avançado → Redirecionamento de Portas* estão as regras:

| Nome | Host | Convidado |
|---|---|---|
| ssh | 127.0.0.1:2222 | 22 |
| nginx | 127.0.0.1:8080 | 80 |
| cpu | 127.0.0.1:8001 | 8001 |
| mem | 127.0.0.1:8002 | 8002 |
| io | 127.0.0.1:8003 | 8003 |

O nginx usa a porta 8080 no host porque um usuário comum não pode abrir portas abaixo de 1024. As regras só podem ser editadas com a VM desligada. No navegador do host, abra http://localhost:8080.

## 8. Subir e testar as apps

Os serviços sobem sozinhos com a VM. No console da VM:

```bash
systemctl status poi-cpu poi-mem poi-io
curl localhost:8001/health
curl "localhost:8001/work?iterations=100000"            # cpu-bound: SHA-256 iterado
curl "localhost:8002/work?size_mb=128&passes=4&hold_ms=400"  # memory-bound: 128 MB por ~400 ms
curl "localhost:8003/work?size_kb=1024"                 # io-bound: 1 MiB gravado (fsync) e lido
sudo systemctl restart poi-mem                          # (re)iniciar um serviço
sudo journalctl -u poi-io -n 20                         # log de um serviço
```

No host, as mesmas URLs funcionam nas portas redirecionadas (`curl localhost:8002/health`). Para entrar por SSH: `ssh -i ~/.ssh/poi_vm_ed25519 -p 2222 osboxes@127.0.0.1`.

Se um serviço não existir ou não responder, o `run_experiment.sh` da app reinstala o código e o serviço (passo 9).

## 9. Experimento rápido (`--quick`)

Uma app por vez. Cada uma leva ~4 min: liga a VM com os recursos do cenário, faz o deploy da app, roda 40 s de aquecimento e mede 2 níveis de carga (50% e 125%) por 20 s cada.

```bash
cd cpu-bound   && ./run_experiment.sh --quick s3-adequada; cd ..
cd memory-bound && ./run_experiment.sh --quick s3-adequada; cd ..
cd io-bound    && ./run_experiment.sh --quick s3-adequada; cd ..
```

- Os cenários são `s1-sub`, `s2-sub-adeq`, `s3-adequada`, `s4-adeq-super` e `s5-super`.
- Antes de começar, o script compara a vCPU e a RAM de cada cenário com o host (CPUs e RAM disponível + 1,5 GB de folga). Se o cenário pedido não couber, ele para e sugere um que caiba.
- O script desliga a VM se ela estiver aberta na interface e a liga de novo em segundo plano. Para voltar à interface depois, desligue-a como no passo 7.
- Ele só aborta em notebook na bateria. Se o perfil de energia não for `performance`, o script só avisa; para melhorar a medição: `powerprofilesctl set performance`.
- Antes de cada rodada, ele espera o host ficar ocioso (outros processos usando menos de 0,5 núcleo). Feche o navegador e programas pesados; se o host não ficar ocioso em 10 min, o script desiste.
- O log fica em `<app>/results/quick/run.log`. Os resultados ficam em `<app>/results/quick/s3-adequada/L050/r1/` e `.../L125/r1/`.

Num notebook com 4 CPUs ou menos, ou com pouca RAM, use o cenário que o script sugerir.

## 10. Gráficos

```bash
cd cpu-bound
~/miniforge3/bin/conda run -n poi-analysis python analysis/analyze.py                          # oficiais → results/analysis/*.png
~/miniforge3/bin/conda run -n poi-analysis python analysis/analyze.py --results results/quick  # seu --quick → results/quick/analysis/*.png
cd ..
```

Repita em `memory-bound` e `io-bound`. Se usou `--conda-root /tmp/miniforge3`, troque `~/miniforge3` por `/tmp/miniforge3`. Os PNG não são versionados; o `summary.csv` oficial está no repositório.

O `--quick` sobrescreve o `results/quick/` que já vem no repositório. Para voltar ao original: `git checkout -- '*/results/quick'`.

## Não rode `calibrate.sh --apply`

Os resultados oficiais (5 cenários × 5 níveis × 3 repetições por app) e a calibração estão no repositório. O `calibrate.sh --apply` recalcula a carga-alvo e os cenários para a sua máquina e **sobrescreve** `load/demand.yaml`, `provisioning.yaml` e `calibration/`. Aí os resultados deixam de bater com o relatório. O `./run_experiment.sh` sem `--quick` também não é necessário: ele leva ~2–2h45 por app e, como os resultados já estão completos, ele pula tudo.

## O que mostrar ao professor

1. **VM do roteiro:** `poi-vm` ligada pela interface, login `osboxes`, `sudo systemctl status nginx`, `curl localhost:80` dentro da VM e http://localhost:8080 no navegador do host.
2. **Redirecionamento de portas:** a tabela do passo 7 em *Configurações → Rede → Avançado*.
3. **Deploy das apps:** `systemctl status poi-cpu poi-mem poi-io` na VM e um `curl` de `/work` em cada porta a partir do host.
4. **Teste de carga ao vivo:** `./run_experiment.sh --quick s3-adequada` numa app (~4 min). Vale mostrar o log: recursos aplicados, k6 a 50% e 125% e as linhas de latência e CPU. Se der tempo, rode `--quick s1-sub` na mesma app para mostrar a saturação.
5. **Resultados:** os gráficos gerados no passo 10 (`results/analysis/comparacao_latencia.png` e `cenario_*.png`) e a tabela "Comparação das três apps" do `README.md`.

## Problemas comuns

| Sintoma | O que fazer |
|---|---|
| `porta 8080 do host ocupada por …` | Feche o programa indicado. SSH_PORT e NGINX_PORT podem ser trocadas no `.env`; as portas 8001–8003 não mudam. |
| `VM poi-vm não existe` | Importe o OVA com o nome `poi-vm` (passo 4) ou ajuste VM_NAME no `.env`. |
| `o cenário … não cabe neste host` | Use o cenário sugerido ou feche programas para liberar RAM. |
| `notebook na bateria` | Conecte o carregador. |
| `host ocupado: outros …% de 1 núcleo (maior: …)` | Feche o processo indicado (navegador, IDE, atualizações). |
| VM não liga, `VERR_VMX_IN_VMX_ROOT_MODE` | Falta `options kvm enable_virt_at_load=0` (rode `sudo ./install_virtualbox.sh` e reinicie). |
| `VM_CPUSET='…' inclui a CPU …` | Deixe `VM_CPUSET=` e `K6_CPUSET=` vazios no `.env`. |
| SSH não responde | Abra a VM na interface e confira se ela terminou o boot; rode `./vm/setup_vm.sh --existing` de novo. |
