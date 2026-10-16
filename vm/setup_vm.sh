#!/usr/bin/env bash
# Prepara a VM única usada pelas 3 aplicações. Idempotente: pode ser rodado de novo.
#   ./vm/setup_vm.sh              cria a VM a partir do BASE_VDI (clone; o original nunca é alterado),
#                                 ou usa a VM se ela já existir (aí o BASE_VDI não é exigido)
#   ./vm/setup_vm.sh --existing   exige a VM já existente (ex. importada do poi-vm.ova) e confere os serviços das apps
# Em ambos: confere/corrige NAT (port forwards), cache de I/O do host e grupo io_limit; checa as portas do host;
# instala a chave SSH (a senha é usada uma única vez, via SSH_ASKPASS) e sudo sem senha; instala pacotes na VM.
set -euo pipefail
source "$(dirname "$0")/vmctl.sh"

EXISTING=0
case "${1:-}" in
    --existing) EXISTING=1 ;;
    "") ;;
    *) die "uso: $0 [--existing]" ;;
esac

for cmd in VBoxManage VBoxHeadless ssh ssh-keygen rsync curl setsid; do
    command -v "$cmd" >/dev/null || die "comando ausente: $cmd (rode ./bootstrap.sh para ver o que instalar)"
done
mkdir -p "$VM_WORKDIR"

# regras de NAT: nome,protocolo,ip_host,porta_host,ip_convidado,porta_convidado
NAT_RULES=("ssh,tcp,127.0.0.1,$SSH_PORT,,22" "nginx,tcp,127.0.0.1,$NGINX_PORT,,80"
           "cpu,tcp,127.0.0.1,$CPU_PORT,,$CPU_PORT" "mem,tcp,127.0.0.1,$MEM_PORT,,$MEM_PORT"
           "io,tcp,127.0.0.1,$IO_PORT,,$IO_PORT")

# --- 1. VM -------------------------------------------------------------------
if vm_exists; then
    log "VM $VM_NAME já existe; usando a existente"
elif (( EXISTING )); then
    die "VM $VM_NAME não existe. Importe o OVA antes (VBoxManage import poi-vm.ova --vsys 0 --vmname $VM_NAME) ou ajuste VM_NAME no .env"
else
    [[ -n "${BASE_VDI:-}" && -f "$BASE_VDI" ]] || die "BASE_VDI não encontrado: '${BASE_VDI:-}' (ajuste o .env ou importe o OVA e use --existing)"
    new_disk="$VM_WORKDIR/$VM_NAME.vdi"
    if [[ ! -f "$new_disk" ]]; then
        log "Clonando $BASE_VDI → $new_disk"
        VBoxManage clonemedium disk "$BASE_VDI" "$new_disk" --format VDI
    fi
    log "Criando VM $VM_NAME"
    VBoxManage createvm --name "$VM_NAME" --ostype Ubuntu22_LTS_64 \
        --basefolder "$VM_WORKDIR" --register
    VBoxManage modifyvm "$VM_NAME" \
        --cpus 2 --memory 2048 --ioapic on --paravirt-provider kvm \
        --graphicscontroller vmsvga --vram 16 --audio-enabled off --usb-ohci off \
        --boot1 disk --boot2 none --boot3 none --boot4 none --nic1 nat
    VBoxManage storagectl "$VM_NAME" --name SATA --add sata --controller IntelAhci --portcount 1
    VBoxManage storageattach "$VM_NAME" --storagectl SATA --port 0 --device 0 --type hdd --medium "$new_disk"
fi

# --- 2. Configuração da VM: confere e corrige ---------------------------------
cfg_problems() {
    local info cfg r name hp line
    info="$(VBoxManage showvminfo "$VM_NAME" --machinereadable)"
    cfg="$(sed -n 's/^CfgFile="\(.*\)"/\1/p' <<<"$info")"
    grep -q '^storagecontrollername[0-9]*="SATA"$' <<<"$info" || { echo "nosata"; return; }
    [[ -n "$(vm_disk)" && "$(vm_disk)" != none ]] || { echo "nodisk"; return; }
    [[ "$(sed -n 's/^nic1="\(.*\)"/\1/p' <<<"$info")" == nat ]] || echo "nic"
    for r in "${NAT_RULES[@]}"; do
        grep -q "^Forwarding([0-9]*)=\"$r\"$" <<<"$info" || echo "nat:${r%%,*}"
    done
    # regra com outro nome ocupando uma das nossas portas do host (ex. criada pela interface)
    while IFS= read -r line; do
        name="${line%%,*}"; hp="$(cut -d, -f4 <<<"$line")"
        case " $SSH_PORT $NGINX_PORT $CPU_PORT $MEM_PORT $IO_PORT " in *" $hp "*)
            case " ssh nginx cpu mem io " in *" $name "*) ;; *) echo "natother:$name" ;; esac ;;
        esac
    done < <(sed -n 's/^Forwarding([0-9]*)="\(.*\)"$/\1/p' <<<"$info")
    grep -q '<StorageController name="SATA"[^>]*useHostIOCache="false"' "$cfg" || echo "hostiocache"
    VBoxManage bandwidthctl "$VM_NAME" list --machinereadable 2>/dev/null \
        | grep -q "^BandwidthGroup[0-9]*=\"$BW_GROUP\",Disk," || echo "bwgroup"
}

