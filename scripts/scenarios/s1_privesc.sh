#!/usr/bin/env bash
# S1 — Eskalacja z przejętego poda (model: napastnik ma jeden pod CNF).
# Pokazujemy WARUNKI do eskalacji, NIE wykonujemy niszczącej ucieczki z kontenera.
# Tryb: --out <katalog>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/../lib.sh"
parse_out "$@"
need_kubectl
ns_exists || die "Namespace $NS nie istnieje."

OUTFILE="${OUT}/s1_privesc.txt"
exec > >(tee "$OUTFILE") 2>&1

section "S1 — WARUNKI ESKALACJI Z PODA"
echo "Data: $(date -Is) | Namespace: $NS"
echo "Cel: wykazać, czy przejęty pod daje warunki do eskalacji na host/klaster."
echo "Uwaga: to pomiar read-only; nie montujemy hosta ani nie modyfikujemy runtime."

# Badamy AMF (typowa CNF) i UPF (zwykle uprzywilejowany przez gtp5g).
TARGETS="amf upf"

for nf in $TARGETS; do
	pod="$(nf_pod "$nf")"
	section "NF=${nf}  pod=${pod:-BRAK}"
	[ -z "$pod" ] && { echo "Brak poda — pomijam."; continue; }

	echo "--- Tożsamość (id) ---"
	pod_exec "$pod" -- id || true

	echo "--- Czy root (uid=0)? ---"
	uid="$(pod_exec "$pod" -- id -u 2>/dev/null)"
	if [ "$uid" = "0" ]; then
		echo "WERDYKT: root w kontenerze (uid=0) -> POSSIBLE (brak runAsNonRoot)"
	else
		echo "WERDYKT: uid=${uid} (nie-root) -> ograniczone"
	fi

	echo "--- Efektywne capabilities (/proc/self/status CapEff) ---"
	pod_exec "$pod" -- sh -c 'grep Cap /proc/self/status' || true
	capeff="$(pod_exec "$pod" -- sh -c 'grep CapEff /proc/self/status' 2>/dev/null | awk '{print $2}')"
	# 0000003fffffffff / ...ffffffff => pełny zestaw (privileged)
	case "$capeff" in
		*ffffffff) echo "WERDYKT: pełny zestaw capabilities -> kontener prawdopodobnie privileged -> POSSIBLE" ;;
		"" ) echo "Nie odczytano CapEff." ;;
		* ) echo "WERDYKT: ograniczony zestaw capabilities (CapEff=$capeff)" ;;
	esac

	echo "--- Widoczność gniazd runtime / plików hosta (tylko odczyt listy) ---"
	pod_exec "$pod" -- sh -c '
		for p in /run/containerd/containerd.sock /var/run/docker.sock /run/crio/crio.sock; do
			[ -S "$p" ] && echo "WIDOCZNE gniazdo runtime: $p (POSSIBLE)" || true
		done
		[ -r /proc/1/root/etc/hostname ] && echo "Widoczny /proc/1/root (hostPath / privileged?)"
		mount 2>/dev/null | grep -Ei "hostpath|/var/lib/kubelet" | head -3 || true
		true' || true

	echo "--- Czy można by zamontować (test uprawnienia, BEZ faktycznego montowania) ---"
	# Sprawdzamy tylko, czy polecenie mount jest dozwolone (brak -> permission denied).
	if pod_exec "$pod" -- sh -c 'mount 2>&1 | head -1' | grep -qi 'permission denied'; then
		echo "WERDYKT: mount odrzucony -> brak CAP_SYS_ADMIN -> BLOCKED"
	else
		echo "WERDYKT: mount dostępny -> warunek do użycia hostPath/urządzeń -> POSSIBLE (nie wykonujemy)"
	fi

	echo "--- allowPrivilegeEscalation / no_new_privs ---"
	pod_exec "$pod" -- sh -c 'grep NoNewPrivs /proc/self/status' || true
done

section "S1 — PODSUMOWANIE"
echo "Patrz werdykty POSSIBLE/BLOCKED powyżej. UPF opisujemy jako wymagający wyjątku (gtp5g)."
log "Zapisano: $OUTFILE"
