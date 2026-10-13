"""Coletor de métricas (roda na VM): amostra psutil a cada --interval s e grava CSV até SIGTERM/SIGINT.

Colunas: timestamp (epoch), CPU total e por núcleo (%), iowait (%), frequência por núcleo (MHz, se
disponível), memória e swap (MB), pressão de memória do /proc/vmstat (páginas de swap in/out, falhas de
página major, OOM kills), disco do / (MB/s, ops/s e %util = tempo ocupado do /proc/diskstats), rede
(taxas por segundo, calculadas entre amostras), CPU/RSS somados dos
processos da app (cmdline contém --match) e de cada --group nome=padrão. Com --top, o processo fora dos
grupos que mais usou CPU no intervalo (para identificar ruído no host).
"""
import argparse
import csv
import signal
import sys
import time

import psutil

MB = 1024 * 1024
stop = False


def _stop(*_):
    global stop
    stop = True


def app_processes(match, cache):
    """Processos cujo cmdline contém `match` e seus descendentes (workers do uvicorn).
    Mantém os objetos entre amostras para cpu_percent ser incremental."""
    found = []
    for p in psutil.process_iter(["pid", "cmdline"]):
        try:
            cmd = " ".join(p.info["cmdline"] or [])
            if match in cmd and "collector.py" not in cmd:
                found.append(p)
                found.extend(p.children(recursive=True))
        except psutil.Error:
            continue
    alive = {}
    for p in found:
        proc = cache.get(p.pid)
        if proc is None:
            proc = p
            try:
                proc.cpu_percent(None)  # primeira chamada só inicializa
            except psutil.Error:
                continue
        alive[p.pid] = proc
    return alive


VMSTAT_KEYS = ("pswpin", "pswpout", "pgmajfault", "pgfault", "oom_kill")


def vmstat():
    out = {}
    with open("/proc/vmstat") as f:
        for line in f:
            k, v = line.split()
            if k in VMSTAT_KEYS:
                out[k] = int(v)
    return out


