"""Eventos da VM numa rodada (roda na VM): OOM kills, workers mortos e reinícios do serviço.

  vm_events.py snapshot --service poi-mem > /tmp/ev0.json
  vm_events.py diff --service poi-mem --before /tmp/ev0.json    → JSON com os eventos desde o snapshot

Workers mortos são reiniciados pelo próprio uvicorn (o systemd não vê): contados pela mensagem
"Child process [pid] died" no journal da unit e separados pela causa:
  - oom: o PID está entre as vítimas do OOM killer do kernel ("Killed process PID (...)");
  - healthcheck: o worker não respondeu ao ping do supervisor do uvicorn em timeout_worker_healthcheck
    (5 s) e levou SIGKILL (ex.: travado em falhas de página sob thrashing). O uvicorn registra o mesmo
    "Child process died" nos dois casos.
NRestarts conta reinícios do serviço inteiro pelo systemd. swap_used_mb no snapshot = swap no início da
medição (já depois do warm-up); o swap logo após o reset fica em meta.json (swap_after_reset_mb).
"""
import argparse
import json
import re
import subprocess
import sys
import time


def sh(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def oom_counter():
    with open("/proc/vmstat") as f:
        for line in f:
            if line.startswith("oom_kill "):
                return int(line.split()[1])
    return 0


def swap_used_mb():
    info = {}
    with open("/proc/meminfo") as f:
        for line in f:
            k, v = line.split(":")
            info[k] = int(v.split()[0])
    return (info["SwapTotal"] - info["SwapFree"]) / 1024


def snapshot(service):
    props = dict(l.split("=", 1) for l in sh("systemctl", "show", "-p", "NRestarts,MainPID", service).split())
    main = props.get("MainPID", "0")
    workers = sorted(int(p) for p in sh("pgrep", "-P", main).split()) if main != "0" else []
    return {"t": time.time(), "nrestarts": int(props.get("NRestarts", 0)), "main_pid": int(main),
            "workers": workers, "oom_kill": oom_counter(), "swap_used_mb": round(swap_used_mb(), 1)}


def diff(service, before):
    after = snapshot(service)
    since = f"@{int(before['t'])}"
    kern = sh("journalctl", "-k", "--since", since, "-o", "cat", "--no-pager")
    victims = re.findall(r"Killed process (\d+) \(([^)]+)\)", kern)
    unit = sh("journalctl", "-u", service, "--since", since, "-o", "cat", "--no-pager")
    died = [int(p) for p in re.findall(r"Child process \[(\d+)\] died", unit)]
    oom_pids = {int(p) for p, _ in victims}
    return {
        "oom_kills": after["oom_kill"] - before["oom_kill"],
        "oom_victims": [{"pid": int(p), "name": n} for p, n in victims],
        "worker_deaths": len(died),
        "worker_deaths_oom": sum(p in oom_pids for p in died),
        "worker_deaths_healthcheck": sum(p not in oom_pids for p in died),
        "swap_used_at_start_mb": before.get("swap_used_mb"),
        "service_restarts": after["nrestarts"] - before["nrestarts"],
        "main_pid_changed": after["main_pid"] != before["main_pid"],
        "workers_before": before["workers"], "workers_after": after["workers"],
        "kernel_oom_lines": [l for l in kern.splitlines() if "out of memory" in l.lower() or "Killed process" in l][:20],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("cmd", choices=["snapshot", "diff"])
    ap.add_argument("--service", required=True)
    ap.add_argument("--before")
    a = ap.parse_args()
    if a.cmd == "snapshot":
        print(json.dumps(snapshot(a.service)))
    else:
        print(json.dumps(diff(a.service, json.load(open(a.before)))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
