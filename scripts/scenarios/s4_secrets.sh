#!/usr/bin/env bash
# S4 — Odczyt secrets z przejętego poda: zmienne env, pliki konfiguracyjne
# free5GC (URI/hasło MongoDB), oraz get secret przez API (jeśli S2 pozwala).
# WSZYSTKIE wartości są MASKOWANE — pokazujemy fakt dostępu, nie sekret.
# Tryb: --out <katalog>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/../lib.sh"
parse_out "$@"
need_kubectl
ns_exists || die "Namespace $NS nie istnieje."

OUTFILE="${OUT}/s4_secrets.txt"
exec > >(tee "$OUTFILE") 2>&1

section "S4 — ODCZYT SEKRETÓW Z PRZEJĘTEGO PODA"
echo "Data: $(date -Is) | Namespace: $NS"
echo "Wszystkie wartości maskowane (***MASKED***). Werdykt: POSSIBLE/BLOCKED."

POD="$(nf_pod udr)"
[ -z "$POD" ] && POD="$(nf_pod amf)"
[ -z "$POD" ] && POD="$(kubectl get pods -n "$NS" -o jsonpath='{.items[0].metadata.name}')"
[ -z "$POD" ] && die "Brak podów."
echo "Pod źródłowy: $POD"

section "1) Zmienne środowiskowe (filtr sekretów, maskowane)"
envout="$(kubectl exec -n "$NS" "$POD" -- env 2>/dev/null | grep -Ei 'pass|secret|key|mongo|token|uri' | mask_secrets)"
if [ -n "$envout" ]; then
	echo "$envout" | sed 's/^/  /'
	echo "WERDYKT: dane wrażliwe widoczne w env -> POSSIBLE (zalecenie: montuj jako pliki)"
else
	echo "  (brak wrażliwych zmiennych w env)"
	echo "WERDYKT: BLOCKED/czyste"
fi

section "2) Pliki konfiguracyjne free5GC (szukam URI/hasła MongoDB, maskowane)"
# Typowe lokalizacje konfiguracji w obrazach free5GC.
cfg="$(kubectl exec -n "$NS" "$POD" -- sh -c '
	for d in /free5gc/config /etc/free5gc /config; do
		[ -d "$d" ] && grep -RilE "mongo|uri|password" "$d" 2>/dev/null
	done' 2>/dev/null)"
if [ -n "$cfg" ]; then
	echo "Pliki z potencjalnymi sekretami:"
	echo "$cfg" | sed 's/^/  /'
	echo "--- Fragmenty (maskowane) ---"
	for f in $cfg; do
		kubectl exec -n "$NS" "$POD" -- sh -c "grep -iE 'mongo|uri|password' '$f' 2>/dev/null | head -5" 2>/dev/null | mask_secrets | sed "s#^#  [$f] #"
	done
	echo "WERDYKT: URI/hasło MongoDB czytelne z poda -> POSSIBLE"
else
	echo "  (nie znaleziono plików konfiguracyjnych z sekretami w typowych lokalizacjach)"
fi

section "3) get secret przez API (zależne od S2 / RBAC)"
SATOKEN_DIR="/var/run/secrets/kubernetes.io/serviceaccount"
API="https://kubernetes.default.svc"
if kubectl exec -n "$NS" "$POD" -- sh -c "[ -f ${SATOKEN_DIR}/token ]" 2>/dev/null; then
	# Pobierz listę nazw secretów (jeśli RBAC pozwala); wartości zamaskujemy.
	resp="$(kubectl exec -n "$NS" "$POD" -- sh -c "
		T=\$(cat ${SATOKEN_DIR}/token); CA=${SATOKEN_DIR}/ca.crt
		command -v curl >/dev/null 2>&1 && curl -s --cacert \$CA -H \"Authorization: Bearer \$T\" \
			${API}/api/v1/namespaces/${NS}/secrets 2>/dev/null | head -c 2000" 2>/dev/null)"
	if echo "$resp" | grep -q '"kind":"SecretList"'; then
		echo "API zwróciło SecretList -> SA może czytać secrety -> POSSIBLE"
		echo "Nazwy secretów (bez danych):"
		echo "$resp" | grep -oE '"name":"[^"]+"' | head -10 | sed 's/^/  /'
		echo "(wartości base64 celowo pominięte/maskowane)"
	elif echo "$resp" | grep -qi 'forbidden'; then
		echo "API: Forbidden -> SA bez prawa get secrets -> BLOCKED"
	else
		echo "API: odpowiedź niejednoznaczna (brak curl lub inny błąd)."
	fi
else
	echo "Brak tokenu SA w podzie -> BLOCKED (nie da się pytać API)."
fi

section "S4 — PODSUMOWANIE"
echo "Patrz werdykty. Hardening: secrety jako pliki + RBAC ograniczający get secrets."
log "Zapisano: $OUTFILE"
