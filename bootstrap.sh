#!/usr/bin/env bash
# Prepara o host, sem sudo. Idempotente: pode ser rodado de novo.
#   ./bootstrap.sh [--vdi CAMINHO] [--workdir DIR] [--vm-name NOME] [--conda-root DIR]
#   1. confere os pacotes do sistema e imprime o "sudo apt install" do que faltar
#   2. cria o .env a partir do .env.example (sem afinidade de CPU), se ainda não existir
#   3. Miniforge em ~/miniforge3 e k6 em ~/.local/bin, se faltarem
#   4. envs conda do host: poi-analysis (orquestração e análise) e poi-tools (tmux)
#   5. chave SSH da VM
# --vdi: disco base, só para criar a VM do zero (partindo do poi-vm.ova, não precisa).
# --conda-root: onde instalar o Miniforge (padrão ~/miniforge3; ex. /tmp/miniforge3 se a cota do HOME for pequena).
# As opções só valem na criação do .env (exceto --vdi, que também atualiza um .env existente).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
K6_VERSION=v2.3.0   # versão usada nos experimentos

log() { echo "[$(date '+%F %T')] $*" >&2; }
die() { log "ERRO: $*"; exit 1; }

VDI="" WORKDIR="" NAME="" CROOT="" VDI_SET=0
while (( $# )); do
    case "$1" in
        --vdi) VDI="${2:?--vdi exige um caminho}"; VDI_SET=1; shift 2 ;;
        --workdir) WORKDIR="${2:?--workdir exige um diretório}"; shift 2 ;;
        --vm-name) NAME="${2:?--vm-name exige um nome}"; shift 2 ;;
        --conda-root) CROOT="${2:?--conda-root exige um diretório}"; shift 2 ;;
        *) die "uso: $0 [--vdi CAMINHO] [--workdir DIR] [--vm-name NOME] [--conda-root DIR]" ;;
    esac
done

# --- 1. pacotes do sistema --------------------------------------------------------
missing=()
for pair in rsync:rsync bc:bc curl:curl taskset:util-linux setsid:util-linux ss:iproute2 \
            ssh:openssh-client ssh-keygen:openssh-client git:git tar:tar python3:python3; do
    command -v "${pair%%:*}" >/dev/null || missing+=("${pair#*:}")
