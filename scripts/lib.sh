# shellcheck shell=bash
# Wspólne funkcje dla skryptów projektu. Źródłuj przez: source "$(dirname "$0")/lib.sh"
# Nie wykonywać bezpośrednio.

# Namespace i etykiety wg manifestów niloysh/free5gc-k8s (NIE zgadywane).
NS="${NS:-free5gc}"
APP_LABEL="${APP_LABEL:-app=free5gc}"
SBI_PORT="${SBI_PORT:-8000}"
MONGO_PORT="${MONGO_PORT:-27017}"
WEBUI_NODEPORT="${WEBUI_NODEPORT:-30505}"

# Lista funkcji sieciowych (wartości etykiety nf=...).
NF_LIST="${NF_LIST:-nrf amf smf upf ausf udm udr nssf pcf}"

# Kolory tylko gdy terminal interaktywny.
if [ -t 1 ]; then
	C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_RED=$'\033[31m'
	C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
	C_RESET=; C_BOLD=; C_RED=; C_GREEN=; C_YELLOW=; C_BLUE=
fi

log()  { printf '%s[*]%s %s\n' "$C_BLUE"  "$C_RESET" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_RED"   "$C_RESET" "$*" >&2; }
die()  { err "$*"; exit 1; }

# Nagłówek sekcji do pliku wyniku i na ekran.
section() {
	printf '\n==== %s ====\n' "$*"
}

# Wykryj kubectl; projekt zakłada uruchomienie wewnątrz VM free5gc.
need_kubectl() {
	command -v kubectl >/dev/null 2>&1 || die "Brak kubectl w PATH. Uruchom skrypt wewnątrz VM free5gc (multipass exec free5gc -- ...)."
	kubectl version --request-timeout=10s >/dev/null 2>&1 \
		|| warn "kubectl nie łączy się z API klastra (sprawdź, czy jesteś w VM i klaster działa)."
}

# Czy namespace istnieje.
ns_exists() { kubectl get ns "$NS" >/dev/null 2>&1; }

# Pierwszy pod danej funkcji sieciowej (nf=<name>), pusto jeśli brak.
nf_pod() {
	local nf="$1"
	kubectl get pods -n "$NS" -l "nf=${nf}" \
		-o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Pierwszy działający pod po dowolnym selektorze.
pod_by_selector() {
	local sel="$1"
	kubectl get pods -n "$NS" -l "$sel" --field-selector=status.phase=Running \
		-o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# ClusterIP usługi danej NF (jeśli istnieje usługa o tej nazwie).
svc_ip() {
	local svc="$1"
	kubectl get svc -n "$NS" "$svc" -o jsonpath='{.spec.clusterIP}' 2>/dev/null
}

# Maskuj potencjalne sekrety w strumieniu (hasła, URI mongo, tokeny, klucze).
# Pokazujemy, że wartość ISTNIEJE, nie samą wartość.
mask_secrets() {
	sed -E \
		-e 's/(mongodb(\+srv)?:\/\/[^:]+:)[^@]+(@)/\1***MASKED***\3/gi' \
		-e 's/((pass(word)?|secret|token|apikey|api_key|key)[^=:]*[=:][[:space:]]*)[^[:space:]"'"'"']+/\1***MASKED***/gi'
}

# Przygotuj katalog wyjściowy; echo jego ścieżki.
ensure_outdir() {
	local d="$1"
	[ -n "$d" ] || die "Brak katalogu wyjściowego."
	mkdir -p "$d"
	printf '%s\n' "$d"
}

# Parsuj --out <dir> ze scenariuszy; ustawia globalną OUT.
OUT=""
parse_out() {
	while [ $# -gt 0 ]; do
		case "$1" in
			--out) OUT="$2"; shift 2 ;;
			--out=*) OUT="${1#*=}"; shift ;;
			*) shift ;;
		esac
	done
	[ -n "$OUT" ] || OUT="results/before"
	mkdir -p "$OUT"
}

# Uruchom komendę w podzie; jeśli w obrazie brak narzędzia, spróbuj efemeryczny
# kontener debug (kubectl debug). Zwraca wyjście komendy.
# Użycie: pod_exec <pod> -- <cmd...>
pod_exec() {
	local pod="$1"; shift
	[ "$1" = "--" ] && shift
	kubectl exec -n "$NS" "$pod" -- "$@" 2>&1
}

# Test połączenia TCP z poda do host:port. Zwraca "OK" lub "BLOCKED".
# Próbuje kolejno: bash /dev/tcp, nc, curl. Timeout krótki.
tcp_probe() {
	local pod="$1" host="$2" port="$3" timeout="${4:-5}"
	local out
	# bash /dev/tcp (najczęściej dostępne w obrazach free5GC opartych o bash)
	out=$(kubectl exec -n "$NS" "$pod" -- timeout "$timeout" bash -c \
		"exec 3<>/dev/tcp/${host}/${port} && echo OPEN" 2>/dev/null)
	if [ "$out" = "OPEN" ]; then printf 'OK\n'; return 0; fi
	# nc
	if kubectl exec -n "$NS" "$pod" -- sh -c "command -v nc >/dev/null 2>&1"; then
		if kubectl exec -n "$NS" "$pod" -- timeout "$timeout" nc -z -w "$timeout" "$host" "$port" >/dev/null 2>&1; then
			printf 'OK\n'; return 0
		fi
		printf 'BLOCKED\n'; return 1
	fi
	# curl (dla portów HTTP/SBI)
	if kubectl exec -n "$NS" "$pod" -- sh -c "command -v curl >/dev/null 2>&1"; then
		if kubectl exec -n "$NS" "$pod" -- timeout "$timeout" curl -s -o /dev/null --connect-timeout "$timeout" "http://${host}:${port}/" >/dev/null 2>&1; then
			printf 'OK\n'; return 0
		fi
		printf 'BLOCKED\n'; return 1
	fi
	printf 'BLOCKED\n'; return 1
}
