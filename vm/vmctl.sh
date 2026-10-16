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

# k6 instalado pelo bootstrap.sh
[[ -d "$HOME/.local/bin" && ":$PATH:" != *":$HOME/.local/bin:"* ]] && PATH="$HOME/.local/bin:$PATH"

VM_CPUSET="${VM_CPUSET:-}"   # vazio = sem afinidade
K6_CPUSET="${K6_CPUSET:-}"
HOST_RAM_MARGIN_MB=1536      # folga de RAM no host além da RAM da VM
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
    rsync -a --copy-links --delete -e "ssh ${SSH_OPTS[*]}" "${@:1:$#-1}" "$VM_USER@127.0.0.1:$dest"
}

# vm_fetch <caminho-remoto> <destino-local>
vm_fetch() { rsync -a -e "ssh ${SSH_OPTS[*]}" "$VM_USER@127.0.0.1:$1" "$2"; }

vm_exists() { VBoxManage showvminfo "$VM_NAME" >/dev/null 2>&1; }

# Disco anexado à VM (controlador SATA, porta 0), lido da própria VM: vale para a VM criada pelo
# setup_vm.sh (VDI clonado) e para a importada do OVA (VMDK ou VDI, em qualquer pasta).
vm_disk() {
    VBoxManage showvminfo "$VM_NAME" --machinereadable 2>/dev/null | sed -n 's/^"SATA-0-0"="\(.*\)"$/\1/p'
}

# cpuset_ids <lista>: expande uma lista do taskset ("0-3,8") em "0 1 2 3 8"; falha se o formato for inválido
cpuset_ids() {
    local part out=() parts
    IFS=, read -ra parts <<<"$1"
    for part in "${parts[@]}"; do
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then out+=($(seq "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"))
        elif [[ "$part" =~ ^[0-9]+$ ]]; then out+=("$part")
        else return 1; fi
    done
    echo "${out[@]}"
}

# cpuset_check <nome> <lista>: lista vazia = sem afinidade; senão todas as CPUs precisam existir neste host
cpuset_check() {
    local name="$1" set="$2" n ids id
    [[ -z "$set" ]] && return 0
    n=$(nproc --all)
    ids="$(cpuset_ids "$set")" || die "$name='$set' inválido no .env (formato do taskset, ex. 0-3 ou 0,2,4-6; vazio = sem afinidade)"
    for id in $ids; do
        (( id < n )) || die "$name='$set' inclui a CPU $id, mas este host tem $n CPU(s) (0-$((n - 1))). Ajuste ou deixe vazio no .env"
    done
    taskset -c "$set" true 2>/dev/null || die "$name='$set': CPUs indisponíveis para este processo (taskset falhou)"
}

# Prefixo de afinidade do k6 e do coletor do host: "${K6_PIN[@]}" comando ... (vazio = sem afinidade).
# Array e não função: com "comando &" o $! é o próprio processo (com uma função seria uma subshell, e o kill não o alcançaria).
K6_PIN=()
[[ -n "$K6_CPUSET" ]] && K6_PIN=(taskset -c "$K6_CPUSET")

# repo_commit [dir]: commit curto do repositório (+ "-dirty" se dir tiver mudanças); "sem commit" fora de um clone git
repo_commit() {
    local c
    c="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null)" || { echo "sem commit"; return 0; }
    if [[ -n "${1:-}" ]] && ! git -C "$REPO_ROOT" diff --quiet HEAD -- "$1" 2>/dev/null; then c="$c-dirty"; fi
    echo "$c"
}

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

# Liga em modo headless com o processo da VM (todas as threads) fixado em VM_CPUSET (se definido).
# VBoxHeadless é iniciado diretamente (não via VBoxSVC) para herdar a afinidade, e com setsid:
# ele salva o estado da VM ao receber SIGHUP, o que aconteceria ao fechar o terminal/tmux de origem.
vm_start() {
    if vm_running; then log "VM já está ligada"; vm_pin; return 0; fi
    cpuset_check VM_CPUSET "$VM_CPUSET"
    log "Ligando $VM_NAME (headless, afinidade ${VM_CPUSET:-nenhuma})"
    mkdir -p "$VM_WORKDIR"
    local attempt i pin=()
    [[ -n "$VM_CPUSET" ]] && pin=(taskset -c "$VM_CPUSET")
    for attempt in 1 2 3; do
        setsid nohup "${pin[@]}" VBoxHeadless --startvm "$VM_NAME" --vrde off \
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
    [[ -n "$VM_CPUSET" ]] || return 0
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
    local cpus="$1" mem="$2" bw="${3:-}" disk
    vm_running && die "vm_set_resources exige a VM desligada"
    disk="$(vm_disk)"
    [[ -n "$disk" && "$disk" != none ]] || die "nenhum disco no controlador SATA, porta 0, da VM $VM_NAME (rode ./vm/setup_vm.sh --existing)"
    log "Recursos: ${cpus} vCPU, ${mem} MB RAM, disco ${bw:-sem limite}"
    VBoxManage modifyvm "$VM_NAME" --cpus "$cpus" --memory "$mem"
    if [[ -n "$bw" ]]; then
        VBoxManage bandwidthctl "$VM_NAME" set "$BW_GROUP" --limit "$bw"
        VBoxManage storageattach "$VM_NAME" --storagectl SATA --port 0 --device 0 \
            --type hdd --medium "$disk" --bandwidthgroup "$BW_GROUP"
    else
        VBoxManage storageattach "$VM_NAME" --storagectl SATA --port 0 --device 0 \
            --type hdd --medium "$disk" --bandwidthgroup none
    fi
    sleep 2
}

