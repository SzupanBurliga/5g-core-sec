#!/usr/bin/env bash
# Faza 1 — stawia klaster i rdzeń 5G. Wariant: niloysh/testbed-automator (k8s)
# + niloysh/free5gc-k8s (free5GC v3.2.0) + UERANSIM. Abonent przez API WebUI.
#
# Uruchamiać WEWNĄTRZ VM free5gc jako zwykły użytkownik (nie root).
# Idempotentny: ponowne uruchomienie nie duplikuje obiektów.
#
# NIE uruchamiać bez przeglądu — zmienia klaster. CLAUDE.md: zatrzymaj się i
# pytaj człowieka przy zmianie jądra / reinstalacji klastra.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "${SCRIPT_DIR}/lib.sh"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SRC_DIR="${SRC_DIR:-${HOME}/src}"
TESTBED_REPO="https://github.com/niloysh/testbed-automator.git"
FREE5GC_REPO="https://github.com/niloysh/free5gc-k8s.git"
WEBUI_USER="${WEBUI_USER:-admin}"
WEBUI_PASS="${WEBUI_PASS:-free5gc}"

usage() {
	cat <<EOF
Użycie: $0 [etap]
Etapy (domyślnie: all, po kolei):
  cluster     testbed-automator -> klaster k8s single-node
  gtp5g       zbuduj i załaduj moduł gtp5g (bin/install-gtp5g.sh)
  core        wdróż mongodb, networks5g, free5gc, webui
  subscriber  dodaj abonenta przez API WebUI (ue1)
  ran         wdróż UERANSIM gNB + UE
  verify      sprawdź pody Running i NGAP
  all         wszystkie powyższe po kolei

Zmienne: SRC_DIR (domyślnie ~/src), WEBUI_USER, WEBUI_PASS.
EOF
}

git_sync() {
	# Sklonuj repo jeśli brak; w przeciwnym razie zostaw jak jest (nie nadpisuj lokalnych zmian).
	local url="$1" dir="$2"
	if [ -d "$dir/.git" ]; then
		ok "Repo istnieje: $dir (pomijam clone)"
	else
		log "git clone $url -> $dir"
		git clone "$url" "$dir" || die "git clone nie powiodło się: $url"
	fi
}

stage_cluster() {
	section "KLASTER (testbed-automator)"
	git_sync "$TESTBED_REPO" "${SRC_DIR}/testbed-automator"
	if kubectl get nodes >/dev/null 2>&1 && kubectl get nodes | grep -q ' Ready '; then
		ok "Klaster już działa (węzeł Ready) — pomijam install.sh."
	else
		warn "Uruchamiam testbed-automator/install.sh. Na Ubuntu 24.04 patrz CLAUDE.md sek. 3.2."
		( cd "${SRC_DIR}/testbed-automator" && ./install.sh ) || die "install.sh nie powiodło się."
	fi
	kubectl get nodes
	log "CNI / sieć:"
	ls -1 /etc/cni/net.d/ 2>/dev/null || true
	kubectl get pods -n kube-system 2>/dev/null | grep -Ei 'calico|cilium|flannel|multus' || true
}

stage_gtp5g() {
	section "gtp5g"
	git_sync "$FREE5GC_REPO" "${SRC_DIR}/free5gc-k8s"
	if lsmod | grep -q '^gtp5g'; then
		ok "gtp5g już załadowany."
		return
	fi
	local kernel; kernel="$(uname -r)"
	case "$kernel" in
		6.2*|6.[3-9]*|[7-9].*)
			warn "Jądro $kernel ≥ 6.2 — gtp5g v0.8.2 z planu B może się nie zbudować."
			warn "CLAUDE.md Faza 1C: zainstaluj nowszy gtp5g z github.com/free5gc/gtp5g i zweryfikuj z UPF v3.2.0, albo zgłoś człowiekowi." ;;
	esac
	if [ -x "${SRC_DIR}/free5gc-k8s/bin/install-gtp5g.sh" ]; then
		( cd "${SRC_DIR}/free5gc-k8s/bin" && ./install-gtp5g.sh ) || die "install-gtp5g.sh nie powiodło się."
	else
		die "Brak bin/install-gtp5g.sh w ${SRC_DIR}/free5gc-k8s."
	fi
	lsmod | grep '^gtp5g' || die "gtp5g nie załadował się po instalacji."
}

