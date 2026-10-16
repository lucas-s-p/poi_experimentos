"""Auxiliares do host para os scripts de experimento (roda no env conda poi-analysis).

  scenarios <provisioning.yaml> [--only ID]   linhas "id vcpus ram_mb disk_bw unit_extra" (disk_bw/unit_extra '-' se vazio)
  config <provisioning.yaml> <demand.yaml> [--quick]   atribuições shell (eval) com app, porta e demanda
  hoststats <host_metrics.csv>                 "mean max n_over_85" da CPU total do host
  idlecheck --exclude PADRÃO [--seconds 10]   "outros_pct_1núcleo top docker(0/1)": CPU de todos os
                                               processos do host fora a VM (e este script) numa janela
  events <vm_events.json>                      resumo de uma linha dos eventos da VM (OOM, reinícios)
  meta --out ... [opções]                      grava meta.json
"""
import argparse
import csv
import json
import shlex
import sys

import yaml


def load(path):
    with open(path) as f:
        return yaml.safe_load(f)


def cmd_scenarios(a):
    prov = load(a.provisioning)
    fixed = prov.get("fixed", {})
    for s in prov["scenarios"]:
        if a.only and s["id"] != a.only:
            continue
        s = {**fixed, **s}
        extra = s.get("unit_extra") or "-"
        print(s["id"], s["vcpus"], s["ram_mb"], s.get("disk_bw") or "-", extra.replace(" ", "\x1f"))


def cmd_config(a):
    prov, dem = load(a.provisioning), load(a.demand)
    if a.quick:
        dem = {**dem, **dem.get("quick", {})}
    if dem.get("target_rps") in (None, 0) and not a.calib:
        print("echo 'ERRO: target_rps não definido em load/demand.yaml (rode calibrate.sh)' >&2; exit 1")
        return
    out = {
        "APP": prov["app"], "SERVICE": prov["service"], "PORT": prov["port"],
        "QUERY": dem["query"], "TARGET_RPS": dem.get("target_rps") or 0,
        "LEVELS": " ".join(str(x) for x in dem["levels_pct"]),
        "WARMUP_S": dem["warmup_s"], "DURATION_S": dem["duration_s"], "REPS": dem["reps"],
        "PAUSE_S": dem["pause_s"], "MAX_VUS": dem["max_vus"],
        "RESET": int(bool(dem.get("reset_between_reps", False))),
        "RESET_EXTRA": dem.get("reset_extra") or "",
    }
    for k, v in out.items():
        print(f"{k}={shlex.quote(str(v))}")


def host_stats(path):
    """CPU total do host e CPU de "outros" processos (fora a VM e o k6), em % de 1 núcleo."""
    vals, other, tops = [], [], {}
    with open(path) as f:
        rows = list(csv.DictReader(f))
    ncpu = sum(1 for k in (rows[0] if rows else {}) if k.startswith("cpu") and k.endswith("_pct") and k[3:-4].isdigit())
    for r in rows:
        vals.append(float(r["cpu_pct"]))
        if "vm_cpu_pct" in r:
            other.append(max(0.0, float(r["cpu_pct"]) * ncpu - float(r["vm_cpu_pct"]) - float(r["app_cpu_pct"])))
        if r.get("top_other"):
            tops[r["top_other"]] = max(tops.get(r["top_other"], 0.0), float(r["top_other_cpu_pct"]))
    if not vals:
        return None
    out = {"mean": round(sum(vals) / len(vals), 1), "max": max(vals),
           "n_over_85": sum(v > 85 for v in vals), "n": len(vals)}
    if other:
        out.update({"other_procs_mean_pct1core": round(sum(other) / len(other), 1),
                    "other_procs_max_pct1core": round(max(other), 1),
                    "n_other_over_100": sum(v > 100 for v in other),
                    "top_other_peaks": dict(sorted(tops.items(), key=lambda kv: -kv[1])[:5])})
    return out


def cmd_hoststats(a):
    s = host_stats(a.csv)
    if not s:
        print("0 0 0 0 0 -"); return
    top = ",".join(f"{k}:{v:.0f}" for k, v in list(s.get("top_other_peaks", {}).items())[:3]) or "-"
    print(f"{s['mean']} {s['max']} {s['n_over_85']} {s.get('other_procs_max_pct1core', 0)} {s.get('n_other_over_100', 0)} {top}")


