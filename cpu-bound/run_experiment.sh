#!/usr/bin/env bash
# Experimento completo da cpu-bound (5 cenários × níveis × repetições). Retomável.
#   ./run_experiment.sh                 experimento completo
#   ./run_experiment.sh --quick s3-adequada   demonstração (1 cenário, 2 níveis, 1 rep de 20s)
set -euo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$APP_DIR/../vm/explib.sh"
experiment_main "$@"
