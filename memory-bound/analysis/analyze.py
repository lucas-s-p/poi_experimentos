"""Análise da app (implementação comum em common/analysis_lib.py).
Uso: conda run -n poi-analysis python analysis/analyze.py [--results DIR]"""
import sys
from pathlib import Path

APP_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(APP_DIR.parent / "common"))
from analysis_lib import main  # noqa: E402

main(APP_DIR)
