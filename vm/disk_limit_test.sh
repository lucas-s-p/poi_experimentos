#!/usr/bin/env bash
# Verifica se o limite de disco do VirtualBox (bandwidthctl) funciona.
# Matriz: host I/O cache {off,on} × limite {sem,10M,40M}. Em cada célula, com fio (O_DIRECT,
# arquivo novo, drop_caches entre rodadas): escrita, leitura, escrita, leitura sequenciais de 15 s.
# Saída: vm/disk_limit_results.csv  (bw em MB/s)
# Ao final volta para hostiocache off, sem limite, 2 vCPU / 2 GB.
set -euo pipefail
source "$(dirname "$0")/vmctl.sh"

OUT="$REPO_ROOT/vm/disk_limit_results.csv"
echo "hostiocache,limit,round,op,bw_MBps,iops,lat_mean_ms" >"$OUT"

vm_ssh 'command -v fio >/dev/null || sudo DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 install -y -qq fio >/dev/null'

fio_run() {  # fio_run <rw> → "bw_MBps iops lat_ms"
    vm_ssh "sync; echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
        fio --name=t --filename=\$HOME/fiotest --rw=$1 --bs=1M --direct=1 --ioengine=psync \
            --size=256M --time_based --runtime=15 --output-format=json 2>/dev/null" \
    | python3 -c '
import json,sys
j=json.load(sys.stdin)["jobs"][0]; op="write" if j["write"]["io_bytes"] else "read"; d=j[op]
print("%.1f %.1f %.2f" % (d["bw_bytes"]/1e6, d["iops"], d["lat_ns"]["mean"]/1e6))'
}

for cache in off on; do
    for limit in none 10M 40M; do
        vm_stop
        VBoxManage storagectl "$VM_NAME" --name SATA --hostiocache "$cache"
        vm_set_resources 2 2048 "$([[ $limit == none ]] || echo "$limit")"
        vm_start; vm_wait_ssh 180 || die "SSH não voltou"
        sleep 10   # deixa o boot assentar
        # arquivo novo (a criação já passa pelo limite)
        vm_ssh 'rm -f ~/fiotest; fio --name=lay --filename=$HOME/fiotest --rw=write --bs=1M --direct=1 --size=256M >/dev/null 2>&1'
        for round in 1 2; do
            for op in write read; do
                read -r bw iops lat < <(fio_run "$op")
                echo "$cache,$limit,$round,$op,$bw,$iops,$lat" | tee -a "$OUT"
            done
        done
        vm_ssh 'rm -f ~/fiotest'
    done
done

vm_stop
VBoxManage storagectl "$VM_NAME" --name SATA --hostiocache off
vm_set_resources 2 2048
log "Resultados em $OUT"
