"""Análise comum às 3 apps: consolida results/<cenario>/<nivel>/<rep>/ e gera tabelas e gráficos
(média ± IC 95%, t-Student). Chamada pelo analysis/analyze.py de cada app.

Uso: conda run -n poi-analysis python <app>/analysis/analyze.py [--results DIR]
Saídas em <results>/analysis/: reps.csv, summary.csv, cenario_<id>.png, comparacao_latencia.png, comparacao_recursos.png
Painéis extras por app (EXTRA): memória → pressão de memória e eventos (OOM, reinícios); io → disco.
"""
import argparse
import json
from pathlib import Path

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402
from matplotlib.ticker import FuncFormatter  # noqa: E402
import numpy as np  # noqa: E402
import pandas as pd  # noqa: E402
import yaml  # noqa: E402
from scipy import stats  # noqa: E402

APP_DIR = None  # definido em main()

# Paleta categórica validada (ordem fixa; cenários seguem a ordem do provisioning.yaml)
SERIES = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4"]
MARKERS = ["o", "s", "^", "D", "v"]
INK, INK2, GRID = "#1f1f1e", "#5f5e58", "#e4e3dd"

METRICS = {  # coluna: (rótulo, unidade)
    "p50_ms": ("Latência p50", "ms"), "p95_ms": ("Latência p95", "ms"), "p99_ms": ("Latência p99", "ms"),
    "throughput_rps": ("Vazão (respostas 200)", "req/s"), "vm_cpu_pct": ("CPU da VM", "%"),
    "vm_mem_used_mb": ("Memória usada na VM", "MB"),
    "swap_max_mb": ("Swap usado na VM (máx.)", "MB"), "swap_io_pg_s": ("Swap in + out", "páginas/s"),
    "pgmajfault_s": ("Falhas de página major", "por s"), "oom_kills": ("OOM kills por rodada", "eventos"),
    "worker_deaths": ("Workers reiniciados por rodada", "eventos"),
    "worker_deaths_healthcheck": ("Workers mortos pelo healthcheck", "por rodada"),
    "worker_deaths_oom": ("Workers mortos por OOM", "por rodada"),
    "disk_util_pct": ("Disco ocupado (%util)", "%"), "iowait_pct": ("iowait", "% da CPU"),
    "disk_mb_s": ("Disco (leitura + escrita)", "MB/s"),
}

# Painéis extras do gráfico por cenário e métrica extra do comparativo de recursos, por app
EXTRA = {
    "memory-bound": {"panels": [("Pressão de memória", "por s", ["swap_io_pg_s", "pgmajfault_s"], False),
                                ("Eventos na VM (média por rodada)", "eventos",
                                 ["worker_deaths_healthcheck", "worker_deaths_oom", "oom_kills"], False)],
                     "compare": ["swap_max_mb", "swap_io_pg_s"]},
    "io-bound": {"panels": [("Disco", "%", ["disk_util_pct", "iowait_pct"], False),
                            ("Taxa de disco", "MB/s", ["disk_mb_s"], False)],
                 "compare": ["disk_util_pct", "disk_mb_s"]},
}


def col_mean(w, name):
    """Média de uma coluna do coletor (NaN em resultados antigos, sem a coluna)."""
    return w[name].mean() if name in w else np.nan


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
    ev = meta.get("vm_events") or {}
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
        "disk_mb_s": w.disk_read_mb_s.mean() + w.disk_write_mb_s.mean(),
        "disk_util_pct": col_mean(w, "disk_util_pct"),
        "swap_io_pg_s": col_mean(w, "pswpin_pg_s") + col_mean(w, "pswpout_pg_s"),
        "pgmajfault_s": col_mean(w, "pgmajfault_s"),
        "oom_kills": ev.get("oom_kills", np.nan), "worker_deaths": ev.get("worker_deaths", np.nan),
        "worker_deaths_healthcheck": ev.get("worker_deaths_healthcheck", np.nan),
        "worker_deaths_oom": ev.get("worker_deaths_oom", np.nan),
        "swap_after_reset_mb": meta.get("swap_after_reset_mb", np.nan) if meta.get("swap_after_reset_mb") is not None else np.nan,
        "swap_at_measure_start_mb": ev.get("swap_used_at_start_mb", np.nan),
        "service_restarts": ev.get("service_restarts", np.nan),
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
    events = [c for c in ("oom_kills", "worker_deaths_healthcheck", "worker_deaths_oom", "service_restarts") if c in reps]
    totals = g[events].sum(min_count=1).add_suffix("_total")   # contagens somadas nas repetições
    out = pd.concat([g[["rate_rps", "vcpus", "ram_mb"]].first(), g.size().rename("n"), mean, ci, totals], axis=1)
    return out.reset_index()


def log_y(ax):
    """Escala log com rótulos numéricos simples (30, 100, 400) em vez de 4×10²."""
    ax.set_yscale("log")
    fmt = FuncFormatter(lambda v, _: f"{v:g}")
    ax.yaxis.set_major_formatter(fmt)
    ax.yaxis.set_minor_formatter(fmt)
    ax.tick_params(axis="y", which="minor", labelsize=7)


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
    ci = d[f"{col}_ci95"].fillna(0)
    lower = ci
    if ax.get_yscale() == "log":
        lower = np.minimum(ci, d[col] * 0.9)  # IC inferior ≤ 0 não existe em escala log
    ax.errorbar(d.rate_rps, d[col], yerr=[lower, ci], color=color, marker=marker,
                markersize=6, linewidth=2, capsize=3, elinewidth=1, label=label)
    if direct:
        last = d.iloc[-1]
        ax._direct_labels = getattr(ax, "_direct_labels", []) + [(label, last.rate_rps, last[col])]


