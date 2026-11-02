#!/usr/bin/env bash
# S3 — Ruch między CNF (wschód-zachód). Aktywna macierz: które CNF łączą się
# z którymi (SBI 8000) i z MongoDB (27017). Dokumentujemy ograniczenie Multus.
# Tryb: --out <katalog>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/../lib.sh"
parse_out "$@"
need_kubectl
ns_exists || die "Namespace $NS nie istnieje."

OUTFILE="${OUT}/s3_east_west.txt"
exec > >(tee "$OUTFILE") 2>&1

section "S3 — MACIERZ POŁĄCZEŃ MIĘDZY CNF"
echo "Data: $(date -Is) | Namespace: $NS"
echo "OK = połączenie przeszło, BLOCKED = odrzucone/timeout, n/d = brak poda/usługi"
echo

# Zbierz IP docelowe (ClusterIP usługi NF, fallback: podIP).
declare -A TARGET_IP
for nf in $NF_LIST; do
	ip="$(svc_ip "$nf")"
	if [ -z "$ip" ]; then
		p="$(nf_pod "$nf")"
		[ -n "$p" ] && ip="$(kubectl get pod -n "$NS" "$p" -o jsonpath='{.status.podIP}' 2>/dev/null)"
	fi
	TARGET_IP[$nf]="$ip"
done
MONGO_IP="$(svc_ip mongodb)"
[ -z "$MONGO_IP" ] && MONGO_IP="$(pod_by_selector 'app=mongodb' | xargs -r -I{} kubectl get pod -n "$NS" {} -o jsonpath='{.status.podIP}' 2>/dev/null)"

# Nagłówek macierzy.
printf '\n%-8s' "SRC\\DST"
for d in $NF_LIST mongo; do printf '%-8s' "$d"; done
printf '\n'

for src in $NF_LIST; do
	spod="$(nf_pod "$src")"
	printf '%-8s' "$src"
	for d in $NF_LIST; do
		if [ -z "$spod" ] || [ -z "${TARGET_IP[$d]}" ] || [ "$src" = "$d" ]; then
			printf '%-8s' "-"
			continue
		fi
		r="$(tcp_probe "$spod" "${TARGET_IP[$d]}" "$SBI_PORT" 4)"
		[ "$r" = "OK" ] && printf '%-8s' "OK" || printf '%-8s' "BLK"
	done
	# kolumna mongo
	if [ -n "$spod" ] && [ -n "$MONGO_IP" ]; then
		r="$(tcp_probe "$spod" "$MONGO_IP" "$MONGO_PORT" 4)"
		[ "$r" = "OK" ] && printf '%-8s' "OK" || printf '%-8s' "BLK"
	else
		printf '%-8s' "-"
	fi
	printf '\n'
done

section "OGRANICZENIE: interfejsy Multus (N2/N3/N4)"
echo "NetworkPolicy k8s działa na sieci CNI podstawowej, NIE na dodatkowych"
echo "interfejsach Multus (macvlan/N2/N3/N4). Sprawdzam obecność takich interfejsów:"
for nf in amf smf upf; do
	p="$(nf_pod "$nf")"
	[ -z "$p" ] && continue
	echo "--- $nf ($p) ---"
	kubectl exec -n "$NS" "$p" -- ip -br a 2>/dev/null | grep -vE '^(lo|eth0)' | sed 's/^/  /' || true
done
echo
echo "WNIOSEK: ruch na powyższych interfejsach może omijać NetworkPolicy."
echo "Opisujemy to jako ograniczenie metody — NIE próbujemy go obchodzić."

section "S3 — PODSUMOWANIE"
echo "Macierz powyżej = stan '$OUT'. W Fazie 4 ta sama macierz pokaże efekt NetworkPolicy."
log "Zapisano: $OUTFILE"
