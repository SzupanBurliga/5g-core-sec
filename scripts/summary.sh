#!/usr/bin/env bash
# Faza 5 — buduje tabelę przed/po do results/summary.md na podstawie werdyktów
# (POSSIBLE/BLOCKED) z plików w results/before i results/after.
# Użycie: scripts/summary.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
BEFORE="${REPO_ROOT}/results/before"
AFTER="${REPO_ROOT}/results/after"
OUT="${REPO_ROOT}/results/summary.md"

# Zlicz werdykty w pliku: zwraca "P=<n> B=<n>".
verdicts() {
	local f="$1"
	[ -f "$f" ] || { echo "brak"; return; }
	local p b
	# grep -c sam wypisuje 0 przy braku dopasowań (exit 1) — "|| echo 0" dawało "0\n0"
	p="$(grep -ic 'POSSIBLE' "$f" 2>/dev/null)" || true
	b="$(grep -ic 'BLOCKED' "$f" 2>/dev/null)" || true
	echo "P=${p} B=${b}"
}

# Skrót stanu scenariusza do jednego słowa.
state() {
	local f="$1"
	[ -f "$f" ] || { echo "n/d"; return; }
	if grep -qi 'POSSIBLE' "$f"; then echo "PODATNE"; else echo "OK"; fi
}

row() {
	local label="$1" file="$2" mech="$3"
	local bf="${BEFORE}/${file}" af="${AFTER}/${file}"
	printf '| %s | %s (%s) | %s (%s) | %s | `%s` |\n' \
		"$label" "$(state "$bf")" "$(verdicts "$bf")" \
		"$(state "$af")" "$(verdicts "$af")" "$mech" "results/*/${file}"
}

log "Buduję $OUT"
{
	echo "# Podsumowanie przed/po — bezpieczeństwo CNF free5GC"
	echo
	echo "Wygenerowano: $(date -Is)"
	echo "Stan 'PODATNE' = wykryto co najmniej jeden werdykt POSSIBLE; 'OK' = brak."
	echo "W nawiasie liczba werdyktów P=POSSIBLE / B=BLOCKED w pliku dowodowym."
	echo
	echo "| Scenariusz | Przed | Po | Mechanizm | Plik z dowodem |"
	echo "| --- | --- | --- | --- | --- |"
	row "S1 — eskalacja z poda"        "s1_privesc.txt"             "PodSecurity, runAsNonRoot, drop caps (04)"
	row "S2 — token SA do API"         "s2_sa_token.txt"            "automountServiceAccountToken:false, RBAC (03)"
	row "S3 — ruch między CNF"         "s3_east_west.txt"           "NetworkPolicy default-deny + allow (01,02)"
	row "S4 — odczyt secrets"          "s4_secrets.txt"             "secrety jako pliki, RBAC get secrets (06)"
	row "S5 — łańcuch dostaw"          "s5_supply_chain.txt"        "skan obrazów, aktualizacja (poza k8s)"
	row "S6 — wyczerpanie zasobów"     "s6_resource_exhaustion.txt" "ResourceQuota + LimitRange (05)"
	echo
	echo "## Macierz połączeń S3 (wschód-zachód)"
	echo
	echo "### Przed"
	echo '```'
	if [ -f "${BEFORE}/s3_east_west.txt" ]; then sed -n '/SRC\\DST/,/OGRANICZENIE/p' "${BEFORE}/s3_east_west.txt"; else echo "(brak results/before/s3_east_west.txt)"; fi
	echo '```'
	echo "### Po"
	echo '```'
	if [ -f "${AFTER}/s3_east_west.txt" ]; then sed -n '/SRC\\DST/,/OGRANICZENIE/p' "${AFTER}/s3_east_west.txt"; else echo "(brak results/after/s3_east_west.txt)"; fi
	echo '```'
	echo
	echo "## Ograniczenia metody"
	echo
	echo "- **NetworkPolicy a Multus:** reguły (01,02) obejmują sieć CNI podstawową."
	echo "  Interfejsy N2/N3/N4 (macvlan/Multus) mogą nie podlegać NetworkPolicy —"
	echo "  patrz sekcja 'OGRANICZENIE' w \`results/*/s3_east_west.txt\`."
	echo "- **Wyjątek dla UPF:** UPF wymaga NET_ADMIN/gtp5g, więc nie przechodzi"
	echo "  poziomu *restricted*. Trzymany na *baseline* lub w osobnym namespace —"
	echo "  opis w \`docs/setup-notes.md\`."
	echo "- **S6:** uruchamiany wyłącznie za zgodą człowieka, z limitem czasu."
} > "$OUT"

ok "Zapisano: $OUT"
cat "$OUT"
