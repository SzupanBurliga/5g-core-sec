#!/usr/bin/env bash
# S5 — Łańcuch dostaw (opcjonalny). Skan obrazów używanych w namespace przez
# Trivy (HIGH,CRITICAL). Liczy CVE per obraz. Nie wdraża nic nowego.
# Tryb: --out <katalog>
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/../lib.sh"
parse_out "$@"
need_kubectl
ns_exists || die "Namespace $NS nie istnieje."

OUTFILE="${OUT}/s5_supply_chain.txt"
mkdir -p "${OUT}/trivy"
exec > >(tee "$OUTFILE") 2>&1

section "S5 — SKAN OBRAZÓW (Trivy)"
echo "Data: $(date -Is) | Namespace: $NS"

if ! command -v trivy >/dev/null 2>&1; then
	warn "Brak trivy. Zainstaluj, np.:"
	echo "  sudo apt-get install -y wget apt-transport-https gnupg"
	echo "  wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo gpg --dearmor -o /usr/share/keyrings/trivy.gpg"
	echo "  echo \"deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb \$(lsb_release -sc) main\" | sudo tee /etc/apt/sources.list.d/trivy.list"
	echo "  sudo apt-get update && sudo apt-get install -y trivy"
	echo "WERDYKT: SKIP (brak narzędzia)"
	exit 0
fi

# Zbierz unikalne obrazy z podów namespace.
IMAGES="$(kubectl get pods -n "$NS" -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' | sort -u)"
echo "Obrazy w namespace:"
echo "$IMAGES" | sed 's/^/  /'
echo

printf '%-50s %-8s %-10s\n' "OBRAZ" "HIGH" "CRITICAL"
for img in $IMAGES; do
	safe="$(echo "$img" | tr '/:' '__')"
	json="${OUT}/trivy/${safe}.json"
	trivy image --quiet --severity HIGH,CRITICAL --format json --output "$json" "$img" 2>/dev/null || {
		printf '%-50s %-8s %-10s\n' "$img" "ERR" "ERR"; continue; }
	high="$(grep -o '"Severity":"HIGH"' "$json" | wc -l)"
	crit="$(grep -o '"Severity":"CRITICAL"' "$json" | wc -l)"
	printf '%-50s %-8s %-10s\n' "$img" "$high" "$crit"
done

section "Porównanie ze starą wersją (opcjonalnie)"
echo "Jeśli używacie wariantu 1B, przeskanuj też stary tag dla porównania, np.:"
echo "  trivy image --severity HIGH,CRITICAL free5gc/amf:v3.2.0"
echo "(bez wdrażania tego obrazu w klastrze)"

section "S5 — PODSUMOWANIE"
echo "Liczba CVE HIGH/CRITICAL per obraz powyżej. Pełne raporty: ${OUT}/trivy/"
log "Zapisano: $OUTFILE"
