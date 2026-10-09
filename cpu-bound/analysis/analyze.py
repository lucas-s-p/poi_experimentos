"""Consolida results/<cenario>/<nivel>/<rep>/ e gera tabelas e gráficos (média ± IC 95%, t-Student).

Uso: conda run -n poi-analysis python analysis/analyze.py [--results DIR]
Saídas em <results>/analysis/: reps.csv, summary.csv, cenario_<id>.png, comparacao_latencia.png, comparacao_recursos.png
"""
import argparse
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
import yaml  # noqa: E402
from scipy import stats  # noqa: E402

APP_DIR = Path(__file__).resolve().parent.parent

# Paleta categórica validada (ordem fixa; cenários seguem a ordem do provisioning.yaml)
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4"]
MARKERS = ["o", "s", "^", "D", "v"]
INK, INK2, GRID = "#1f1f1e", "#5f5e58", "#e4e3dd"

METRICS = {  # coluna: (rótulo, unidade)
    "p50_ms": ("Latência p50", "ms"), "p95_ms": ("Latência p95", "ms"), "p99_ms": ("Latência p99", "ms"),
    "throughput_rps": ("Vazão (respostas 200)", "req/s"), "vm_cpu_pct": ("CPU da VM", "%"),
    "vm_mem_used_mb": ("Memória usada na VM", "MB"),
}


def one_rep(d: Path):
    meta = json.loads((d / "meta.json").read_text())
    k6 = json.loads((d / "k6_summary.json").read_text())["metrics"]
    vm = pd.read_csv(d / "vm_metrics.csv")
    t = vm.timestamp - meta["clock_offset_s"]
    w = vm[(t >= meta["t_start"] + 1) & (t <= meta["t_end"])]
    dur = meta["t_end"] - meta["t_start"]
    lat = k6["http_req_duration"]["values"]
    reqs = k6["http_reqs"]["values"]["count"]
    failed = k6["http_req_failed"]["values"]["rate"]
    return {
        "scenario": meta["scenario"], "level_pct": meta["level_pct"], "rep": meta["rep"],
        "rate_rps": meta["rate_rps"], "vcpus": meta["vm"]["vcpus"], "ram_mb": meta["vm"]["ram_mb"],
        "p50_ms": lat["p(50)"], "p95_ms": lat["p(95)"], "p99_ms": lat["p(99)"], "mean_ms": lat["avg"],
        "throughput_rps": reqs * (1 - failed) / dur, "failed_rate": failed,
        "dropped": k6.get("dropped_iterations", {}).get("values", {}).get("count", 0),
        "vm_cpu_pct": w.cpu_pct.mean(), "app_cpu_pct": w.app_cpu_pct.mean(),
        "vm_mem_used_mb": w.mem_used_mb.mean(), "app_rss_mb": w.app_rss_mb.mean(),
        "swap_max_mb": w.swap_used_mb.max(), "iowait_pct": w.cpu_iowait_pct.mean(),
        "disk_read_mb_s": w.disk_read_mb_s.mean(), "disk_write_mb_s": w.disk_write_mb_s.mean(),
        "host_cpu_mean": meta["host_cpu_pct"]["mean"], "host_cpu_max": meta["host_cpu_pct"]["max"],
    }


def ci95(x):
    x = np.asarray(x, dtype=float)
    n = len(x)
    if n < 2:
        return np.nan
    return stats.t.ppf(0.975, n - 1) * x.std(ddof=1) / np.sqrt(n)


def summarize(reps: pd.DataFrame):
    cols = [c for c in reps.columns if c not in ("scenario", "level_pct", "rep", "vcpus", "ram_mb", "rate_rps")]
    g = reps.groupby(["scenario", "level_pct"])
    mean = g[cols].mean()
    ci = g[cols].agg(ci95).add_suffix("_ci95")
    out = pd.concat([g[["rate_rps", "vcpus", "ram_mb"]].first(), g.size().rename("n"), mean, ci], axis=1)
    return out.reset_index()


def style(ax, title, unit):
    ax.set_title(title, loc="left", fontsize=11, color=INK)
    ax.set_ylabel(unit, color=INK2)
    ax.grid(True, color=GRID, linewidth=0.8)
    ax.set_axisbelow(True)
    for s in ("top", "right"):
        ax.spines[s].set_visible(False)
    for s in ("left", "bottom"):
        ax.spines[s].set_color(GRID)
    ax.tick_params(colors=INK2, labelsize=9)


def demand_axis(ax, summ):
    lv = summ.drop_duplicates("level_pct").sort_values("level_pct")
    ax.set_xticks(lv.rate_rps)
    ax.set_xticklabels([f"{r:g}\n({p}%)" for r, p in zip(lv.rate_rps, lv.level_pct)])
    ax.set_xlabel("Demanda (req/s, % da carga-alvo)", color=INK2)


