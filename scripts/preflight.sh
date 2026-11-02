#!/usr/bin/env bash
# Faza 0 — Preflight. Zbiera stan VM i ocenia względem wymagań z CLAUDE.md sek. 3.
# Idempotentny, niczego nie zmienia. Uruchamiać WEWNĄTRZ VM free5gc.
# Wynik: results/preflight.txt
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

OUTFILE="${1:-${REPO_ROOT}/results/preflight.txt}"
mkdir -p "$(dirname "$OUTFILE")"

# Wszystko loguj równocześnie na ekran i do pliku.
exec > >(tee "$OUTFILE") 2>&1

log "Preflight start: $(date -Is)"

section "OS / dystrybucja"
lsb_release -a 2>/dev/null || cat /etc/os-release

section "Jądro"
uname -r
KERNEL="$(uname -r)"

section "CPU / RAM / dysk"
echo "nproc: $(nproc)"
free -h
df -h /

section "Narzędzia"
for t in git curl helm kubectl docker containerd trivy stress-ng; do
	if command -v "$t" >/dev/null 2>&1; then
		printf '%-12s OK  (%s)\n' "$t" "$(command -v "$t")"
	else
		printf '%-12s BRAK\n' "$t"
	fi
done

section "Secure Boot"
if command -v mokutil >/dev/null 2>&1; then
	mokutil --sb-state 2>&1
else
	echo "mokutil: BRAK (zainstaluj, by sprawdzić Secure Boot)"
fi

section "SCTP (NGAP gNB <-> AMF)"
if sudo modprobe sctp 2>/dev/null; then
	if lsmod | grep -q '^sctp'; then echo "sctp: ZAŁADOWANY"; else echo "sctp: modprobe ok, brak w lsmod"; fi
else
	echo "sctp: NIE DA SIĘ ZAŁADOWAĆ -> sudo apt install linux-modules-extra-$(uname -r)"
fi
lsmod | grep -E '^sctp' || true

section "openvswitch (interfejsy Multus / OVS-CNI)"
if sudo modprobe openvswitch 2>/dev/null; then
	echo "openvswitch: ok"
else
	echo "openvswitch: NIE DA SIĘ ZAŁADOWAĆ"
fi

section "gtp5g (moduł UPF)"
if lsmod | grep -q '^gtp5g'; then echo "gtp5g: ZAŁADOWANY"; else echo "gtp5g: brak (ładowany przy setupie UPF)"; fi

section "cloud-init"
command -v cloud-init >/dev/null 2>&1 && cloud-init status 2>&1 || echo "cloud-init: brak / n/d"

# --- Ocena względem wymagań ---
section "OCENA"
PROBLEMS=0

case "$KERNEL" in
	*microsoft*|*WSL*)
		err "To wygląda na WSL ($KERNEL). gtp5g to moduł jądra — klaster musi stać w VM Multipass, nie w WSL."
		PROBLEMS=$((PROBLEMS+1)) ;;
	*) ok "Jądro nie jest WSL." ;;
esac

MEM_MB="$(free -m | awk '/^Mem:/ {print $2}')"
if [ "${MEM_MB:-0}" -lt 8000 ]; then
	err "RAM ${MEM_MB} MB < 8 GB. Zwiększ pamięć VM (człowiek: multipass set local.free5gc.memory=12G)."
	PROBLEMS=$((PROBLEMS+1))
else
	ok "RAM ${MEM_MB} MB."
fi

if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
	err "Secure Boot WŁĄCZONY — jądro może odrzucić niepodpisany gtp5g. Zgłoś człowiekowi."
	PROBLEMS=$((PROBLEMS+1))
else
	ok "Secure Boot wyłączony lub n/d."
fi

if ! lsmod | grep -q '^sctp'; then
	warn "SCTP nie załadowany — gNB nie zestawi NGAP. Spróbuj linux-modules-extra-$(uname -r)."
	PROBLEMS=$((PROBLEMS+1))
else
	ok "SCTP dostępny."
fi

echo
if [ "$PROBLEMS" -eq 0 ]; then
	ok "Preflight OK — można przejść do Fazy 1."
else
	warn "Preflight: ${PROBLEMS} problem(ów). Zatrzymaj się i zgłoś człowiekowi (CLAUDE.md sek. 3, Faza 0)."
fi

log "Zapisano do: $OUTFILE"
