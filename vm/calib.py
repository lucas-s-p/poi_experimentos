"""Cálculos da calibração (host, env poi-analysis).

  measure <dir>        métricas de uma rodada (JSON): vazão, latência, utilização da VM, custos por requisição
  propose-cpu ...      carga-alvo e "adequada" da cpu-bound a partir do custo de CPU por requisição
  confirm ...          maior taxa com média do p95 das rodadas ≤ limite (atualiza proposal.json)
  mem-search ...       memory-bound: carga-alvo (média do p95 ≤ 2× sem carga) e pico de memória por taxa
"""
import argparse
import json
import math
import sys

import pandas as pd


def measure(d):
    meta = json.load(open(f"{d}/meta.json"))
    k6 = json.load(open(f"{d}/k6_summary.json"))["metrics"]
    vm = pd.read_csv(f"{d}/vm_metrics.csv")
    off = meta["clock_offset_s"]
    # só as amostras dentro da janela do k6 (relógio da VM convertido para o do host)
    t = vm.timestamp - off
    w = vm[(t >= meta["t_start"] + 1) & (t <= meta["t_end"])]
    dur = meta["t_end"] - meta["t_start"]
    reqs = k6["http_reqs"]["values"]["count"]
    lat = k6["http_req_duration"]["values"]
    vcpus = meta["vm"]["vcpus"]
    util = w.cpu_pct.mean() / 100
    return {
        "dir": d, "vcpus": vcpus, "ram_mb": meta["vm"]["ram_mb"],
        "rate_rps": meta["rate_rps"], "throughput_rps": reqs / dur, "reqs": reqs,
        "failed_rate": k6["http_req_failed"]["values"]["rate"],
        "dropped": k6.get("dropped_iterations", {}).get("values", {}).get("count", 0),
        "p50_ms": lat["p(50)"], "p95_ms": lat["p(95)"], "p99_ms": lat["p(99)"], "mean_ms": lat["avg"],
        "vm_util": util, "app_cpu_pct": w.app_cpu_pct.mean(),
        "cpu_s_per_req": util * vcpus * dur / reqs,
        "app_cpu_s_per_req": w.app_cpu_pct.mean() / 100 * dur / reqs,
        "mem_used_mb": w.mem_used_mb.mean(), "app_rss_mb": w.app_rss_mb.mean(),
        "app_rss_max_mb": w.app_rss_mb.max(), "swap_max_mb": w.swap_used_mb.max(),
        # Little: requisições em andamento = vazão × tempo médio de resposta
        "inflight": reqs / dur * lat["avg"] / 1000,
        "disk_mb_per_req": (w.disk_read_mb_s.sum() + w.disk_write_mb_s.sum()) / reqs,
        "n_samples": len(w),
        # memória: pico (p95 das amostras de 1 s) de memória usada (total - disponível), swap e eventos
        "mem_used_p95_mb": w.mem_used_mb.quantile(0.95), "mem_total_mb": w.mem_total_mb.max(),
        "app_rss_p95_mb": w.app_rss_mb.quantile(0.95),
        "swap_io_pg_s": (w.pswpin_pg_s.mean() + w.pswpout_pg_s.mean()) if "pswpin_pg_s" in w else float("nan"),
        "pgmajfault_s": w.pgmajfault_s.mean() if "pgmajfault_s" in w else float("nan"),
        "oom_kills": (meta.get("vm_events") or {}).get("oom_kills", 0),
        "worker_deaths": (meta.get("vm_events") or {}).get("worker_deaths", 0),
    }


def cmd_measure(a):
    print(json.dumps(measure(a.dir)))


def cmd_propose_cpu(a):
    noload = measure(a.noload)
    costs = [measure(d) for d in a.cost]
    c = sum(m["cpu_s_per_req"] for m in costs) / len(costs)
    s0 = noload["p50_ms"]
    adeq = a.adequada_vcpus
    target = a.util * adeq / c
    target = math.floor(target * 2) / 2  # múltiplo de 0,5 req/s
    levels = [int(x) for x in a.levels.split()]
    scen = [int(x) for x in a.scenarios.split()]
    pred = {v: {lv: round(target * lv / 100 * c / v, 2) for lv in levels} for v in scen}
    out = {
        "noload_p50_ms": round(s0, 1), "noload_p95_ms": round(noload["p95_ms"], 1),
        "p95_limit_ms": round(2 * s0, 1),
        "cost_runs": [{k: round(m[k], 4) if isinstance(m[k], float) else m[k]
                       for k in ("rate_rps", "throughput_rps", "vm_util", "cpu_s_per_req", "app_cpu_s_per_req", "p95_ms")}
                      for m in costs],
        "cpu_s_per_req": round(c, 4),
        "capacity_rps_per_vcpu": round(1 / c, 2),
        "adequada_vcpus": adeq, "util_target": a.util, "target_rps": target,
        "predicted_util": pred,
    }
    print(json.dumps(out))


