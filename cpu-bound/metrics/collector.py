"""Coletor de métricas (roda na VM): amostra psutil a cada --interval s e grava CSV até SIGTERM/SIGINT.

Colunas: timestamp (epoch), CPU total e por núcleo (%), memória e swap (MB), taxas de disco e rede
(por segundo, calculadas entre amostras) e CPU/RSS somados dos processos da app (cmdline contém --match).
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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", required=True)
    ap.add_argument("--interval", type=float, default=1.0)
    ap.add_argument("--match", default="uvicorn", help="substring do cmdline dos processos da app")
    args = ap.parse_args()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    ncpu = psutil.cpu_count()
    header = (
        ["timestamp", "cpu_pct"]
        + [f"cpu{i}_pct" for i in range(ncpu)]
        + ["cpu_iowait_pct", "mem_total_mb", "mem_used_mb", "mem_available_mb", "swap_used_mb",
           "swapin_mb_s", "swapout_mb_s",
           "disk_read_mb_s", "disk_write_mb_s", "disk_read_ops_s", "disk_write_ops_s",
           "net_rx_mb_s", "net_tx_mb_s",
           "app_nproc", "app_cpu_pct", "app_rss_mb"]
    )

    psutil.cpu_percent(None, percpu=True)
    psutil.cpu_times_percent(None)
    procs = app_processes(args.match, {})
    prev_t = time.time()
    prev_disk = psutil.disk_io_counters()
    prev_net = psutil.net_io_counters()
    prev_swap = psutil.swap_memory()

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

            procs = app_processes(args.match, procs)
            app_cpu = app_rss = 0.0
            for p in list(procs.values()):
                try:
                    app_cpu += p.cpu_percent(None)
                    app_rss += p.memory_info().rss
                except psutil.Error:
                    procs.pop(p.pid, None)

            w.writerow(
                [f"{now:.3f}", f"{sum(percpu) / len(percpu):.1f}"]
                + [f"{c:.1f}" for c in percpu]
                + [f"{getattr(times, 'iowait', 0.0):.1f}",
                   f"{vm.total / MB:.0f}", f"{(vm.total - vm.available) / MB:.1f}",
                   f"{vm.available / MB:.1f}", f"{sw.used / MB:.1f}",
                   f"{(sw.sin - prev_swap.sin) / MB / dt:.2f}", f"{(sw.sout - prev_swap.sout) / MB / dt:.2f}",
                   f"{(disk.read_bytes - prev_disk.read_bytes) / MB / dt:.3f}",
                   f"{(disk.write_bytes - prev_disk.write_bytes) / MB / dt:.3f}",
                   f"{(disk.read_count - prev_disk.read_count) / dt:.1f}",
                   f"{(disk.write_count - prev_disk.write_count) / dt:.1f}",
                   f"{(net.bytes_recv - prev_net.bytes_recv) / MB / dt:.3f}",
                   f"{(net.bytes_sent - prev_net.bytes_sent) / MB / dt:.3f}",
                   len(procs), f"{app_cpu:.1f}", f"{app_rss / MB:.1f}"]
            )
            f.flush()
            prev_t, prev_disk, prev_net, prev_swap = now, disk, net, sw
    return 0


if __name__ == "__main__":
    sys.exit(main())