def host_power():
    """Fonte, perfil de energia e cpufreq (afetam a frequência dos núcleos do host).
    Tudo opcional: o que não existir neste host fica None (sem bateria, sem powerprofilesctl, sem cpufreq)."""
    import glob
    import os
    import subprocess
    def read(path):
        try:
            return open(path).read().strip()
        except OSError:
            return None
    try:
        profile = subprocess.run(["powerprofilesctl", "get"], capture_output=True, text=True, timeout=5).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        profile = None
    psu = os.environ.get("PSU_DIR", "/sys/class/power_supply")
    supplies = [(read(f"{d}/type"), read(f"{d}/online"), read(f"{d}/status")) for d in glob.glob(f"{psu}/*")]
    bats = [st for t, _, st in supplies if t == "Battery"]
    mains = [on for t, on, _ in supplies if t == "Mains"]
    usb_on = any(t == "USB" and on == "1" for t, on, _ in supplies)
    ac = (any(on == "1" for on in mains) or usb_on) if (mains or usb_on) else None
    on_battery = bool(bats) and (ac is False or (ac is None and "Discharging" in bats))
    def active(unit):
        try:
            return subprocess.run(["systemctl", "is-active", unit], capture_output=True, text=True,
                                  timeout=5).stdout.strip()
        except (OSError, subprocess.SubprocessError):
            return None
    try:
        snap = subprocess.run(["snap", "refresh", "--time"], capture_output=True, text=True, timeout=10).stdout
        snap_hold = next((l.split(":", 1)[1].strip() for l in snap.splitlines() if l.startswith("hold:")),
                         "não visível sem sudo")
    except (OSError, subprocess.SubprocessError):
        snap_hold = None
    # cpufreq da primeira CPU da VM (VM_CPUSET) ou da cpu0, se a VM não tiver afinidade
    first = (os.environ.get("VM_CPUSET") or "0").split(",")[0].split("-")[0]
    cf = f"/sys/devices/system/cpu/cpu{first}/cpufreq"
    return {"power_profile": profile, "ac_online": ac, "battery_present": bool(bats), "on_battery": on_battery,
            "unattended_upgrades": active("unattended-upgrades.service"),
            "apt_daily_timer": active("apt-daily.timer"),
            "apt_daily_upgrade_timer": active("apt-daily-upgrade.timer"),
            "snap_refresh_hold": snap_hold,
            "cpufreq_cpu": int(first) if first.isdigit() else None,
            "governor": read(f"{cf}/scaling_governor"),
            "epp": read(f"{cf}/energy_performance_preference")}


def docker_running():
    import psutil
    return any(p.info["name"] in ("dockerd", "containerd") for p in psutil.process_iter(["name"]))


def cmd_idlecheck(a):
    import os
    import time

    import psutil
    me = os.getpid()

    def snapshot():
        snap = {}
        for p in psutil.process_iter(["name", "cmdline", "cpu_times"]):
            if p.pid == me or a.exclude in " ".join(p.info["cmdline"] or []):
                continue
            t = p.info["cpu_times"]
            if t is not None:
                snap[p.pid] = (p.info["name"], t.user + t.system)
        return snap

    s0 = snapshot()
    time.sleep(a.seconds)
    s1 = snapshot()
    per = {}
    for pid, (name, cpu) in s1.items():
        if pid in s0:
            per[name] = per.get(name, 0.0) + (cpu - s0[pid][1]) / a.seconds * 100
    total = sum(per.values())
    top = max(per.items(), key=lambda kv: kv[1]) if per else ("-", 0.0)
    print(f"{total:.1f} {top[0]}:{top[1]:.0f} {int(docker_running())}")


def cmd_written(a):
    """Total gravado no disco da VM (MB) somando os meta.json de um diretório de resultados."""
    import glob
    tot = 0.0
    for p in glob.glob(f"{a.results}/s*/L*/r*/meta.json"):
        w = json.load(open(p)).get("vm_disk_written") or {}
        tot += w.get("with_warmup_mb", 0.0)
    print(f"{tot / 1024:.1f}")


def cmd_events(a):
    """Resumo de uma linha dos eventos da VM (vazio se nada aconteceu)."""
    e = json.load(open(a.path))
    parts = []
    if e["oom_kills"]:
        parts.append(f"{e['oom_kills']} OOM kill(s) ({', '.join(v['name'] for v in e['oom_victims']) or '?'})")
    if e.get("worker_deaths_healthcheck"):
        parts.append(f"{e['worker_deaths_healthcheck']} worker(s) morto(s) pelo healthcheck do uvicorn (sem resposta em 5 s)")
    if e.get("worker_deaths_oom"):
        parts.append(f"{e['worker_deaths_oom']} worker(s) morto(s) por OOM")
    if e["worker_deaths"] and "worker_deaths_oom" not in e:
        parts.append(f"{e['worker_deaths']} worker(s) morto(s) e reiniciado(s) pelo uvicorn")
    if e["service_restarts"] or e["main_pid_changed"]:
        parts.append(f"serviço reiniciado pelo systemd ({e['service_restarts']}x)")
    print("; ".join(parts))


