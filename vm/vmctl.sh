# Funções compartilhadas de controle da VM (VBoxManage + SSH).
# Uso: source vm/vmctl.sh   (carrega o .env da raiz do repositório)

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -f "$REPO_ROOT/.env" ]]; then
    echo "ERRO: $REPO_ROOT/.env não existe (copie de .env.example)" >&2
    return 1 2>/dev/null || exit 1
fi
set -a
# shellcheck disable=SC1091
source "$REPO_ROOT/.env"
set +a

VM_DISK="$VM_WORKDIR/$VM_NAME.vdi"
VM_KNOWN_HOSTS="$VM_WORKDIR/known_hosts"
BW_GROUP="io_limit"

SSH_OPTS=(-i "$SSH_KEY" -p "$SSH_PORT" -o BatchMode=yes -o ConnectTimeout=5
          -o StrictHostKeyChecking=no -o UserKnownHostsFile="$VM_KNOWN_HOSTS"
          -o LogLevel=ERROR
          # conexão SSH reaproveitada: RTT de ms em vez de ~200 ms (medição do offset de relógio)
          -o ControlMaster=auto -o ControlPath="$VM_WORKDIR/ssh-%C" -o ControlPersist=120
          -o ServerAliveInterval=5 -o ServerAliveCountMax=3)

log() { echo "[$(date '+%F %T')] $*" >&2; }
die() { log "ERRO: $*"; exit 1; }

vm_ssh() { ssh "${SSH_OPTS[@]}" "$VM_USER@127.0.0.1" "$@"; }

# vm_rsync <origem...> <destino-remoto>  (destino relativo ao home do usuário da VM)
vm_rsync() {
    local dest="${*: -1}"
    rsync -a --delete -e "ssh ${SSH_OPTS[*]}" "${@:1:$#-1}" "$VM_USER@127.0.0.1:$dest"
}

# vm_fetch <caminho-remoto> <destino-local>
vm_fetch() { rsync -a -e "ssh ${SSH_OPTS[*]}" "$VM_USER@127.0.0.1:$1" "$2"; }

vm_exists() { VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1; }

vm_state() {
    VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null \
        | sed -n 's/^VMState="\(.*\)"/\1/p'
}

# list runningvms não abre sessão na máquina (showvminfo abre e pode colidir com o startvm)
vm_running() { VBoxManage list runningvms | grep -q "^\"$VM_NAME\" "; }

# PID do processo VBoxHeadless desta VM
vm_pid() {
    pgrep -a -x VBoxHeadless | awk -v n="$VM_NAME" '$0 ~ "--startvm " n "( |$)" {print $1; exit}'
}

# Liga em modo headless com o processo da VM (todas as threads) fixado em VM_CPUSET.
# VBoxHeadless é iniciado diretamente (não via VBoxSVC) para herdar a afinidade.
vm_start() {
    if vm_running; then log "VM já está ligada"; vm_pin; return 0; fi
    log "Ligando $VM_NAME (headless, afinidade $VM_CPUSET)"
    local attempt i
    for attempt in 1 2 3; do
        nohup taskset -c "$VM_CPUSET" VBoxHeadless --startvm "$VM_NAME" --vrde off \
            >"$VM_WORKDIR/headless.log" 2>&1 &
        for i in $(seq 1 30); do
            vm_running && break
            kill -0 $! 2>/dev/null || break   # VBoxHeadless saiu (ex. sessão ainda travada)
            sleep 1
        done
        vm_running && break
        log "tentativa $attempt falhou: $(grep -m1 error "$VM_WORKDIR/headless.log" || true)"
        sleep 5
    done
    vm_running || die "VM não ligou (veja $VM_WORKDIR/headless.log)"
    vm_pin
}

# Confere a afinidade de todas as threads da VM. VBoxHeadless é setuid-root, então
# não dá para alterá-la depois de iniciado; ela vem herdada do taskset no lançamento.
vm_pin() {
    local aff; aff="$(vm_affinity)"
    if [[ "$aff" != "$VM_CPUSET" ]]; then
        log "aviso: afinidade da VM é '$aff' (esperado '$VM_CPUSET'); a VM foi ligada fora do vm_start? Desligue e ligue de novo."
    fi
}

