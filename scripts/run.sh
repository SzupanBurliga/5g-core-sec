#!/usr/bin/env bash
# Orkiestracja: uruchamia baseline + wszystkie scenariusze do results/<faza>.
# Użycie: scripts/run.sh before|after [--yes-s6]
#   before : stan domyślny (przed hardeningiem)
#   after  : po hardeningu (scripts/harden.sh)
#   --yes-s6 : przekazuje potwierdzenie do S6 (obciążenie zasobów)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PHASE="${1:-}"; shift || true
case "$PHASE" in
	before) OUTDIR="${REPO_ROOT}/results/before" ;;
	after)  OUTDIR="${REPO_ROOT}/results/after" ;;
	*) die "Użycie: $0 before|after [--yes-s6]" ;;
esac

S6_ARGS=()
for a in "$@"; do [ "$a" = "--yes-s6" ] && S6_ARGS+=(--yes); done

mkdir -p "$OUTDIR"
need_kubectl
ns_exists || die "Namespace $NS nie istnieje. Najpierw Faza 1."

log "=== RUN '$PHASE' -> $OUTDIR ==="

section "BASELINE"
"${SCRIPT_DIR}/baseline.sh" "$OUTDIR"

for s in s1_privesc s2_sa_token s3_east_west s4_secrets s5_supply_chain; do
	section "SCENARIUSZ ${s}"
	"${SCRIPT_DIR}/scenarios/${s}.sh" --out "$OUTDIR" || warn "${s} zakończony błędem (kontynuuję)."
done

section "SCENARIUSZ s6_resource_exhaustion"
if [ "${#S6_ARGS[@]}" -gt 0 ]; then
	"${SCRIPT_DIR}/scenarios/s6_resource_exhaustion.sh" --out "$OUTDIR" "${S6_ARGS[@]}" \
		|| warn "s6 zakończony błędem."
else
	warn "S6 pominięty (wymaga zgody człowieka). Dodaj --yes-s6, by go uruchomić."
fi

ok "RUN '$PHASE' zakończony. Wyniki w: $OUTDIR"
log "Gdy masz before I after -> scripts/summary.sh"