wait_running() {
	# Czekaj aż pody w namespace będą Running/Completed (maks. ~5 min).
	local tries=60
	while [ "$tries" -gt 0 ]; do
		local pending
		pending="$(kubectl get pods -n "$NS" --no-headers 2>/dev/null \
			| grep -Ev 'Running|Completed' | wc -l)"
		if [ "${pending:-1}" -eq 0 ] && kubectl get pods -n "$NS" --no-headers 2>/dev/null | grep -q .; then
			ok "Wszystkie pody w $NS gotowe."
			return 0
		fi
		log "Czekam na pody ($pending niegotowych)..."
		sleep 5
		tries=$((tries-1))
	done
	warn "Upłynął limit oczekiwania. Sprawdź: kubectl get pods -n $NS"
	kubectl get pods -n "$NS" -o wide
	return 1
}

stage_core() {
	section "RDZEŃ 5G (free5gc-k8s v3.2.0)"
	local base="${SRC_DIR}/free5gc-k8s"
	[ -d "$base" ] || die "Brak $base — uruchom najpierw etap gtp5g/clone."
	kubectl get ns "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
	# Kolejność wg README niloysh/free5gc-k8s.
	for k in mongodb networks5g free5gc free5gc-webui; do
		if [ -d "${base}/${k}" ]; then
			log "kubectl apply -k ${k}"
			kubectl apply -k "${base}/${k}" -n "$NS" || die "apply -k ${k} nie powiodło się."
		else
			warn "Brak katalogu ${base}/${k} — pomijam (sprawdź strukturę repo)."
		fi
		wait_running || warn "Kontynuuję mimo niegotowych podów."
	done
	kubectl get pods -n "$NS" -o wide
}

node_ip() {
	kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null
}

stage_subscriber() {
	section "ABONENT (API WebUI)"
	local ip; ip="$(node_ip)"
	[ -n "$ip" ] || die "Nie udało się ustalić IP węzła."
	local base="http://${ip}:${WEBUI_NODEPORT}"
	local ue_file="${SRC_DIR}/free5gc-k8s/ueransim/ueransim-ue/ue1/ue1.yaml"

	# IMSI/klucze bierzemy z pliku UE jeśli istnieje; inaczej domyślne v3.2.0.
	local imsi key opc
	if [ -f "$ue_file" ]; then
		imsi="$(grep -E '^\s*supi:' "$ue_file" | head -1 | sed -E 's/.*imsi-([0-9]+).*/\1/')"
		key="$(grep -E '^\s*key:' "$ue_file" | head -1 | awk '{print $2}' | tr -d '"'"'"'')"
		opc="$(grep -E '^\s*op:' "$ue_file" | head -1 | awk '{print $2}' | tr -d '"'"'"'')"
	fi
	imsi="${imsi:-208930000000003}"
	key="${key:-8baf473f2f8fd09487cccbd7097c6862}"
	opc="${opc:-8e27b6af0e692e750f32667a3b14605d}"

	log "Logowanie do WebUI API: $base"
	local token
	token="$(curl -s -X POST "${base}/api/login" \
		-H 'Content-Type: application/json' \
		-d "{\"username\":\"${WEBUI_USER}\",\"password\":\"${WEBUI_PASS}\"}" \
		| sed -E 's/.*"access_token"\s*:\s*"([^"]+)".*/\1/')"
	if [ -z "$token" ] || [ "$token" = "{" ]; then
		warn "Nie udało się pobrać tokenu WebUI. Dodaj abonenta ręcznie przez ${base} (${WEBUI_USER}/${WEBUI_PASS})."
		return 0
	fi

	# Idempotencja: jeśli abonent istnieje, nie twórz ponownie.
	if curl -s -H "Token: ${token}" "${base}/api/subscriber/imsi-${imsi}/20893" | grep -q "$imsi"; then
		ok "Abonent imsi-${imsi} już istnieje."
		return 0
	fi

	log "Dodaję abonenta imsi-${imsi} (klucze z ${ue_file:-domyślne})."
	# Minimalny profil zgodny z API WebUI free5GC v3.2.0.
	curl -s -X POST "${base}/api/subscriber/imsi-${imsi}/20893" \
		-H "Token: ${token}" -H 'Content-Type: application/json' \
		-d "$(subscriber_payload "$imsi" "$key" "$opc")" >/dev/null \
		&& ok "Abonent dodany." \
		|| warn "POST abonenta nie powiódł się — dodaj ręcznie w WebUI."
}

