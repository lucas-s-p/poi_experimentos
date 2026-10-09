"""Auxiliares do host para os scripts de experimento (roda no env conda poi-analysis).

  scenarios <provisioning.yaml> [--only ID]   linhas "id vcpus ram_mb disk_bw unit_extra" (disk_bw/unit_extra '-' se vazio)
  config <provisioning.yaml> <demand.yaml> [--quick]   atribuições shell (eval) com app, porta e demanda
  hoststats <host_metrics.csv>                 "mean max n_over_85" da CPU total do host
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
    """Perfil de energia e fonte (afetam a frequência dos núcleos do host)."""
    import glob
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
    ac = [read(p) for p in glob.glob("/sys/class/power_supply/A*/online")]
    return {"power_profile": profile, "ac_online": ac[0] == "1" if ac else None,
            "governor_cpu4": read("/sys/devices/system/cpu/cpu4/cpufreq/scaling_governor"),
            "epp_cpu4": read("/sys/devices/system/cpu/cpu4/cpufreq/energy_performance_preference")}


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
    a = ap.parse_args()
    {"scenarios": cmd_scenarios, "config": cmd_config, "hoststats": cmd_hoststats, "meta": cmd_meta}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