def place_direct_labels(ax, min_gap_pt=11):
    """Rótulos no fim das linhas, afastados verticalmente para não se sobreporem."""
    items = getattr(ax, "_direct_labels", [])
    if not items:
        return
    fig = ax.figure
    fig.canvas.draw()
    to_px = ax.transData.transform
    gap = min_gap_pt * fig.dpi / 72
    pts = sorted(((to_px((x, y))[1], lab, x, y) for lab, x, y in items))
    placed = []
    for py, lab, x, y in pts:
        py = max(py, placed[-1] + gap) if placed else py
        placed.append(py)
        dy_pt = (py - to_px((x, y))[1]) * 72 / fig.dpi
        ax.annotate(lab, (x, y), xytext=(6, dy_pt), textcoords="offset points",
                    va="center", fontsize=8, color=INK2)


def plot_scenario(summ, sid, name, out):
    d = summ[summ.scenario == sid].sort_values("level_pct")
    extra = EXTRA.get(APP_DIR.name, {}).get("panels", [])
    ncols = 3 if extra else 2
    fig, axes = plt.subplots(2, ncols, figsize=(5.5 * ncols, 8), constrained_layout=True)
    if extra:  # colunas 0-1 = painéis padrão; coluna 2 = extras
        for row, (title, unit, cols, logy) in enumerate(extra):
            ax = axes[row, 2]
            if logy:
                log_y(ax)
            for i, col in enumerate(cols):
                line(ax, d, col, SERIES[i], MARKERS[i], METRICS[col][0], direct=False)
            style(ax, title, unit); ax.legend(frameon=False, fontsize=8); ax.set_ylim(bottom=0)
    ax = axes[0, 0]
    log_y(ax)
    for i, col in enumerate(("p50_ms", "p95_ms", "p99_ms")):
        line(ax, d, col, SERIES[i], MARKERS[i], col.split("_")[0])
    style(ax, "Latência", "ms (escala log)"); ax.legend(frameon=False, fontsize=8)
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
    if d.swap_max_mb.max() > 1:
        line(ax, d, "swap_max_mb", SERIES[2], MARKERS[2], "swap (máx.)", direct=False)
    style(ax, "Memória", "MB"); ax.legend(frameon=False, fontsize=8); ax.set_ylim(bottom=0)
    for ax in axes.flat:
        demand_axis(ax, d)
    for ax in axes.flat:
        ax.margins(x=0.1)
        place_direct_labels(ax)
    r = d.iloc[0]
    fig.suptitle(f"{APP_DIR.name} · {name} ({r.vcpus:g} vCPU, {r.ram_mb:g} MB) · média ± IC 95% (n={r.n:g})",
                 x=0.01, ha="left", fontsize=12, color=INK)
    fig.savefig(out, dpi=130); plt.close(fig)


def plot_compare(summ, scen, cols, title, out, logy=()):
    fig, axes = plt.subplots(1, len(cols), figsize=(5.2 * len(cols), 4.6), constrained_layout=True)
    for ax, col in zip(np.atleast_1d(axes), cols):
        label, unit = METRICS[col]
        if col in logy:
            log_y(ax); unit += " (escala log)"
        for i, s in enumerate(scen):
            d = summ[summ.scenario == s["id"]].sort_values("level_pct")
            if len(d):
                line(ax, d, col, SERIES[i], MARKERS[i], s["name"])
        style(ax, label, unit)
        demand_axis(ax, summ)
    np.atleast_1d(axes)[0].legend(frameon=False, fontsize=8)
    fig.suptitle(f"{APP_DIR.name} · {title} · média ± IC 95%", x=0.01, ha="left", fontsize=12, color=INK)
    for ax in np.atleast_1d(axes):
        ax.margins(x=0.12)
        place_direct_labels(ax)
    fig.savefig(out, dpi=130); plt.close(fig)


def main(app_dir):
    global APP_DIR
    APP_DIR = Path(app_dir)
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
    extra_cmp = EXTRA.get(APP_DIR.name, {}).get("compare", [])
    plot_compare(summ, scen, ["throughput_rps", "vm_cpu_pct", "vm_mem_used_mb"] + extra_cmp,
                 "Vazão e recursos × demanda", out / "comparacao_recursos.png")

    cols = ["scenario", "level_pct", "rate_rps", "n", "throughput_rps", "p50_ms", "p95_ms", "p95_ms_ci95", "p99_ms",
            "failed_rate", "vm_cpu_pct", "vm_mem_used_mb", "host_cpu_max"]
    if APP_DIR.name == "memory-bound":
        cols += ["swap_after_reset_mb", "swap_at_measure_start_mb", "swap_max_mb", "swap_io_pg_s", "pgmajfault_s", "oom_kills_total",
                 "worker_deaths_healthcheck_total", "worker_deaths_oom_total", "service_restarts_total"]
    elif APP_DIR.name == "io-bound":
        cols += ["disk_mb_s", "disk_util_pct", "iowait_pct"]
    with pd.option_context("display.width", 200, "display.max_rows", 200):
        print(summ[cols].round(1).to_string(index=False))
    print(f"\nArquivos em {out}")