subscriber_payload() {
	local imsi="$1" key="$2" opc="$3"
	cat <<JSON
{"plmnID":"20893","ueId":"imsi-${imsi}","authenticationManagement":{"authenticationMethod":"5G_AKA","k":"${key}","opc":"${opc}","op":"","amf":"8000"},"accessAndMobilitySubscriptionData":{"nssai":{"defaultSingleNssais":[{"sst":1,"sd":"010203"}],"singleNssais":[{"sst":1,"sd":"010203"}]},"subscribedUeAmbr":{"downlink":"2 Gbps","uplink":"1 Gbps"}},"sessionManagementSubscriptionData":[{"singleNssai":{"sst":1,"sd":"010203"},"dnnConfigurations":{"internet":{"sscModes":{"defaultSscMode":"SSC_MODE_1","allowedSscModes":["SSC_MODE_2","SSC_MODE_3"]},"5gQosProfile":{"5qi":9,"arp":{"priorityLevel":8,"preemptCap":"","preemptVuln":""},"priorityLevel":8},"sessionAmbr":{"downlink":"1 Gbps","uplink":"1 Gbps"}}}}],"flowRules":[]}
JSON
}

stage_ran() {
	section "UERANSIM (gNB + UE)"
	local base="${SRC_DIR}/free5gc-k8s"
	if [ -d "${base}/ueransim/ueransim-gnb" ]; then
		kubectl apply -k "${base}/ueransim/ueransim-gnb" -n "$NS" || die "apply gNB nie powiodło się."
	else
		warn "Brak ueransim/ueransim-gnb — pomijam."
	fi
	# Poczekaj na NGAP w logach AMF przed UE.
	log "Czekam na NGAP (AMF)..."
	local amf tries=24
	amf="$(nf_pod amf)"
	while [ "$tries" -gt 0 ] && [ -n "$amf" ]; do
		if kubectl logs -n "$NS" "$amf" 2>/dev/null | grep -qi 'NGSetup\|NG-RAN\|gNB'; then
			ok "NGAP widoczny w logach AMF."
			break
		fi
		sleep 5; tries=$((tries-1))
	done
	if [ -d "${base}/ueransim/ueransim-ue" ]; then
		kubectl apply -k "${base}/ueransim/ueransim-ue" -n "$NS" || die "apply UE nie powiodło się."
	else
		warn "Brak ueransim/ueransim-ue — pomijam."
	fi
	wait_running || true
}

stage_verify() {
	section "WERYFIKACJA"
	kubectl get pods -n "$NS" -o wide
	local ue; ue="$(pod_by_selector 'nf=ue')"
	[ -n "$ue" ] || ue="$(kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '/ue/ {print $1; exit}')"
	if [ -n "$ue" ]; then
		log "Test E2E: ping z UE (wynik -> results/e2e-ping.txt)"
		mkdir -p "${REPO_ROOT}/results"
		# Nazwa interfejsu może się różnić; próbujemy uesimtun0.
		kubectl exec -n "$NS" "$ue" -- ping -I uesimtun0 -c 4 8.8.8.8 \
			2>&1 | tee "${REPO_ROOT}/results/e2e-ping.txt" \
			|| warn "Ping nie przeszedł — patrz CLAUDE.md sek. 3.1 (NAT hypervisora); test E2E może być wewnątrz klastra."
	else
		warn "Nie znaleziono poda UE."
	fi
	warn "Faza 1 gotowa — PRZYPOMNIENIE dla człowieka: zrób snapshot VM przed Fazą 3."
	warn "  multipass stop free5gc && multipass snapshot free5gc --name faza1-ok"
}

main() {
	need_kubectl
	mkdir -p "$SRC_DIR"
	local stage="${1:-all}"
	case "$stage" in
		-h|--help) usage; exit 0 ;;
		cluster)    stage_cluster ;;
		gtp5g)      stage_gtp5g ;;
		core)       stage_core ;;
		subscriber) stage_subscriber ;;
		ran)        stage_ran ;;
		verify)     stage_verify ;;
		all)
			stage_cluster
			stage_gtp5g
			stage_core
			stage_subscriber
			stage_ran
			stage_verify ;;
		*) usage; die "Nieznany etap: $stage" ;;
	esac
}

main "$@"
