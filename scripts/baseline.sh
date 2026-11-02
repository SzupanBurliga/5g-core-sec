#!/usr/bin/env bash
# Faza 2 — Baseline. Mierzy stan namespace free5gc. Idempotentny, NIC nie zmienia.
# Ten sam skrypt w Fazie 4 do pomiaru "po".
# Użycie: scripts/baseline.sh <katalog_wyjściowy>   (np. results/before | results/after)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"

OUTDIR="$(ensure_outdir "${1:-results/before}")"
need_kubectl
ns_exists || die "Namespace $NS nie istnieje. Najpierw Faza 1 (setup.sh)."

log "Baseline -> $OUTDIR (namespace: $NS)"

# 1. Inwentarz
{
	section "INWENTARZ (pods, svc, sa, secrets, netpol, quota, limitrange)"
	kubectl get pods,svc,sa,secrets,networkpolicy,resourcequota,limitrange \
		-n "$NS" -o wide 2>&1
	echo
	section "Etykiety podów (app / nf)"
	kubectl get pods -n "$NS" \
		-o custom-columns='POD:.metadata.name,APP:.metadata.labels.app,NF:.metadata.labels.nf' 2>&1
} > "${OUTDIR}/inventory.txt"
ok "inventory.txt"

# 2. Sieć wschód-zachód: macierz AMF -> inne NF (SBI 8000) i -> MongoDB (27017)
{
	section "MACIERZ SIECI E-W (źródło AMF)"
	echo "Legenda: OK = połączenie przeszło, BLOCKED = odrzucone/timeout"
	echo
	src_pod="$(nf_pod amf)"
	if [ -z "$src_pod" ]; then
		echo "Brak poda AMF — pomijam aktywne próby."
	else
		printf '%-10s %-28s %-6s %s\n' "ŹRÓDŁO" "CEL" "PORT" "WYNIK"
		for nf in $NF_LIST; do
			[ "$nf" = "amf" ] && continue
			ip="$(svc_ip "$nf")"
			[ -z "$ip" ] && ip="$(nf_pod "$nf" | xargs -r -I{} kubectl get pod -n "$NS" {} -o jsonpath='{.status.podIP}' 2>/dev/null)"
			[ -z "$ip" ] && { printf '%-10s %-28s %-6s %s\n' amf "$nf" "$SBI_PORT" "n/d(brak)"; continue; }
			res="$(tcp_probe "$src_pod" "$ip" "$SBI_PORT")"
			printf '%-10s %-28s %-6s %s\n' amf "${nf}(${ip})" "$SBI_PORT" "$res"
		done
		# MongoDB
		mip="$(svc_ip mongodb)"
		[ -z "$mip" ] && mip="$(pod_by_selector 'app=mongodb' | xargs -r -I{} kubectl get pod -n "$NS" {} -o jsonpath='{.status.podIP}' 2>/dev/null)"
		if [ -n "$mip" ]; then
			res="$(tcp_probe "$src_pod" "$mip" "$MONGO_PORT")"
			printf '%-10s %-28s %-6s %s\n' amf "mongodb(${mip})" "$MONGO_PORT" "$res"
		fi
	fi
} > "${OUTDIR}/net-matrix.txt"
ok "net-matrix.txt"

# 3. RBAC
{
	section "RBAC — uprawnienia per ServiceAccount"
	for sa in $(kubectl get sa -n "$NS" -o jsonpath='{.items[*].metadata.name}'); do
		echo "--- SA: ${sa} ---"
		kubectl auth can-i --list \
			--as="system:serviceaccount:${NS}:${sa}" -n "$NS" 2>&1 | sed 's/^/  /'
		echo
	done
	section "Montowanie tokenu SA w podach"
	for pod in $(kubectl get pods -n "$NS" -o jsonpath='{.items[*].metadata.name}'); do
		mounted="$(kubectl exec -n "$NS" "$pod" -- sh -c \
			'[ -f /var/run/secrets/kubernetes.io/serviceaccount/token ] && echo TOKEN-OBECNY || echo brak' 2>/dev/null)"
		printf '  %-40s %s\n' "$pod" "${mounted:-n/d}"
	done
} > "${OUTDIR}/rbac.txt"
ok "rbac.txt"

# 4. Secrets / konfiguracja (maskowane)
{
	section "SECRETS / CONFIGMAP (lista, bez wartości)"
	kubectl get secrets,configmap -n "$NS" 2>&1
	echo
	section "Zmienne środowiskowe podów (filtr pass|secret|key|mongo|token, MASKOWANE)"
	for pod in $(kubectl get pods -n "$NS" -o jsonpath='{.items[*].metadata.name}'); do
		envout="$(kubectl exec -n "$NS" "$pod" -- env 2>/dev/null \
			| grep -Ei 'pass|secret|key|mongo|token' | mask_secrets)"
		if [ -n "$envout" ]; then
			echo "--- $pod ---"
			echo "$envout" | sed 's/^/  /'
		fi
	done
} > "${OUTDIR}/secrets.txt"
ok "secrets.txt"

# 5. securityContext
{
	section "securityContext per kontener"
	printf '%-36s %-10s %-9s %-10s %-8s %-18s %s\n' \
		POD CONTAINER PRIV RUNASNONROOT ROOTFS CAPS-ADD HOST
	kubectl get pods -n "$NS" -o json | python3 - "$NS" <<'PY' 2>/dev/null || echo "(python3 niedostępny — użyj jsonpath)"
import json,sys
data=json.load(sys.stdin)
for it in data.get("items",[]):
    pod=it["metadata"]["name"]
    spec=it["spec"]
    hostnet=spec.get("hostNetwork",False)
    hostpaths=[v["name"] for v in spec.get("volumes",[]) if v.get("hostPath")]
    for c in spec.get("containers",[]):
        sc=c.get("securityContext",{}) or {}
        priv=sc.get("privileged",False)
        rnr=sc.get("runAsNonRoot","-")
        rofs=sc.get("readOnlyRootFilesystem","-")
        caps=(sc.get("capabilities",{}) or {}).get("add",[])
        host=f"net={hostnet}"+(f",hostPath={hostpaths}" if hostpaths else "")
        print(f'{pod:<36} {c["name"]:<10} {str(priv):<9} {str(rnr):<10} {str(rofs):<8} {",".join(caps) or "-":<18} {host}')
PY
	echo
	echo "Uwaga: UPF zwykle wymaga uprawnień do gtp5g (privileged / NET_ADMIN) — traktuj osobno."
} > "${OUTDIR}/securitycontext.txt"
ok "securitycontext.txt"

# 6. Zasoby
{
	section "requests / limits per kontener"
	kubectl get pods -n "$NS" -o custom-columns=\
'POD:.metadata.name,'\
'CONTAINER:.spec.containers[*].name,'\
'CPU_REQ:.spec.containers[*].resources.requests.cpu,'\
'MEM_REQ:.spec.containers[*].resources.requests.memory,'\
'CPU_LIM:.spec.containers[*].resources.limits.cpu,'\
'MEM_LIM:.spec.containers[*].resources.limits.memory' 2>&1
} > "${OUTDIR}/resources.txt"
ok "resources.txt"

log "Baseline zakończony. Pliki w: $OUTDIR"