def vm_disk_written(path, t_start, t_end, offset):
    """MB gravados no disco da VM: na janela da medição e no CSV inteiro (inclui o warm-up)."""
    with open(path) as f:
        rows = list(csv.DictReader(f))
    if not rows:
        return None
    total = window = 0.0
    prev = float(rows[0]["timestamp"])
    for r in rows[1:]:
        t = float(r["timestamp"])
        mb = float(r["disk_write_mb_s"]) * (t - prev)
        total += mb
        if t_start <= t - offset <= t_end + 1:
            window += mb
        prev = t
    return {"measure_mb": round(window, 1), "with_warmup_mb": round(total, 1)}


def cmd_meta(a):
    meta = {
        "app": a.app, "scenario": a.scenario, "level_pct": a.level, "rep": a.rep,
        "target_rps": a.target_rps, "rate_rps": a.rate, "query": a.query,
        "duration_s": a.duration, "quick": a.quick,
        "vm": json.loads(a.vm_config),
        "git_commit": a.commit,
        "t_start": a.t_start, "t_end": a.t_end,
        "clock_offset_s": a.clock_offset, "clock_rtt_s": a.clock_rtt,
        "clock_note": "offset = relógio_VM - relógio_host (amostra de menor RTT via SSH)",
        "host_cpu_pct": host_stats(a.host_metrics),
        "host_metrics_file": "host_metrics.csv",
        "host_power": host_power(),
        "host_idle_check": json.loads(a.idle) if a.idle else None,
        "vm_events": json.load(open(a.events)) if a.events else None,
        # swap logo após o reset entre rodadas (antes do warm-up); vm_events.swap_used_at_start_mb é o
        # swap no início da medição, já depois do warm-up na mesma carga
        "swap_after_reset_mb": a.swap_after_reset,
        "vm_disk_written": vm_disk_written(a.vm_metrics, a.t_start, a.t_end, a.clock_offset) if a.vm_metrics else None,
        "docker_running": docker_running(),
    }
    with open(a.out, "w") as f:
        json.dump(meta, f, indent=2)


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("scenarios"); p.add_argument("provisioning"); p.add_argument("--only")
    p = sub.add_parser("config"); p.add_argument("provisioning"); p.add_argument("demand"); p.add_argument("--quick", action="store_true")
    p.add_argument("--calib", action="store_true", help="aceita target_rps vazio")
    p = sub.add_parser("hoststats"); p.add_argument("csv")
    p = sub.add_parser("meta")
    for k in ("out", "app", "scenario", "query", "vm_config", "commit", "host_metrics"):
        p.add_argument("--" + k.replace("_", "-"), dest=k, required=True)
    for k in ("level", "rep"):
        p.add_argument("--" + k, type=int, required=True)
    for k in ("target_rps", "rate", "duration", "t_start", "t_end", "clock_offset", "clock_rtt"):
        p.add_argument("--" + k.replace("_", "-"), dest=k, type=float, required=True)
    p.add_argument("--quick", action="store_true")
    p.add_argument("--idle", help="JSON da checagem de host ocioso antes da rodada")
    p.add_argument("--events", help="vm_events.json da rodada (OOM, workers mortos, reinícios)")
    p.add_argument("--vm-metrics", dest="vm_metrics", help="vm_metrics.csv (bytes gravados na VM)")
    p.add_argument("--swap-after-reset", dest="swap_after_reset", type=float,
                   help="swap usado (MB) logo após o reset da rodada")
    p = sub.add_parser("events"); p.add_argument("path")
    p = sub.add_parser("written"); p.add_argument("results")
    p = sub.add_parser("idlecheck"); p.add_argument("--exclude", required=True)
    p.add_argument("--seconds", type=float, default=10)
    a = ap.parse_args()
    {"scenarios": cmd_scenarios, "config": cmd_config, "hoststats": cmd_hoststats, "meta": cmd_meta,
     "idlecheck": cmd_idlecheck, "events": cmd_events, "written": cmd_written}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