def root_disk():
    """Disco inteiro que contém o / (ex. sda2 → sda, nvme0n1p3 → nvme0n1)."""
    dev = next((p.device for p in psutil.disk_partitions() if p.mountpoint == "/"), "")
    name = dev.rsplit("/", 1)[-1]
    disks = psutil.disk_io_counters(perdisk=True)
    for cand in (name.rstrip("0123456789").rstrip("p") if "nvme" in name else name.rstrip("0123456789"), name):
        if cand in disks:
            return cand
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--match", default="uvicorn", help="substring do cmdline dos processos da app")
    ap.add_argument("--group", action="append", default=[], metavar="NOME=PADRÃO",
                    help="grupo extra de processos (colunas NOME_nproc, NOME_cpu_pct, NOME_rss_mb)")
    ap.add_argument("--top", action="store_true", help="registra o processo fora dos grupos com mais CPU")
    args = ap.parse_args()
    groups = {"app": args.match}
    for g in args.group:
        name, pat = g.split("=", 1)
        groups[name] = pat

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    ncpu = psutil.cpu_count()
    header = (
        ["timestamp", "cpu_pct"]
        + [f"cpu{i}_pct" for i in range(ncpu)]
        + ["cpu_iowait_pct", "mem_total_mb", "mem_used_mb", "mem_available_mb", "swap_used_mb",
           "swapin_mb_s", "swapout_mb_s",
           "pswpin_pg_s", "pswpout_pg_s", "pgmajfault_s", "pgfault_s", "oom_kill",
           "disk_read_mb_s", "disk_write_mb_s", "disk_read_ops_s", "disk_write_ops_s", "disk_util_pct",
           "net_rx_mb_s", "net_tx_mb_s"]
        + [f"{g}_{c}" for g in groups for c in ("nproc", "cpu_pct", "rss_mb")]
    )
    freqs = psutil.cpu_freq(percpu=True) or []
    has_freq = len(freqs) == ncpu and any(f.current for f in freqs)
    if has_freq:
        header += [f"cpu{i}_mhz" for i in range(ncpu)]
    if args.top:
        header += ["top_other", "top_other_cpu_pct"]
        others = {}

    psutil.cpu_percent(None, percpu=True)
    psutil.cpu_times_percent(None)
    procs = {g: app_processes(pat, {}) for g, pat in groups.items()}
    prev_t = time.time()
    prev_disk = psutil.disk_io_counters()
    prev_net = psutil.net_io_counters()
    prev_swap = psutil.swap_memory()
    prev_vms = vmstat()
    rdisk = root_disk()
    prev_busy = psutil.disk_io_counters(perdisk=True)[rdisk].busy_time if rdisk else 0

    with open(args.out, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(header)
        next_t = prev_t + args.interval
        while not stop:
            time.sleep(max(0.0, next_t - time.time()))
            next_t += args.interval
            now = time.time()
            dt = now - prev_t
            percpu = psutil.cpu_percent(None, percpu=True)
            times = psutil.cpu_times_percent(None)
            vm = psutil.virtual_memory()
            sw = psutil.swap_memory()
            disk = psutil.disk_io_counters()
            net = psutil.net_io_counters()
            vms = vmstat()
            busy = psutil.disk_io_counters(perdisk=True)[rdisk].busy_time if rdisk else 0
            dv = lambda k: (vms.get(k, 0) - prev_vms.get(k, 0)) / dt

            gcols = []
            for g, pat in groups.items():
                procs[g] = app_processes(pat, procs[g])
                cpu = rss = 0.0
                for p in list(procs[g].values()):
                    try:
                        cpu += p.cpu_percent(None)
                        rss += p.memory_info().rss
                    except psutil.Error:
                        procs[g].pop(p.pid, None)
                gcols += [len(procs[g]), f"{cpu:.1f}", f"{rss / MB:.1f}"]
            extra = []
            if has_freq:
                extra += [f"{f.current:.0f}" for f in psutil.cpu_freq(percpu=True)]
            if args.top:
                grouped = {pid for d in procs.values() for pid in d}
                best, best_cpu, alive = "", 0.0, {}
                for p in psutil.process_iter(["name"]):
                    if p.pid in grouped or p.pid == psutil.Process().pid:
                        continue
                    proc = others.get(p.pid, p)
                    try:
                        c = proc.cpu_percent(None) if p.pid in others else (proc.cpu_percent(None) and 0.0)
                    except psutil.Error:
                        continue
                    alive[p.pid] = proc
                    if c > best_cpu:
                        best, best_cpu = p.info["name"], c
                others = alive
                extra += [best, f"{best_cpu:.1f}"]

            w.writerow(
                [f"{now:.3f}", f"{sum(percpu) / len(percpu):.1f}"]
                + [f"{c:.1f}" for c in percpu]
                + [f"{getattr(times, 'iowait', 0.0):.1f}",
                   f"{vm.total / MB:.0f}", f"{(vm.total - vm.available) / MB:.1f}",
                   f"{vm.available / MB:.1f}", f"{sw.used / MB:.1f}",
                   f"{(sw.sin - prev_swap.sin) / MB / dt:.2f}", f"{(sw.sout - prev_swap.sout) / MB / dt:.2f}",
                   f"{dv('pswpin'):.1f}", f"{dv('pswpout'):.1f}", f"{dv('pgmajfault'):.1f}", f"{dv('pgfault'):.0f}",
                   vms.get("oom_kill", 0) - prev_vms.get("oom_kill", 0),
                   f"{(disk.read_bytes - prev_disk.read_bytes) / MB / dt:.3f}",
                   f"{(disk.write_bytes - prev_disk.write_bytes) / MB / dt:.3f}",
                   f"{(disk.read_count - prev_disk.read_count) / dt:.1f}",
                   f"{(disk.write_count - prev_disk.write_count) / dt:.1f}",
                   f"{min(100.0, (busy - prev_busy) / (dt * 1000) * 100):.1f}",
                   f"{(net.bytes_recv - prev_net.bytes_recv) / MB / dt:.3f}",
                   f"{(net.bytes_sent - prev_net.bytes_sent) / MB / dt:.3f}"]
                + gcols + extra
            )
            f.flush()
            prev_t, prev_disk, prev_net, prev_swap, prev_vms, prev_busy = now, disk, net, sw, vms, busy
    return 0


if __name__ == "__main__":
    sys.exit(main())