mapfile -t problems < <(cfg_problems)
[[ " ${problems[*]} " == *" nosata "* ]] && die "a VM $VM_NAME não tem controlador de disco chamado SATA (esperado no OVA e no setup)"
[[ " ${problems[*]} " == *" nodisk "* ]] && die "a VM $VM_NAME não tem disco no controlador SATA, porta 0"
if (( ${#problems[@]} )); then
    log "Corrigindo configuração da VM: ${problems[*]}"
    vm_stop
    for p in "${problems[@]}"; do
        case "$p" in
            nic) VBoxManage modifyvm "$VM_NAME" --nic1 nat ;;
            natother:*) VBoxManage modifyvm "$VM_NAME" --natpf1 delete "${p#natother:}" ;;
        esac
    done
    for p in "${problems[@]}"; do
        case "$p" in
            nat:*)
                VBoxManage modifyvm "$VM_NAME" --natpf1 delete "${p#nat:}" >/dev/null 2>&1 || true
                for r in "${NAT_RULES[@]}"; do
                    [[ "${r%%,*}" == "${p#nat:}" ]] && VBoxManage modifyvm "$VM_NAME" --natpf1 "$r"
                done ;;
            # Host I/O cache desligado: o limite de disco e as medições de IO não passam pelo page cache do host
            hostiocache) VBoxManage storagectl "$VM_NAME" --name SATA --hostiocache off ;;
            bwgroup) VBoxManage bandwidthctl "$VM_NAME" add "$BW_GROUP" --type disk --limit 1000M ;;
        esac
    done
    mapfile -t problems < <(cfg_problems)
    (( ${#problems[@]} == 0 )) || die "configuração ainda com problemas: ${problems[*]}"
fi
log "Configuração ok: NAT ($(printf '%s ' "${NAT_RULES[@]}" | sed 's/,tcp,127.0.0.1,/:/g; s/,,/→/g')), host I/O cache off, grupo $BW_GROUP"

# --- 3. Portas do host -----------------------------------------------------------
if vm_running; then
    log "VM ligada: as portas $SSH_PORT $NGINX_PORT $CPU_PORT $MEM_PORT $IO_PORT estão com ela"
else
    busy=0
    for port in $SSH_PORT $NGINX_PORT $CPU_PORT $MEM_PORT $IO_PORT; do
        line="$(ss -Hltnp "sport = :$port" 2>/dev/null | head -1)"
        if [[ -z "$line" ]] && ! command -v ss >/dev/null; then
            (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && line="em uso"
        fi
        if [[ -n "$line" ]]; then
            who="$(grep -o 'users:(("[^"]*",pid=[0-9]*' <<<"$line" | sed 's/users:(("\(.*\)",pid=\(.*\)/\1 (pid \2)/')"
            log "ERRO: porta $port do host ocupada por ${who:-um processo de outro usuário (veja: ss -ltn sport = :$port)}"
            busy=1
        fi
    done
    (( busy == 0 )) || die "libere as portas acima e rode de novo (SSH_PORT e NGINX_PORT podem ser trocadas no .env; $CPU_PORT-$IO_PORT são as portas das apps e não mudam)"
    log "Portas do host livres: $SSH_PORT $NGINX_PORT $CPU_PORT $MEM_PORT $IO_PORT"
fi

# --- 4. Acesso SSH -------------------------------------------------------------
if [[ ! -f "$SSH_KEY" ]]; then
    log "Gerando chave $SSH_KEY"
    mkdir -p "$(dirname "$SSH_KEY")"
    ssh-keygen -t ed25519 -N "" -C "poi-vm" -f "$SSH_KEY" >/dev/null
fi

vm_start

# Senha sem sshpass: o ssh pede a senha ao programa em SSH_ASKPASS (force; setsid tira o terminal para
# versões antigas do OpenSSH). A senha vai por variável de ambiente, nunca em argv.
ASKPASS="$(mktemp "$VM_WORKDIR/askpass.XXXXXX")"
trap 'rm -f "$ASKPASS"' EXIT
printf '#!/bin/sh\nprintf "%%s\\n" "$POI_VM_PASS"\n' >"$ASKPASS"
chmod 700 "$ASKPASS"
pw_ssh() {
    POI_VM_PASS="$VM_PASS" SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force DISPLAY="${DISPLAY:-:0}" \
        setsid -w ssh -p "$SSH_PORT" -o ConnectTimeout=5 \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile="$VM_KNOWN_HOSTS" \
        -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive \
        -o NumberOfPasswordPrompts=1 -o LogLevel=ERROR "$VM_USER@127.0.0.1" "$@"
}

log "Aguardando SSH (até ~3 min)"
mode=""
for _ in $(seq 1 60); do
    if vm_ssh true 2>/dev/null; then mode=key; break; fi
    if pw_ssh true </dev/null 2>/dev/null; then mode=password; break; fi
    sleep 3
done
if [[ -z "$mode" ]]; then
    cat >&2 <<EOF

ERRO: o SSH da VM não respondeu em ~3 min (a imagem pode estar sem openssh-server, ou a senha
de $VM_USER não é a do .env). Abra o console da VM (VirtualBox → $VM_NAME → Mostrar),
entre como $VM_USER / $VM_PASS e rode:

    sudo apt-get update && sudo apt-get install -y openssh-server
    sudo systemctl enable --now ssh

Depois rode de novo: ./vm/setup_vm.sh $( (( EXISTING )) && echo --existing)
EOF
    exit 1
fi
if [[ "$mode" == password ]]; then
    # Única conexão com senha: instala a chave e o sudo sem senha
    log "Instalando chave pública ($SSH_KEY.pub) e sudo sem senha"
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
else
    log "SSH por chave ok ($SSH_KEY)"
fi
vm_ssh 'sudo -n true' || die "sudo sem senha não está configurado na VM"

# --- 5. Pacotes e Miniforge -------------------------------------------------------
log "Configurando pacotes na VM"
vm_ssh 'bash -s' <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# atualizações automáticas atrapalham as medições (CPU/disco em segundo plano)
sudo systemctl disable --now unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
sudo systemctl stop apt-daily.service apt-daily-upgrade.service >/dev/null 2>&1 || true
need=""
for p in rsync nginx curl fio; do dpkg -s "$p" >/dev/null 2>&1 || need="$need $p"; done
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

# --- 6. Serviços das apps (só --existing: na VM criada do zero o run_experiment.sh faz o deploy) ---
if (( EXISTING )); then
    missing=0
    for sp in "poi-cpu:$CPU_PORT" "poi-mem:$MEM_PORT" "poi-io:$IO_PORT"; do
        svc="${sp%%:*}"; port="${sp#*:}"
        en="$(vm_ssh "systemctl is-enabled $svc 2>/dev/null" || true)"
        if [[ -z "$en" || "$en" == not-found ]]; then
            log "AVISO: serviço $svc não existe na VM (o run_experiment.sh da app faz o deploy)"; missing=1; continue
        fi
        ok=""
        for _ in $(seq 1 30); do
            ok="$(curl -fs "http://127.0.0.1:$port/health" || true)"; [[ -n "$ok" ]] && break; sleep 1
        done
        if [[ -n "$ok" ]]; then log "$svc: $en, $(vm_ssh "systemctl is-active $svc" || true); localhost:$port/health → $ok"
        else log "AVISO: $svc ($en) não respondeu em localhost:$port/health; veja: ssh ... 'sudo journalctl -u $svc -n 30'"; missing=1; fi
    done
    (( missing )) && log "Algum serviço não está ok; ele é (re)instalado ao rodar ./run_experiment.sh --quick s3-adequada na pasta da app"
fi

log "Afinidade do processo da VM: $(vm_affinity) (VM_CPUSET=${VM_CPUSET:-vazio, sem afinidade})"
log "VM pronta. SSH: ssh -i $SSH_KEY -p $SSH_PORT $VM_USER@127.0.0.1"