def cmd_confirm(a):
    """Escolhe a maior taxa cuja MÉDIA do p95 nas rodadas fica ≤ limite (sem descartes em nenhuma rodada).
    Média e não cada rodada: o p95 de rodadas idênticas varia ±5 ms, a mesma ordem da folga até o limite."""
    prop = json.load(open(a.proposal))
    limit = prop["p95_limit_ms"]
    table, best = [], None
    print(f"\n{'taxa':>6} {'rep':>3} {'vazão':>6} {'util':>5} {'p50':>5} {'p95':>6} {'p99':>6} {'drop':>4}  ok")
    for r in a.rates.split():
        rows = [measure(f"{a.runs}/confirm-{r}-r{k}") for k in range(1, a.reps + 1)]
        oks = [m["p95_ms"] <= limit and m["dropped"] == 0 for m in rows]  # informativo, por rodada
        mean_p95 = sum(m["p95_ms"] for m in rows) / len(rows)
        ok_rate = mean_p95 <= limit and all(m["dropped"] == 0 for m in rows)
        for k, (m, ok) in enumerate(zip(rows, oks), 1):
            print(f"{r:>6} {k:>3} {m['throughput_rps']:6.1f} {m['vm_util']:5.0%} {m['p50_ms']:5.0f} "
                  f"{m['p95_ms']:6.0f} {m['p99_ms']:6.0f} {m['dropped']:4d}  {'ok' if ok else 'FALHA'}")
            table.append({"rate_rps": float(r), "rep": k, "ok": ok,
                          **{x: round(m[x], 3) for x in ("throughput_rps", "vm_util", "p50_ms", "p95_ms", "p99_ms", "dropped")}})
        print(f"{r:>6} méd {'':>6} {'':>5} {'':>5} {mean_p95:6.1f} {'':>6} {'':>4}  {'OK' if ok_rate else 'FALHA'} (critério)")
        if ok_rate:
            best = float(r)
    prop["confirmation"] = {"limit_p95_ms": limit, "criterion": "média do p95 das rodadas ≤ limite, sem descartes",
                            "reps": a.reps, "runs": table, "chosen_rps": best}
    if best is not None:
        prop.setdefault("target_rps_single_validation", prop["target_rps"])
        prop["target_rps"] = best
    json.dump(prop, open(a.proposal, "w"), indent=2)
    print(f"\nMaior taxa com média do p95 ({a.reps} rodadas) ≤ {limit} ms: {best if best is not None else 'nenhuma'}")
    return 0 if best is not None else 1


def group_reps(runs, prefix, rates, reps):
    """{taxa: [medidas das rodadas]} para rodadas nomeadas <prefix>-<taxa>-r<k>."""
    return {r: [measure(f"{runs}/{prefix}-{r}-r{k}") for k in range(1, reps + 1)] for r in rates}


def cmd_mem_search(a):
    """Maior taxa com média do p95 ≤ limite (sem descartes) e o pico de memória a essa taxa."""
    s0 = measure(f"{a.runs}/noload")["p50_ms"]
    limit = 2 * s0
    res = group_reps(a.runs, "search", a.rates.split(), a.reps)
    rows, best = [], None
    for r, ms in res.items():
        mean_p95 = sum(m["p95_ms"] for m in ms) / len(ms)
        ok = mean_p95 <= limit and all(m["dropped"] == 0 for m in ms)
        rows.append({"rate_rps": float(r), "mean_p95_ms": round(mean_p95, 1), "ok": ok,
                     "p95_ms": [round(m["p95_ms"]) for m in ms],
                     "vm_util": round(sum(m["vm_util"] for m in ms) / len(ms), 3),
                     "mem_used_p95_mb": round(max(m["mem_used_p95_mb"] for m in ms)),
                     "app_rss_p95_mb": round(max(m["app_rss_p95_mb"] for m in ms)),
                     "inflight": round(sum(m["inflight"] for m in ms) / len(ms), 2)})
        if ok:
            best = rows[-1]
    print(json.dumps({"noload_p50_ms": round(s0, 1), "p95_limit_ms": round(limit, 1), "search": rows,
                      "target": best}))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("measure"); p.add_argument("dir")
    p = sub.add_parser("mem-search")
    p.add_argument("--runs", required=True); p.add_argument("--rates", required=True)
    p.add_argument("--reps", type=int, default=3)
    p = sub.add_parser("confirm")
    p.add_argument("--proposal", required=True); p.add_argument("--runs", required=True)
    p.add_argument("--rates", required=True); p.add_argument("--reps", type=int, default=3)
    p = sub.add_parser("propose-cpu")
    p.add_argument("--noload", required=True); p.add_argument("--cost", nargs="+", required=True)
    p.add_argument("--adequada-vcpus", type=int, required=True); p.add_argument("--util", type=float, default=0.70)
    p.add_argument("--levels", required=True); p.add_argument("--scenarios", required=True)
    a = ap.parse_args()
    return {"measure": cmd_measure, "propose-cpu": cmd_propose_cpu, "confirm": cmd_confirm,
            "mem-search": cmd_mem_search}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