# Afinidade efetiva do processo da VM (união das threads; para meta.json)
vm_affinity() {
    local pid; pid="$(vm_pid)"
    [[ -n "$pid" ]] || return 0
    sed -n 's/^Cpus_allowed_list:\s*//p' /proc/"$pid"/task/*/status 2>/dev/null | sort -u | paste -sd';'
}

# Desliga: poweroff via SSH → botão ACPI → poweroff forçado.
vm_stop() {
    vm_running || return 0
    log "Desligando $VM_NAME"
    vm_ssh 'sudo systemctl poweroff' >/dev/null 2>&1 \
        || VBoxManage controlvm "$VM_NAME" acpipowerbutton >/dev/null 2>&1 || true
    ssh "${SSH_OPTS[@]}" -O exit "$VM_USER@127.0.0.1" >/dev/null 2>&1 || true   # fecha a conexão mestre
    local i
    for i in $(seq 1 60); do
        vm_running || break
        sleep 1
    done
    if vm_running; then
        log "Desligamento ACPI expirou; forçando poweroff"
        VBoxManage controlvm "$VM_NAME" poweroff >/dev/null 2>&1 || true
    fi
    sleep 3   # liberação da sessão é assíncrona; modifyvm logo em seguida pode falhar
}

# vm_set_resources <vcpus> <ram_mb> [limite_disco, ex. 20M | vazio = sem limite]
# Exige VM desligada.
vm_set_resources() {
    local cpus="$1" mem="$2" bw="${3:-}"
    vm_running && die "vm_set_resources exige a VM desligada"
    log "Recursos: ${cpus} vCPU, ${mem} MB RAM, disco ${bw:-sem limite}"
    VBoxManage modifyvm "$VM_NAME" --cpus "$cpus" --memory "$mem"
    if [[ -n "$bw" ]]; then
        VBoxManage bandwidthctl "$VM_NAME" set "$BW_GROUP" --limit "$bw"
        VBoxManage storageattach "$VM_NAME" --storagectl SATA --port 0 --device 0 \
            --type hdd --medium "$VM_DISK" --bandwidthgroup "$BW_GROUP"
    else
        VBoxManage storageattach "$VM_NAME" --storagectl SATA --port 0 --device 0 \
            --type hdd --medium "$VM_DISK" --bandwidthgroup none
    fi
    sleep 2
}

# Configuração atual em JSON (para meta.json)
vm_config_json() {
    local info bw
    info="$(VBoxManage showvminfo "$VM_NAME" --machinereadable)"
    bw="$(VBoxManage bandwidthctl "$VM_NAME" list --machinereadable 2>/dev/null \
          | sed -n 's/^BandwidthGroup0=.*,\([0-9]*\)$/\1/p' | head -1)"
    local attached
    # o grupo associado ao disco só aparece no .vbox
    attached="$(grep -o 'AttachedDevice type="HardDisk"[^>]*bandwidthGroup="[^"]*"' \
                "$(sed -n 's/^CfgFile="\(.*\)"/\1/p' <<<"$info")" | sed 's/.*bandwidthGroup="\([^"]*\)"/\1/' || true)"
    [[ -z "$attached" ]] && bw=""
    printf '{"vcpus": %s, "ram_mb": %s, "disk_bw_group": "%s", "disk_bw_bytes_per_sec": %s, "vm_affinity": "%s", "k6_affinity": "%s"}' \
        "$(sed -n 's/^cpus=//p' <<<"$info")" \
        "$(sed -n 's/^memory=//p' <<<"$info")" \
        "${attached:-none}" "${bw:-null}" "$(vm_affinity)" "$K6_CPUSET"
}

# vm_wait_ssh [timeout_s]
vm_wait_ssh() {
    local timeout="${1:-180}" t=0
    log "Aguardando SSH (até ${timeout}s)"
    until vm_ssh true 2>/dev/null; do
        sleep 2; t=$((t + 2))
        (( t >= timeout )) && return 1
    done
    log "SSH ok (${t}s)"
}

# host_check_ram <ram_vm_mb> [folga_mb=1536]: aborta se o host não tiver RAM livre suficiente.
# Se a VM já estiver ligada, a RAM dela já está contabilizada como usada.
host_check_ram() {
    local need="$1" margin="${2:-1536}" avail
    avail=$(( $(sed -n 's/^MemAvailable: *\([0-9]*\).*/\1/p' /proc/meminfo) / 1024 ))
    vm_running && need=0
    if (( avail < need + margin )); then
        log "ERRO: RAM disponível no host ${avail} MB < necessário $((need + margin)) MB (VM ${need} + folga ${margin}). Feche programas (ex. Chrome) e tente de novo."
        return 1
    fi
    log "RAM do host ok: ${avail} MB disponíveis (necessário $((need + margin)) MB)"
}

# host_check_power: exige perfil de energia "performance" e fonte na tomada (AC).
# Ambos afetam a frequência dos núcleos e, portanto, o custo por requisição.
host_check_power() {
    local profile ac f ok=0
    profile="$(powerprofilesctl get 2>/dev/null || echo desconhecido)"
    ac="desconhecido"
    for f in /sys/class/power_supply/A*/online; do [[ -r "$f" ]] && ac="$(cat "$f")"; done
    [[ "$profile" == "performance" ]] || { log "ERRO: perfil de energia é '$profile'; rode: powerprofilesctl set performance"; ok=1; }
    [[ "$ac" == "1" ]] || { log "ERRO: notebook fora da tomada (AC=$ac); conecte o carregador"; ok=1; }
    (( ok == 0 )) && log "Energia ok: perfil $profile, na tomada"
    return "$ok"
}
