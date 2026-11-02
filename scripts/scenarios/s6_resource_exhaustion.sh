#!/usr/bin/env bash
# S6 — Wyczerpanie zasobów. Obciążenie CPU/RAM w JEDNYM podzie CNF (NIE UPF),
# z twardym limitem czasu. Mierzy wpływ na dostępność rdzenia.
#
# CLAUDE.md: NAJPIERW ZAPYTAJ CZŁOWIEKA. Skrypt wymaga jawnego potwierdzenia
# (--yes) albo potwierdzenia interaktywnego. Bez tego tylko pokazuje plan.
# Tryb: --out <katalog> [--yes] [--target <nf>] [--timeout <sek>]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/../lib.sh"

YES=0; TARGET_NF="smf"; DURATION=120
ARGS=()
while [ $# -gt 0 ]; do
	case "$1" in
		--yes) YES=1; shift ;;
		--target) TARGET_NF="$2"; shift 2 ;;
		--timeout) DURATION="$2"; shift 2 ;;
		*) ARGS+=("$1"); shift ;;
	esac
done
set -- "${ARGS[@]}"
parse_out "$@"
need_kubectl
ns_exists || die "Namespace $NS nie istnieje."

OUTFILE="${OUT}/s6_resource_exhaustion.txt"

# UPF wykluczony — jego zakłócenie rozsadza płaszczyznę danych nieproporcjonalnie.
[ "$TARGET_NF" = "upf" ] && die "S6 nie obciąża UPF (CLAUDE.md). Wybierz inną NF (--target smf)."

POD="$(nf_pod "$TARGET_NF")"
[ -z "$POD" ] && die "Brak poda nf=${TARGET_NF} w $NS."

echo "==== S6 — PLAN ===="
echo "Cel obciążenia: $POD (nf=$TARGET_NF), CPU+RAM, timeout ${DURATION}s"
echo "Równolegle mierzone: ping UE, restarty/OOMKilled innych podów, kubectl top."
echo "To może chwilowo pogorszyć dostępność rdzenia."
echo

if [ "$YES" -ne 1 ]; then
	if [ -t 0 ]; then
		printf 'Potwierdź uruchomienie obciążenia S6 [tak/NIE]: '
		read -r ans
		case "$ans" in tak|TAK|yes|y) : ;; *) die "Anulowano (brak potwierdzenia)." ;; esac
	else
		warn "Brak --yes i brak terminala interaktywnego."
		warn "CLAUDE.md: S6 wymaga zgody człowieka. Uruchom ponownie z --yes po akceptacji."
		exit 0
	fi
fi

exec > >(tee "$OUTFILE") 2>&1
section "S6 — WYKONANIE ($(date -Is))"

# Znajdź narzędzie obciążające: stress-ng w podzie albo kontener debug.
STRESS_IN_POD=0
if kubectl exec -n "$NS" "$POD" -- sh -c 'command -v stress-ng >/dev/null 2>&1' 2>/dev/null; then
	STRESS_IN_POD=1
	log "stress-ng dostępny w podzie."
else
	warn "Brak stress-ng w podzie — użyję kontenera debug (kubectl debug, obraz z stress-ng)."
fi

# Monitor w tle: co 5 s zapisuj stan.
MON="${OUT}/s6_timeline.txt"
: > "$MON"
(
	end=$(( $(date +%s) + DURATION + 15 ))
	while [ "$(date +%s)" -lt "$end" ]; do
		ts="$(date +%H:%M:%S)"
		top="$(kubectl top pods -n "$NS" --no-headers 2>/dev/null | tr '\n' ';')"
		restarts="$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '{print $1"="$4}' | tr '\n' ' ')"
		oom="$(kubectl get pods -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"="}{.status.containerStatuses[*].lastState.terminated.reason}{" "}{end}' 2>/dev/null)"
		printf '[%s] TOP: %s | RESTARTS: %s | LASTTERM: %s\n' "$ts" "${top:-n/d}" "$restarts" "$oom" >> "$MON"
		sleep 5
	done
) &
MON_PID=$!

# Równoległy pomiar pinga UE (jeśli jest pod UE).
UE="$(pod_by_selector 'nf=ue')"
[ -z "$UE" ] && UE="$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '/ue/ {print $1; exit}')"
if [ -n "$UE" ]; then
	( kubectl exec -n "$NS" "$UE" -- ping -I uesimtun0 -w "$DURATION" 8.8.8.8 \
		> "${OUT}/s6_ue_ping.txt" 2>&1 || true ) &
	PING_PID=$!
	log "Ping UE w tle -> ${OUT}/s6_ue_ping.txt"
fi

log "Start obciążenia (timeout ${DURATION}s)..."
if [ "$STRESS_IN_POD" -eq 1 ]; then
	kubectl exec -n "$NS" "$POD" -- \
		stress-ng --cpu 2 --vm 1 --vm-bytes 256M --timeout "${DURATION}s" --metrics-brief 2>&1 || true
else
	# Efemeryczny kontener debug współdzielący namespace procesów poda.
	kubectl debug -n "$NS" "$POD" --image=alpine --target="" -- \
		sh -c "apk add --no-cache stress-ng >/dev/null 2>&1; stress-ng --cpu 2 --vm 1 --vm-bytes 256M --timeout ${DURATION}s --metrics-brief" 2>&1 || \
		warn "kubectl debug nie powiodło się — pomiar niepełny."
fi

log "Obciążenie zakończone. Czekam na domknięcie monitorów..."
wait "$MON_PID" 2>/dev/null || true
[ -n "${PING_PID:-}" ] && wait "$PING_PID" 2>/dev/null || true

section "WYNIK — restarty / OOMKilled po teście"
kubectl get pods -n "$NS" -o wide 2>&1

section "S6 — PODSUMOWANIE"
echo "Przebieg czasowy: $MON"
[ -n "$UE" ] && echo "Ping UE: ${OUT}/s6_ue_ping.txt (straty = wpływ na dostępność)"
echo "W Fazie 4 (po LimitRange/ResourceQuota) obciążenie nie powinno zabić sąsiednich podów."
log "Zapisano: $OUTFILE"
