#!/usr/bin/env bash
# Faza 4 — aplikuje manifesty hardeningu 01..06 PO KOLEI. Po każdym kroku
# sprawdza, czy UE nadal robi pinga; jeśli hardening psuje rdzeń, zatrzymuje się,
# byś mógł poluzować regułę i opisać trade-off w docs/setup-notes.md.
# Użycie: scripts/harden.sh [--step NN] [--no-pingcheck]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
HDIR="${REPO_ROOT}/manifests/hardening"

ONLY_STEP=""; PINGCHECK=1
while [ $# -gt 0 ]; do
	case "$1" in
		--step) ONLY_STEP="$2"; shift 2 ;;
		--no-pingcheck) PINGCHECK=0; shift ;;
		-h|--help) echo "Użycie: $0 [--step NN] [--no-pingcheck]"; exit 0 ;;
		*) shift ;;
	esac
done

need_kubectl
ns_exists || die "Namespace $NS nie istnieje. Najpierw Faza 1."

ping_ok() {
	[ "$PINGCHECK" -eq 0 ] && return 0
	local ue; ue="$(pod_by_selector 'nf=ue')"
	[ -z "$ue" ] && ue="$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '/ue/ {print $1; exit}')"
	if [ -z "$ue" ]; then warn "Brak poda UE — pomijam ping-check."; return 0; fi
	if kubectl exec -n "$NS" "$ue" -- ping -I uesimtun0 -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
		ok "Ping UE OK."
		return 0
	fi
	warn "Ping UE NIE PRZECHODZI po tym kroku."
	return 1
}

apply_step() {
	local f="$1"
	section "APPLY $(basename "$f")"
	kubectl apply -f "$f" || die "apply nie powiodło się: $f"
	sleep 3
	if ! ping_ok; then
		warn "ZATRZYMANIE: hardening '$(basename "$f")' mógł zepsuć rdzeń."
		warn "Poluzuj regułę w tym pliku i opisz kompromis w docs/setup-notes.md, potem uruchom ponownie."
		exit 2
	fi
}

log "Hardening -> namespace $NS (ping-check: $PINGCHECK)"
for f in "${HDIR}"/*.yaml; do
	n="$(basename "$f" | cut -c1-2)"
	if [ -n "$ONLY_STEP" ] && [ "$n" != "$ONLY_STEP" ]; then continue; fi
	apply_step "$f"
done

section "STAN KOŃCOWY"
kubectl get networkpolicy,resourcequota,limitrange,sa -n "$NS" 2>&1
ok "Hardening zastosowany. Teraz: scripts/run.sh after"
