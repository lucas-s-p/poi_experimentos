#!/usr/bin/env bash
# Cria e prepara a VM única usada pelas 3 aplicações. Idempotente: pode ser rodado de novo.
#   1. clona o VDI base (o original nunca é alterado) e cria a VM com NAT + port forwards
#   2. liga em headless, instala a chave SSH (senha usada uma única vez) e sudo sem senha
#   3. instala pacotes (rsync, nginx), desativa atualizações automáticas e instala Miniforge
set -euo pipefail
source "$(dirname "$0")/vmctl.sh"

for cmd in VBoxManage VBoxHeadless ssh ssh-keygen rsync sshpass taskset; do
    command -v "$cmd" >/dev/null || die "comando ausente: $cmd"
done
[[ -f "$BASE_VDI" ]] || die "BASE_VDI não encontrado: $BASE_VDI"
mkdir -p "$VM_WORKDIR"

# --- 1. VM -------------------------------------------------------------------
if vm_exists; then
    log "VM $VM_NAME já existe; pulando criação"
else
    if [[ ! -f "$VM_DISK" ]]; then
        log "Clonando $BASE_VDI → $VM_DISK"
        VBoxManage clonemedium disk "$BASE_VDI" "$VM_DISK" --format VDI
    fi
    log "Criando VM $VM_NAME"
    VBoxManage createvm --name "$VM_NAME" --ostype Ubuntu22_LTS_64 \
        --basefolder "$VM_WORKDIR" --register
    VBoxManage modifyvm "$VM_NAME" \
        --cpus 2 --memory 2048 --ioapic on --paravirt-provider kvm \
        --graphicscontroller vmsvga --vram 16 --audio-enabled off --usb-ohci off \
        --boot1 disk --boot2 none --boot3 none --boot4 none \
        --nic1 nat \
        --natpf1 "ssh,tcp,127.0.0.1,$SSH_PORT,,22" \
        --natpf1 "nginx,tcp,127.0.0.1,$NGINX_PORT,,80" \
        --natpf1 "cpu,tcp,127.0.0.1,$CPU_PORT,,$CPU_PORT" \
        --natpf1 "mem,tcp,127.0.0.1,$MEM_PORT,,$MEM_PORT" \
        --natpf1 "io,tcp,127.0.0.1,$IO_PORT,,$IO_PORT"
    # Host I/O cache desligado: o limite de disco e as medições de IO não passam pelo page cache do host
    VBoxManage storagectl "$VM_NAME" --name SATA --add sata --controller IntelAhci \
        --portcount 1 --hostiocache off
    VBoxManage bandwidthctl "$VM_NAME" add "$BW_GROUP" --type disk --limit 1000M
    VBoxManage storageattach "$VM_NAME" --storagectl SATA --port 0 --device 0 \
        --type hdd --medium "$VM_DISK"
fi

# --- 2. Acesso SSH -------------------------------------------------------------
if [[ ! -f "$SSH_KEY" ]]; then
    log "Gerando chave $SSH_KEY"
    ssh-keygen -t ed25519 -N "" -C "poi-vm" -f "$SSH_KEY" >/dev/null
fi

vm_start

if ! vm_wait_ssh 20; then
    log "Chave ainda não instalada; esperando o sshd aceitar senha"
    pw_ssh() {
        SSHPASS="$VM_PASS" sshpass -e ssh -p "$SSH_PORT" -o ConnectTimeout=5 \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile="$VM_KNOWN_HOSTS" \
            -o PubkeyAuthentication=no -o LogLevel=ERROR "$VM_USER@127.0.0.1" "$@"
    }
    ok=0
    for _ in $(seq 1 60); do
        if pw_ssh true 2>/dev/null; then ok=1; break; fi
        sleep 3
    done
    if (( ok == 0 )); then
        cat >&2 <<EOF

ERRO: o SSH da VM não respondeu em ~3 min (a imagem pode estar sem openssh-server).
Abra o console da VM (VirtualBox → $VM_NAME → Mostrar), entre como $VM_USER / $VM_PASS e rode:

    sudo apt-get update && sudo apt-get install -y openssh-server
    sudo systemctl enable --now ssh

Depois rode de novo: ./vm/setup_vm.sh
EOF
        exit 1
    fi
    # Única conexão com senha: instala a chave e o sudo sem senha
    log "Instalando chave pública e sudo sem senha"
    pubkey="$(cat "$SSH_KEY.pub")"
    # a senha do sudo vai pelo stdin (não aparece em argv)
    pw_ssh "set -e
        read -r PW
        mkdir -p ~/.ssh && chmod 700 ~/.ssh
        grep -qxF '$pubkey' ~/.ssh/authorized_keys 2>/dev/null || echo '$pubkey' >> ~/.ssh/authorized_keys
        chmod 600 ~/.ssh/authorized_keys
        printf '%s\n' \"\$PW\" | sudo -S -p '' sh -c 'echo \"$VM_USER ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/90-$VM_USER && chmod 440 /etc/sudoers.d/90-$VM_USER'" \
        <<<"$VM_PASS"
    vm_wait_ssh 30 || die "chave instalada mas o SSH por chave falhou"
fi
vm_ssh 'sudo -n true' || die "sudo sem senha não está configurado na VM"

# --- 3. Pacotes e Miniforge -------------------------------------------------------
log "Configurando pacotes na VM"
vm_ssh 'bash -s' <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# atualizações automáticas atrapalham as medições (CPU/disco em segundo plano)
sudo systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
sudo systemctl stop apt-daily.service apt-daily-upgrade.service >/dev/null 2>&1 || true
need=""
for p in rsync nginx curl; do dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"; done
if [[ -n "$need" ]]; then
    sudo apt-get -o DPkg::Lock::Timeout=300 update -qq
    sudo apt-get -o DPkg::Lock::Timeout=300 install -y -qq $need >/dev/null
fi
sudo systemctl enable --now nginx >/dev/null 2>&1
if [[ ! -x ~/miniforge3/bin/conda ]]; then
    curl -fsSL -o /tmp/Miniforge3.sh \
        https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh
    bash /tmp/Miniforge3.sh -b -p ~/miniforge3 >/dev/null
    rm -f /tmp/Miniforge3.sh
fi
echo "VM: $(lsb_release -ds), kernel $(uname -r), $(nproc) vCPU, $(free -m | awk '/Mem:/{print $2}') MB RAM"
echo "conda: $(~/miniforge3/bin/conda --version)"
df -h / | tail -1
EOF

curl -fsS -o /dev/null -w "nginx via NAT (localhost:$NGINX_PORT): HTTP %{http_code}\n" "http://127.0.0.1:$NGINX_PORT/"
log "Afinidade do processo da VM: $(vm_affinity)"
log "VM pronta. SSH: ssh -i $SSH_KEY -p $SSH_PORT $VM_USER@127.0.0.1"