def line(ax, d, col, color, marker, label, direct=True):
    ax.errorbar(d.rate_rps, d[col], yerr=d[f"{col}_ci95"].fillna(0), color=color, marker=marker,
                markersize=6, linewidth=2, capsize=3, elinewidth=1, label=label)
    if direct:
        last = d.iloc[-1]
        ax.annotate(label, (last.rate_rps, last[col]), xytext=(6, 0), textcoords="offset points",
                    va="center", fontsize=8, color=INK2)


def plot_scenario(summ, sid, name, out):
    d = summ[summ.scenario == sid].sort_values("level_pct")
    fig, axes = plt.subplots(2, 2, figsize=(11, 8), constrained_layout=True)
    ax = axes[0, 0]
    for i, col in enumerate(("p50_ms", "p95_ms", "p99_ms")):
        line(ax, d, col, SERIES[i], MARKERS[i], col.split("_")[0])
    ax.set_yscale("log"); style(ax, "Latência", "ms (escala log)"); ax.legend(frameon=False, fontsize=8)
    ax = axes[0, 1]
    ax.plot(d.rate_rps, d.rate_rps, "--", color=INK2, linewidth=1, label="oferecida")
    line(ax, d, "throughput_rps", SERIES[0], MARKERS[0], "atingida", direct=False)
    style(ax, "Vazão", "req/s"); ax.legend(frameon=False, fontsize=8)
    ax = axes[1, 0]
    line(ax, d, "vm_cpu_pct", SERIES[0], MARKERS[0], "VM (total)", direct=False)
    style(ax, "CPU da VM", "% da capacidade da VM"); ax.set_ylim(0, 105)
    ax = axes[1, 1]
    line(ax, d, "vm_mem_used_mb", SERIES[0], MARKERS[0], "VM", direct=False)
    line(ax, d, "app_rss_mb", SERIES[1], MARKERS[1], "app (RSS)", direct=False)
    style(ax, "Memória", "MB"); ax.legend(frameon=False, fontsize=8); ax.set_ylim(bottom=0)
    for ax in axes.flat:
        demand_axis(ax, d)
    r = d.iloc[0]
    fig.suptitle(f"{APP_DIR.name} · {name} ({r.vcpus:g} vCPU, {r.ram_mb:g} MB) · média ± IC 95% (n={r.n:g})",
                 x=0.01, ha="left", fontsize=12, color=INK)
    fig.savefig(out, dpi=130); plt.close(fig)


def plot_compare(summ, scen, cols, title, out, logy=()):
    fig, axes = plt.subplots(1, len(cols), figsize=(5.2 * len(cols), 4.6), constrained_layout=True)
    for ax, col in zip(np.atleast_1d(axes), cols):
        for i, s in enumerate(scen):
            d = summ[summ.scenario == s["id"]].sort_values("level_pct")
            if len(d):
                line(ax, d, col, SERIES[i], MARKERS[i], s["name"])
        label, unit = METRICS[col]
        if col in logy:
            ax.set_yscale("log"); unit += " (escala log)"
        style(ax, label, unit)
        demand_axis(ax, summ)
    np.atleast_1d(axes)[0].legend(frameon=False, fontsize=8)
    fig.suptitle(f"{APP_DIR.name} · {title} · média ± IC 95%", x=0.01, ha="left", fontsize=12, color=INK)
    fig.savefig(out, dpi=130); plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default=str(APP_DIR / "results"))
    a = ap.parse_args()
    res = Path(a.results)
    prov = yaml.safe_load((APP_DIR / "provisioning.yaml").read_text())
    scen = prov["scenarios"]

    # resultados de --quick ficam em results/quick/ (analisáveis com --results results/quick)
    reps = [one_rep(p.parent) for p in sorted(res.glob("*/L*/r*/meta.json")) if p.relative_to(res).parts[0] != "quick"]
    if not reps:
        raise SystemExit(f"nenhum resultado em {res}")
    reps = pd.DataFrame(reps)
    summ = summarize(reps)
    out = res / "analysis"
    out.mkdir(exist_ok=True)
    reps.to_csv(out / "reps.csv", index=False, float_format="%.3f")
    summ.to_csv(out / "summary.csv", index=False, float_format="%.3f")

    for s in scen:
        if (summ.scenario == s["id"]).any():
            plot_scenario(summ, s["id"], s["name"], out / f"cenario_{s['id']}.png")
    plot_compare(summ, scen, ["p50_ms", "p95_ms", "p99_ms"], "Latência × demanda", out / "comparacao_latencia.png",
                 logy=("p50_ms", "p95_ms", "p99_ms"))
    plot_compare(summ, scen, ["throughput_rps", "vm_cpu_pct", "vm_mem_used_mb"], "Vazão e recursos × demanda",
                 out / "comparacao_recursos.png")

    cols = ["scenario", "level_pct", "rate_rps", "n", "throughput_rps", "p50_ms", "p95_ms", "p95_ms_ci95", "p99_ms",
            "failed_rate", "vm_cpu_pct", "vm_mem_used_mb", "host_cpu_max"]
    with pd.option_context("display.width", 200, "display.max_rows", 200):
        print(summ[cols].round(1).to_string(index=False))
    print(f"\nArquivos em {out}")


if __name__ == "__main__":
    main()