done
if (( ${#missing[@]} )); then
    log "Faltam pacotes do sistema. Peça para alguém com sudo rodar:"
    echo "    sudo apt install -y $(printf '%s\n' "${missing[@]}" | sort -u | paste -sd' ')" >&2
else
    log "Pacotes do sistema ok (rsync bc curl util-linux iproute2 openssh-client git)"
fi
if command -v VBoxManage >/dev/null; then
    log "VirtualBox: $(VBoxManage --version 2>/dev/null | tail -1)"
else
    log "AVISO: VirtualBox ausente. Em máquina própria: sudo ./install_virtualbox.sh"
fi
git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1 \
    || log "AVISO: $ROOT não é um clone git; use git clone (o zip do GitHub quebra os links simbólicos de metrics/)"

# --- 2. .env ---------------------------------------------------------------------
ENVF="$ROOT/.env"
if [[ -f "$ENVF" ]]; then
    log ".env já existe; mantido"
    if (( VDI_SET )); then
        sed -i "s|^BASE_VDI=.*|BASE_VDI=$VDI|" "$ENVF"; log "BASE_VDI atualizado no .env: $VDI"
    fi
else
    if (( ! VDI_SET )) && [[ -t 0 ]]; then
        read -rp "Caminho do VDI base para criar a VM do zero (Enter = nenhum, vou usar o poi-vm.ova): " VDI
    fi
    sedargs=(-e "s|^BASE_VDI=.*|BASE_VDI=$VDI|" -e "s|^VM_CPUSET=.*|VM_CPUSET=|" -e "s|^K6_CPUSET=.*|K6_CPUSET=|")
    [[ -n "$WORKDIR" ]] && sedargs+=(-e "s|^VM_WORKDIR=.*|VM_WORKDIR=$WORKDIR|")
    [[ -n "$NAME" ]] && sedargs+=(-e "s|^VM_NAME=.*|VM_NAME=$NAME|")
    [[ -n "$CROOT" ]] && sedargs+=(-e "s|^CONDA_ROOT=.*|CONDA_ROOT=$CROOT|")
    sed "${sedargs[@]}" "$ROOT/.env.example" >"$ENVF"
    log ".env criado a partir do .env.example (sem afinidade de CPU)"
fi
(( VDI_SET )) && [[ -n "$VDI" && ! -f "$VDI" ]] && log "AVISO: VDI não encontrado: $VDI"
set -a
# shellcheck disable=SC1090
source "$ENVF"
set +a
log ".env: VM_NAME=$VM_NAME, VM_WORKDIR=$VM_WORKDIR, BASE_VDI=${BASE_VDI:-vazio}, VM_CPUSET=${VM_CPUSET:-vazio}, K6_CPUSET=${K6_CPUSET:-vazio}"

# --- 3. Miniforge e k6 ---------------------------------------------------------------
CONDA_ROOT="${CONDA_ROOT:-$HOME/miniforge3}"
if [[ -x "$CONDA_ROOT/bin/conda" ]]; then
    log "Miniforge ok: $CONDA_ROOT ($("$CONDA_ROOT/bin/conda" --version))"
else
    log "Instalando Miniforge em $CONDA_ROOT"
    tmp="$(mktemp -d)"
    curl -fsSL -o "$tmp/Miniforge3.sh" \
        "https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-$(uname -m).sh"
    bash "$tmp/Miniforge3.sh" -b -p "$CONDA_ROOT" >/dev/null
    rm -rf "$tmp"
fi

K6="$HOME/.local/bin/k6"
if [[ -x "$K6" ]] && "$K6" version 2>/dev/null | grep -q "^k6 $K6_VERSION "; then
    log "k6 ok: $K6 ($K6_VERSION)"
else
    case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) die "arquitetura sem k6: $(uname -m)" ;; esac
    log "Instalando k6 $K6_VERSION em $K6"
    mkdir -p "$HOME/.local/bin"
    tmp="$(mktemp -d)"
    curl -fsSL "https://github.com/grafana/k6/releases/download/$K6_VERSION/k6-$K6_VERSION-linux-$arch.tar.gz" \
        | tar -xz -C "$tmp"
    install -m 755 "$tmp/k6-$K6_VERSION-linux-$arch/k6" "$K6"
    rm -rf "$tmp"
fi

# --- 4. envs conda do host --------------------------------------------------------------
if [[ -x "$CONDA_ROOT/envs/poi-analysis/bin/python" ]]; then
    log "env poi-analysis ok"
else
    log "Criando env poi-analysis (pandas, matplotlib, scipy, pyyaml, psutil)"
    "$CONDA_ROOT/bin/conda" env create -q -f "$ROOT/cpu-bound/analysis/environment.yml" >/dev/null
fi
if [[ -x "$CONDA_ROOT/envs/poi-tools/bin/tmux" ]]; then
    log "env poi-tools ok (tmux)"
else
    log "Criando env poi-tools (tmux)"
    "$CONDA_ROOT/bin/conda" create -q -y -n poi-tools -c conda-forge tmux >/dev/null
fi

# --- 5. chave SSH ------------------------------------------------------------------------
if [[ -f "$SSH_KEY" ]]; then
    log "Chave SSH ok: $SSH_KEY"
else
    mkdir -p "$(dirname "$SSH_KEY")"; chmod 700 "$(dirname "$SSH_KEY")"
    ssh-keygen -t ed25519 -N "" -C "poi-vm" -f "$SSH_KEY" >/dev/null
    log "Chave SSH criada: $SSH_KEY (instalada na VM pelo ./vm/setup_vm.sh)"
fi

cat >&2 <<EOF

Pronto. Versões: $("$K6" version | cut -d' ' -f1-2), $("$CONDA_ROOT/envs/poi-analysis/bin/python" --version), tmux $("$CONDA_ROOT/envs/poi-tools/bin/tmux" -V | cut -d' ' -f2)
Os scripts do repositório já acham o k6 em ~/.local/bin. Para usar k6 e tmux direto no terminal:
    export PATH="\$HOME/.local/bin:$CONDA_ROOT/envs/poi-tools/bin:\$PATH"
Próximo passo: ./vm/setup_vm.sh --existing   (VM importada do poi-vm.ova)
EOF
(( ${#missing[@]} == 0 )) || { log "Faltam pacotes do sistema (veja o apt install acima)"; exit 1; }
