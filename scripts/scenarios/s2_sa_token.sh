#!/usr/bin/env bash
# S2 — Nadużycie tokenu ServiceAccount z przejętego poda do API Kubernetes.
# Zapytania: list pods, get secrets, create pod. Zapisujemy kody HTTP (200/403).
# Tryb: --out <katalog>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/../lib.sh"
parse_out "$@"
need_kubectl
ns_exists || die "Namespace $NS nie istnieje."

OUTFILE="${OUT}/s2_sa_token.txt"
exec > >(tee "$OUTFILE") 2>&1

section "S2 — NADUŻYCIE TOKENU SERVICE ACCOUNT"
echo "Data: $(date -Is) | Namespace: $NS"
echo "Model: napastnik w podzie używa zamontowanego tokenu SA do API k8s."

POD="$(nf_pod amf)"
[ -z "$POD" ] && POD="$(kubectl get pods -n "$NS" -o jsonpath='{.items[0].metadata.name}')"
[ -z "$POD" ] && die "Brak podów w $NS."
echo "Pod źródłowy: $POD"

SATOKEN_DIR="/var/run/secrets/kubernetes.io/serviceaccount"
API="https://kubernetes.default.svc"

# Pomocnik: wykonuje curl Z WNĘTRZA poda, używając zamontowanego tokenu + CA.
# Zwraca tylko kod HTTP. Jeśli brak curl, próbuje wget.
api_code() {
	local method="$1" path="$2" data="${3:-}"
	local script="
		T=\$(cat ${SATOKEN_DIR}/token 2>/dev/null)
		CA=${SATOKEN_DIR}/ca.crt
		if command -v curl >/dev/null 2>&1; then
			if [ -n \"${data}\" ]; then
				curl -s -o /dev/null -w '%{http_code}' --cacert \$CA \
					-H \"Authorization: Bearer \$T\" -H 'Content-Type: application/json' \
					-X ${method} -d '${data}' ${API}${path}
			else
				curl -s -o /dev/null -w '%{http_code}' --cacert \$CA \
					-H \"Authorization: Bearer \$T\" -X ${method} ${API}${path}
			fi
		else
			echo 'NO-CURL'
		fi"
	kubectl exec -n "$NS" "$POD" -- sh -c "$script" 2>/dev/null
}

verdict() { case "$1" in 200|201) echo "POSSIBLE (HTTP $1)";; 401|403) echo "BLOCKED (HTTP $1)";; *) echo "niejednoznaczne (HTTP $1)";; esac; }

section "Czy token jest w ogóle zamontowany?"
if kubectl exec -n "$NS" "$POD" -- sh -c "[ -f ${SATOKEN_DIR}/token ] && echo TAK || echo NIE" 2>/dev/null | grep -q TAK; then
	echo "Token SA OBECNY w podzie -> automount włączony."
else
	echo "Token SA NIEOBECNY -> automountServiceAccountToken: false (dobry stan po hardeningu)."
	echo "WERDYKT S2: BLOCKED (brak tokenu do nadużycia)."
	log "Zapisano: $OUTFILE"; exit 0
fi

section "Próba 1: list pods w namespace ${NS}"
c="$(api_code GET "/api/v1/namespaces/${NS}/pods?limit=1")"
echo "GET pods -> $(verdict "$c")"

section "Próba 2: get secrets w namespace ${NS}"
c="$(api_code GET "/api/v1/namespaces/${NS}/secrets?limit=1")"
echo "GET secrets -> $(verdict "$c")"

section "Próba 3: list pods we WSZYSTKICH namespace (eskalacja zasięgu)"
c="$(api_code GET "/api/v1/pods?limit=1")"
echo "GET pods (all-ns) -> $(verdict "$c")"

section "Próba 4: create pod (dry-run po stronie serwera)"
PAYLOAD='{"apiVersion":"v1","kind":"Pod","metadata":{"name":"s2-probe","namespace":"'"${NS}"'"},"spec":{"containers":[{"name":"c","image":"busybox","command":["sleep","1"]}]}}'
c="$(api_code POST "/api/v1/namespaces/${NS}/pods?dryRun=All" "$PAYLOAD")"
echo "CREATE pod (dryRun) -> $(verdict "$c")"
echo "Uwaga: użyto dryRun=All — nic nie zostało faktycznie utworzone."

section "S2 — PODSUMOWANIE"
echo "Kody 200/201 = uprawnienie nadmiarowe (POSSIBLE); 403 = ograniczone (BLOCKED)."
log "Zapisano: $OUTFILE"