# Configuração atual em JSON (para meta.json)
vm_config_json() {
    local info bw
    info="$(VBoxManage showvminfo "$VM_NAME" --machinereadable)"
    bw="$(VBoxManage bandwidthctl "$VM_NAME" list --machinereadable 2>/dev/null \
          | sed -n 's/^BandwidthGroup0=.*,\([0-9]*\)$/\1/p' | head -1)"
    local attached cfg hio
    cfg="$(sed -n 's/^CfgFile="\(.*\)"/\1/p' <<<"$info")"
    # o grupo associado ao disco e o cache de I/O do host só aparecem no .vbox
    attached="$(grep -o 'AttachedDevice type="HardDisk"[^>]*bandwidthGroup="[^"]*"' "$cfg" \
                | sed 's/.*bandwidthGroup="\([^"]*\)"/\1/' || true)"
    [[ -z "$attached" ]] && bw=""
    hio="$(grep -o '<StorageController name="SATA"[^>]*useHostIOCache="[a-z]*"' "$cfg" \
           | sed 's/.*useHostIOCache="\([a-z]*\)"/\1/' || true)"
    case "$hio" in false) hio=off ;; true) hio=on ;; *) hio=desconhecido ;; esac
    # vm_affinity: afinidade efetiva do processo da VM; vm_cpuset/k6_affinity: o configurado no .env ("none" = sem afinidade)
    printf '{"vcpus": %s, "ram_mb": %s, "disk_bw_group": "%s", "disk_bw_bytes_per_sec": %s, "host_io_cache": "%s", "vm_affinity": "%s", "vm_cpuset": "%s", "k6_affinity": "%s", "host_cpus": %s}' \
        "$(sed -n 's/^cpus=//p' <<<"$info")" \
        "$(sed -n 's/^memory=//p' <<<"$info")" \
        "${attached:-none}" "${bw:-null}" "$hio" "$(vm_affinity)" "${VM_CPUSET:-none}" "${K6_CPUSET:-none}" "$(nproc --all)"
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
    local need="$1" margin="${2:-$HOST_RAM_MARGIN_MB}" avail
    avail=$(( $(sed -n 's/^MemAvailable: *\([0-9]*\).*/\1/p' /proc/meminfo) / 1024 ))
    vm_running && need=0
    if (( avail < need + margin )); then
        log "ERRO: RAM disponível no host ${avail} MB < necessário $((need + margin)) MB (VM ${need} + folga ${margin}). Feche programas (ex. Chrome) e tente de novo."
        return 1
    fi
    log "RAM do host ok: ${avail} MB disponíveis (necessário $((need + margin)) MB)"
}

# host_capacity: "cpus ram_mb" que o host pode dar à VM: CPUs (as de VM_CPUSET, ou nproc) e MemAvailable
# menos a folga; com a VM ligada, a RAM dela conta como livre (ela é desligada antes de aplicar um cenário).
host_capacity() {
    local cpus avail
    if [[ -n "$VM_CPUSET" ]]; then cpus=$(wc -w <<<"$(cpuset_ids "$VM_CPUSET")"); else cpus=$(nproc); fi
    avail=$(( $(sed -n 's/^MemAvailable: *\([0-9]*\).*/\1/p' /proc/meminfo) / 1024 ))
    if vm_running; then
        avail=$(( avail + $(VBoxManage showvminfo "$VM_NAME" --machinereadable | sed -n 's/^memory=//p') ))
    fi
    echo "$cpus $(( avail - HOST_RAM_MARGIN_MB ))"
}

# host_check_power [quiet]: aborta (retorno 1) só em notebook na bateria. Perfil de energia diferente de
# "performance", powerprofilesctl ausente ou host sem bateria geram só aviso (o estado vai para o meta.json).
# Fonte e perfil afetam a frequência dos núcleos e, portanto, o custo por requisição. Com "quiet", só loga falhas.
PSU_DIR="${PSU_DIR:-/sys/class/power_supply}"
host_check_power() {
    local profile bat=0 ac="" st="" f
    for f in "$PSU_DIR"/*; do
        [[ -r "$f/type" ]] || continue
        case "$(cat "$f/type")" in
            Battery) bat=1; st="$(cat "$f/status" 2>/dev/null || true)" ;;
            Mains) if [[ "$(cat "$f/online" 2>/dev/null)" == 1 ]]; then ac=1; else ac="${ac:-0}"; fi ;;
            USB) [[ "$(cat "$f/online" 2>/dev/null)" == 1 ]] && ac=1 ;;   # carregador USB-C
        esac
    done
    if (( bat )) && { [[ "$ac" == 0 ]] || { [[ -z "$ac" ]] && [[ "$st" == Discharging ]]; }; }; then
        log "ERRO: notebook na bateria; conecte o carregador"
        return 1
    fi
    [[ "${1:-}" == quiet ]] && return 0
    if command -v powerprofilesctl >/dev/null; then
        profile="$(powerprofilesctl get 2>/dev/null || echo desconhecido)"
        [[ "$profile" == performance ]] \
            || log "AVISO: perfil de energia é '$profile' (recomendado: powerprofilesctl set performance); seguindo"
    else
        profile="indisponível"
        log "AVISO: powerprofilesctl não existe neste host; perfil de energia não verificado; seguindo"
    fi
    if (( bat )); then log "Energia: notebook na tomada, perfil $profile"
    else log "Energia: host sem bateria, perfil $profile"; fi
}
