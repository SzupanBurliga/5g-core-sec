# Projekt: Bezpieczeństwo CNF w 5G Core (free5GC na Kubernetes)

Ten plik to instrukcja dla Claude Code. Leży w katalogu głównym wspólnego repozytorium projektu.
Claude Code: przeczytaj go w całości przed pierwszą komendą i pracuj fazami w podanej kolejności.

## 1. Kontekst

Projekt zaliczeniowy (AGH, 2 osoby, prezentacja ok. 20 min). Temat: bezpieczeństwo Cloud-Native Network Functions (CNF)
rdzenia 5G na Kubernetesie: izolacja kontenerów, bezpieczeństwo hosta i orkiestracji, RBAC, service accounts, secrets,
NetworkPolicy, łańcuch dostaw oraz wpływ przejęcia jednej CNF na resztę rdzenia.

**Teza projektu:** domyślne wdrożenie free5GC na k8s jest słabo izolowane, a kilka standardowych mechanizmów k8s
(NetworkPolicy, RBAC, Pod Security, limity zasobów) zamyka większość dróg ataku. Dowodem jest pomiar **przed/po**
na tych samych testach.

**Pytania ze slajdu, na które odpowiadamy:**
1. Które uprawnienia umożliwiają eskalację w klastrze? → scenariusze S1, S2
2. Jak ograniczyć dostęp między CNF? → S3
3. Jak wyczerpanie zasobów wpływa na dostępność 5GC? → S6

**Model napastnika:** napastnik przejął jeden pod CNF (np. przez lukę w aplikacji). Symulujemy to przez `kubectl exec`
do poda. Nie atakujemy niczego z zewnątrz.

## 2. Zasady pracy dla Claude Code

- **Tylko ten klaster.** Wszystkie testy i ataki wyłącznie wobec lokalnego klastra na tej VM. Nigdy nie kieruj ruchu,
  skanów ani obciążenia na zewnętrzne adresy (wyjątek: ping UE do 8.8.8.8 jako test łączności).
- **Każda osoba ma własną VM.** Wspólne jest tylko to repozytorium (manifesty, skrypty, wyniki). Nie zakładaj, że
  druga osoba ma ten sam stan klastra.
- **Postęp zapisuj w `PROGRESS.md`:** po każdym kroku odhacz zadanie, dopisz datę, wynik i problemy. Ta osoba lub
  następna sesja ma móc podjąć pracę bez pytania.
- **Wszystko, co zmienia klaster, trzymaj jako plik w repo** (`manifests/`, `scripts/`). Żadnych jednorazowych
  poprawek wpisanych tylko w terminalu, których nie da się odtworzyć.
- **Wyniki zapisuj do plików** w `results/` (surowy output komend), nie tylko do konsoli.
- **Nie zgaduj wersji ani nazw parametrów.** Przed użyciem chartu Helm przeczytaj jego `Chart.yaml`, `values.yaml`
  i README. Przed instalacją gtp5g sprawdź, którą wersję wymaga wybrana wersja free5GC.
- **Zatrzymaj się i zapytaj człowieka**, gdy:
  - trzeba zmienić kernel, zrestartować VM albo odinstalować klaster,
  - limit czasu z Fazy 1B minął i trzeba zdecydować o planie B,
  - test w Fazie 3 może trwale zepsuć działający rdzeń (np. obciążenie bez limitów na całym węźle),
  - coś w tym pliku jest sprzeczne z tym, co widzisz w systemie.
- **Snapshot / checkpoint:** po udanej Fazie 1 przypomnij człowiekowi o snapshocie VM, zanim zaczniesz Fazę 3.

## 3. Środowisko docelowe

| Zasób | Wymaganie |
| --- | --- |
| Środowisko | **Lokalna VM w Multipass** na laptopie (host: Linux, Windows lub macOS), definiowana przez `vm/cloud-init.yaml` |
| OS w VM | **Ubuntu 22.04 LTS** (obraz Multipass `22.04`) |
| CPU | 4 vCPU |
| RAM | 12 GB dla VM (min. 8 GB; host powinien mieć ≥ 16 GB) |
| Dysk | 60 GB |
| Uprawnienia | użytkownik `ubuntu` z sudo (domyślny w Multipass), nie root |
| Klaster | single-node (bez worker nodes i tuneli VXLAN) |

Claude Code działa **wewnątrz VM** (`multipass shell free5gc`). Nie uruchamiaj klastra bezpośrednio na hoście ani
w WSL: gtp5g to moduł jądra i musi być ładowany do jądra VM, a nie laptopa.

### 3.1 Specyfika lokalnej VM (Multipass)

- VM stawia człowiek według `vm/README.md`. `cloud-init.yaml` instaluje paczki bazowe, nagłówki jądra,
  `linux-modules-extra`, ładuje SCTP i instaluje Node.js. Sprawdź `cloud-init status` → ma być `done`.
- **Jądro:** obraz 22.04 ma zwykle jądro z serii 5.15. Nie zmieniaj jądra. Dobierz wersję gtp5g zgodną z jądrem
  i wybraną wersją free5GC.
- **Secure Boot:** sprawdź `mokutil --sb-state`. Jeśli włączony, jądro może odrzucić niepodpisany moduł gtp5g → zgłoś
  człowiekowi.
- **SCTP** (NGAP gNB ↔ AMF): `sudo modprobe sctp`. Jeśli błąd → `sudo apt install linux-modules-extra-$(uname -r)`.
- **Sieć:** VM jest za NAT-em hypervisora (Hyper-V na Windowsie domyślnie blokuje podszywanie się pod MAC). Interfejsy
  N2/N3/N4/N6 podpinaj do lokalnego mostka (np. OVS od testbed-automatora) albo interfejsu dummy, a nie do `eth0`.
  Wyjście UE do internetu przez NAT na węźle. Jeśli to zbyt kłopotliwe, test E2E = ping z UE do adresu wewnątrz
  klastra / UPF N6. Dla scenariuszy bezpieczeństwa to bez znaczenia.
- **WebUI (NodePort 30505)** jest osiągalne z hosta pod IP VM (`multipass info free5gc`). Nie wystawiaj go dalej.
- **Snapshoty** robi człowiek na hoście: `multipass stop free5gc && multipass snapshot free5gc --name <nazwa>`,
  przywrócenie: `multipass restore free5gc.<nazwa>`. Claude Code tylko przypomina o snapshocie.
- Claude Code nie wyłącza ani nie usuwa VM.

### 3.2 Jeśli VM ma jednak Ubuntu 24.04

testbed-automator jest testowany na 22.04. Na 24.04 spodziewaj się poprawek. Dozwolone jest łatanie jego skryptów:
skopiuj repo do `~/src/testbed-automator`, zmiany rób tam, a każdą zmianę opisz w `docs/setup-notes.md`
(co się wysypało, co zmieniłeś, dlaczego). Typowe miejsca:
- `pip install` poza venv kończy się błędem `externally-managed-environment` (PEP 668) → paczka z apt
  (`python3-<nazwa>`) albo venv, nie `--break-system-packages` globalnie bez potrzeby.
- Klucze i źródła repozytoriów apt (Kubernetes, Docker/containerd): nowy format `signed-by` w `/etc/apt/keyrings`.
- Konfiguracja containerd (`SystemdCgroup = true`) i moduły jądra (`br_netfilter`, `overlay`, `openvswitch`).
- Wersja Kubernetesa przypięta w skrypcie musi mieć działające repo pakietów (`pkgs.k8s.io`).

Jeśli łatanie testbed-automatora zajmie więcej niż jeden wieczór → zatrzymaj się i zaproponuj człowiekowi
alternatywę: postawienie klastra ręcznie (kubeadm + Calico/Cilium + Multus + OVS-CNI) według oficjalnych dokumentacji.

## 4. Struktura repozytorium

Utwórz, jeśli nie istnieje:

```
.
├── CLAUDE.md              # ten plik
├── PROGRESS.md            # dziennik postępu (aktualizowany przez Claude Code)
├── vm/
│   ├── cloud-init.yaml    # definicja VM (Multipass)
│   └── README.md          # jak postawić VM na hoście (dla ludzi)
├── manifests/
│   ├── baseline/          # ewentualne pomocnicze obiekty do testów (np. pod napastnika)
│   └── hardening/         # NetworkPolicy, RBAC, PodSecurity, ResourceQuota, LimitRange
├── scripts/
│   ├── preflight.sh       # Faza 0
│   ├── baseline.sh        # Faza 2 (ten sam skrypt w Fazie 4 do pomiaru "po")
│   └── scenarios/         # s1_*.sh ... s6_*.sh
├── results/
│   ├── before/            # outputy z Fazy 2 i 3
│   ├── after/             # outputy z Fazy 4
│   └── summary.md         # tabela przed/po
└── docs/
    └── setup-notes.md     # co zadziałało przy stawianiu, wersje, problemy
```

## 5. Fazy

### Faza 0 — Preflight

- [ ] Napisz i uruchom `scripts/preflight.sh`: `lsb_release -a`, `uname -r`, `nproc`, `free -h`, `df -h /`,
      czy jest `git`, `curl`, `helm`, `kubectl`, `mokutil --sb-state`, `sudo modprobe sctp && lsmod | grep sctp`,
      `sudo modprobe openvswitch`, oraz czy to nie WSL (`uname -r` nie może zawierać `microsoft`).
      Zapisz do `results/preflight.txt`.
- [ ] Oceń wynik względem sekcji 3. Zatrzymaj się i zgłoś człowiekowi, jeśli: to WSL, RAM < 8 GB,
      Secure Boot włączony, SCTP nie daje się załadować nawet po `linux-modules-extra-$(uname -r)`.
- [ ] Zanotuj wersję OS i jądra w `docs/setup-notes.md`. Mają znaczenie przy testbed-automatorze (3.2) i gtp5g.

### Faza 1A — Klaster Kubernetes

- [ ] `git clone https://github.com/niloysh/testbed-automator.git` (poza tym repo, np. w `~/src/`).
- [ ] Przeczytaj jego README i `troubleshooting.md`, potem uruchom `./install.sh` jako zwykły użytkownik.
      Na Ubuntu 24.04 spodziewaj się błędów: postępuj według sekcji 3.2 (łatanie skryptu + notatki).
- [ ] Sprawdź: `kubectl get nodes` (Ready), `kubectl get pods -A` (wszystko Running).
- [ ] **Ustal, jakie CNI jest podstawowe** (`kubectl get pods -n kube-system`, `ls /etc/cni/net.d/`).
      Zapisz w `docs/setup-notes.md`. To krytyczne dla S3: NetworkPolicy działa tylko z CNI, które ją egzekwuje
      (Calico, Cilium tak; Flannel nie). Jeśli CNI jej nie egzekwuje → zgłoś człowiekowi.
- [ ] Szybki test egzekwowania NetworkPolicy: dwa testowe pody w namespace `np-test`, `curl` przechodzi →
      nałóż default-deny → `curl` nie przechodzi → usuń namespace. Wynik do `results/np-enforcement-check.txt`.

### Faza 1B — Rdzeń 5G: wariant główny (free5gc-helm, nowsza wersja)

Limit czasu: **ok. 3 wieczory pracy**. Jeśli po tym UE nie robi pinga przez rdzeń → Faza 1C.

- [ ] `git clone https://github.com/free5gc/free5gc-helm.git` (w `~/src/`).
- [ ] Przeczytaj README, `charts/free5gc/Chart.yaml` (pole `appVersion`) i `values.yaml`. Zapisz w
      `docs/setup-notes.md` dokładną wersję free5GC i tagi obrazów.
- [ ] Przeczytaj oficjalną dokumentację wdrożenia Helm na stronie free5gc.org (Guide → free5gc-helm) i wymagania:
      kernel, wersja gtp5g, Multus, wolumen dla MongoDB.
- [ ] Zainstaluj moduł jądra **gtp5g w wersji pasującej do wybranej wersji free5GC** (z
      `https://github.com/free5gc/gtp5g`, tag zgodny z dokumentacją/release notes). Sprawdź `lsmod | grep gtp5g`.
- [ ] Ustaw wartości sieciowe chartu (interfejsy master dla N2/N3/N4/N6 itp.) pod interfejs tej VM
      (`ip -br a`). Zapisz własne nadpisania w `manifests/free5gc-values.yaml`, nie w `--set` w terminalu.
- [ ] Jeśli chart wymaga PersistentVolume dla MongoDB, a klaster nie ma StorageClass → utwórz lokalny PV
      (`manifests/baseline/mongodb-pv.yaml`).
- [ ] `kubectl create namespace free5gc` i `helm install` rdzenia z `manifests/free5gc-values.yaml`.
- [ ] Wszystkie pody Running. Dodaj abonenta (WebUI albo zgodnie z dokumentacją chartu).
- [ ] Wdróż symulator RAN (UERANSIM albo free-ran-ue, cokolwiek chart wspiera). gNB: połączenie NGAP w logach.
- [ ] **Test końcowy:** z poda UE `ping -I uesimtun0 8.8.8.8` (nazwa interfejsu może się różnić). Zapisz do
      `results/e2e-ping.txt`.
- [ ] Zaktualizuj `PROGRESS.md` i przypomnij człowiekowi o snapshocie VM.

### Faza 1C — Rdzeń 5G: plan B (niloysh/free5gc-k8s, free5GC v3.2.0)

Tylko jeśli 1B się nie udała w limicie czasu i człowiek to potwierdził. Najpierw odinstaluj release Helm z 1B.

- [ ] `git clone https://github.com/niloysh/free5gc-k8s.git` (w `~/src/`). Przeczytaj README.
- [ ] Uwaga: ten wariant instaluje gtp5g v0.8.2 i jest testowany na kernelu 5.4 / 5.15. Przy jądrze 5.15 (domyślne
      w VM 22.04) powinno działać. Jeśli `uname -r` pokazuje 6.2 lub nowsze, gtp5g v0.8.2 się nie zbuduje: zainstaluj
      nowszy gtp5g z `https://github.com/free5gc/gtp5g` i sprawdź, czy UPF v3.2.0 z nim współpracuje. Jeśli nie → zgłoś.
- [ ] `cd bin && ./install-gtp5g.sh`
- [ ] Kolejno, czekając na Running po każdym kroku:
      ```
      kubectl create namespace free5gc
      kubectl apply -k mongodb -n free5gc
      kubectl apply -k networks5g -n free5gc
      kubectl apply -k free5gc -n free5gc
      kubectl apply -k free5gc-webui -n free5gc
      ```
- [ ] WebUI `http://<node-ip>:30505` (admin / free5gc), abonent wg `ueransim/ueransim-ue/ue1/ue1.yaml`.
- [ ] `kubectl apply -k ueransim/ueransim-gnb -n free5gc`, czekaj na NGAP, potem `ueransim/ueransim-ue`.
- [ ] Test pinga z UE jak w 1B, zapis do `results/e2e-ping.txt`.

**Scenariusze w Fazach 2–4 są takie same dla 1B i 1C.** Testujemy warstwę Kubernetesa, nie kod rdzenia.

### Faza 2 — Baseline (stan PRZED zmianą polityk)

Napisz `scripts/baseline.sh` z parametrem katalogu wyjściowego (`results/before` lub `results/after`).
Skrypt ma być idempotentny i niczego nie zmieniać w klastrze. Mierzy:

- [ ] **Inwentarz:** `kubectl get pods,svc,sa,secrets,networkpolicy,resourcequota,limitrange -n free5gc -o wide`.
- [ ] **Sieć wschód-zachód:** z poda AMF próby połączeń TCP do usług innych CNF (NRF, SMF, UDM, AUSF…) i do MongoDB
      (27017). Użyj narzędzi dostępnych w obrazie (`curl`, `nc`, `bash /dev/tcp`); jeśli brak, użyj efemerycznego
      kontenera debug (`kubectl debug`) w tym samym podzie. Wynik jako macierz źródło → cel → OK/BLOCKED.
- [ ] **RBAC:** dla każdego SA w namespace `kubectl auth can-i --list --as=system:serviceaccount:free5gc:<sa>`.
      Czy w podach jest zamontowany token (`/var/run/secrets/kubernetes.io/serviceaccount/`).
- [ ] **Secrets / konfiguracja:** zmienne środowiskowe podów (`env`) filtrowane po `pass|secret|key|mongo|token`,
      lista secretów i configmap. W raporcie maskuj wartości, pokazuj tylko, że są widoczne.
- [ ] **securityContext:** dla każdego kontenera: privileged, runAsUser/runAsNonRoot, allowPrivilegeEscalation,
      capabilities, hostNetwork, hostPath. Oznacz UPF osobno (zwykle potrzebuje uprawnień do gtp5g).
- [ ] **Zasoby:** requests/limits każdego kontenera.

### Faza 3 — Scenariusze (atak w stanie domyślnym)

Każdy scenariusz to osobny skrypt `scripts/scenarios/sN_<nazwa>.sh` z trybem `--out <katalog>`.
Każdy zapisuje: co próbowano, komendę, output, werdykt (`POSSIBLE` / `BLOCKED`).
Te same skrypty uruchomisz w Fazie 4 bez zmian.

- [ ] **S1 — Eskalacja z przejętego poda.** Z wnętrza wybranych podów (AMF + UPF): `id`, czy root, capabilities
      (`/proc/self/status` CapEff), czy widać pliki hosta / gniazda runtime, czy privileged pozwala np. na `mount`.
      Nie wykonuj faktycznej ucieczki niszczącej hosta. Wystarczy wykazać, że warunki do niej istnieją.
- [ ] **S2 — Nadużycie tokenu service accountu.** Z poda użyj zamontowanego tokenu do zapytań do API
      (`curl` do `https://kubernetes.default.svc` z tokenem i CA): list pods, get secrets, create pod.
      Zapisz kody HTTP (200/403).
- [ ] **S3 — Ruch między CNF.** Macierz połączeń z Fazy 2 jako test aktywny: które CNF mogą się łączyć z którymi,
      w tym z MongoDB. Udokumentuj, że ruch na interfejsach Multus (N2/N3/N4) może nie podlegać NetworkPolicy:
      sprawdź to i opisz jako ograniczenie, nie próbuj obchodzić.
- [ ] **S4 — Odczyt secrets.** Z przejętego poda: wartości w `env`, pliki konfiguracyjne free5GC (hasło/URI
      MongoDB), oraz (jeśli S2 pozwala) `get secret` przez API i dekodowanie base64. W wynikach maskuj sekrety.
- [ ] **S5 — Łańcuch dostaw (opcjonalnie).** Zainstaluj Trivy, przeskanuj obrazy z `kubectl get pods -o jsonpath`
      (`trivy image --severity HIGH,CRITICAL`). Policz CVE per obraz. Jeśli używacie 1B: przeskanuj też obraz
      starej wersji (np. tag v3.2.0) dla porównania, bez wdrażania go.
- [ ] **S6 — Wyczerpanie zasobów.** **Najpierw zapytaj człowieka.** W jednym podzie CNF (nie UPF) uruchom
      obciążenie CPU/RAM (`stress-ng`, ewentualnie w kontenerze debug) z ograniczonym czasem (`--timeout 120s`).
      Równolegle mierz: ping UE (straty/opóźnienia), restarty i OOMKilled innych podów, `kubectl top` (jeśli jest
      metrics-server). Zapisz przebieg czasowy do pliku.

### Faza 4 — Hardening i pomiar PO

Manifesty w `manifests/hardening/`, każdy obszar osobnym plikiem, aplikowane po kolei. Po każdym kroku sprawdź,
czy UE nadal robi pinga. Jeśli hardening psuje rdzeń, poluzuj regułę i opisz kompromis w `docs/setup-notes.md`.

- [ ] `01-networkpolicy-default-deny.yaml` + `02-networkpolicy-allow.yaml`: default-deny ingress (i egress, jeśli
      się da) w `free5gc`, potem allow tylko dla potrzebnych par (wszystkie NF ↔ NRF, AMF ↔ AUSF/UDM/SMF,
      SMF ↔ UPF/UDM/PCF, UDR ↔ MongoDB, DNS do kube-dns). Pary ustal z konfiguracji free5GC, nie zgaduj.
- [ ] `03-rbac.yaml`: osobny ServiceAccount per CNF, `automountServiceAccountToken: false` tam, gdzie pod nie woła
      API k8s, minimalne Role/RoleBinding. Podepnij SA w wartościach chartu (1B) lub manifestach (1C).
- [ ] `04-pod-security.yaml`: etykiety Pod Security Admission na namespace (`enforce: baseline` lub `restricted`,
      `warn: restricted`). `securityContext`: `runAsNonRoot`, `allowPrivilegeEscalation: false`,
      `capabilities.drop: [ALL]`, `readOnlyRootFilesystem` gdzie się da. UPF prawdopodobnie wymaga wyjątku:
      osobny namespace albo mniej restrykcyjny poziom, udokumentuj to jako trade-off.
- [ ] `05-resources.yaml`: requests/limits dla wszystkich kontenerów + `ResourceQuota` i `LimitRange` na namespace.
- [ ] `06-secrets.yaml`: sekrety montowane jako pliki (nie env), RBAC ograniczający `get secrets` do właściwego SA.
- [ ] Uruchom `scripts/baseline.sh results/after` i wszystkie `scripts/scenarios/*.sh --out results/after`.

### Faza 5 — Wyniki i materiały do prezentacji

- [ ] `results/summary.md`: tabela

      | Scenariusz | Przed | Po | Mechanizm | Plik z dowodem |
      | --- | --- | --- | --- | --- |

      plus macierz połączeń S3 przed/po i krótka lista ograniczeń (NetworkPolicy a Multus, wyjątek dla UPF).
- [ ] `scripts/demo/`: krótkie skrypty do prezentacji (S3, S4, S6), każdy pokazuje „przed” i „po” w < 1 min,
      z czytelnymi nagłówkami w outputcie. Tryb `--dry` wyświetla komendy bez wykonywania.
- [ ] Przygotuj komendy do nagrania demo przez asciinema (`asciinema rec results/demo-sN.cast`).
      Samo nagrywanie i slajdy robią ludzie.

## 6. Podział pracy (dla ludzi)

| Tydzień | Osoba A (sieć + infra) | Osoba B (tożsamość + zasoby) |
| --- | --- | --- |
| 1 | Faza 0–1 na swojej VM, setup-notes | Faza 0–1 na swojej VM, test pinga UE |
| 2 | Faza 2 sieć, S3 | Faza 2 RBAC/secrets/zasoby, S1, S2, S4 |
| 3 | Hardening 01–02, S6 wspólnie | Hardening 03–06, S5 |
| 4 | Slajdy 1–4, demo sieci | Slajdy 5–7, demo RBAC/zasobów |

Obie osoby stawiają środowisko u siebie z tego samego repo. Kto skończy pierwszy, dopisuje do `docs/setup-notes.md`,
co zadziałało, żeby druga osoba poszła szybciej.

## 7. Znane problemy

| Problem | Objaw | Co zrobić |
| --- | --- | --- |
| Niezgodność kernel ↔ gtp5g | UPF CrashLoop, błędy gtp5g w logach | Wersja gtp5g zgodna z wersją free5GC; stara v0.8.2 (plan B) nie wspiera kernela ≥ 6.2 |
| Za mało RAM | OOMKilled, Pending | 8 GB dla VM |
| MongoDB Pending | brak PV / StorageClass | lokalny PV (Faza 1B) |
| Brak NGAP gNB ↔ AMF | gNB nie łączy się | sieci Multus i interfejsy w values; kolejność wdrażania |
| NetworkPolicy nic nie blokuje | `curl` przechodzi po default-deny | CNI nie egzekwuje polityk (Faza 1A) |
| Ruch N2/N3/N4 omija politykę | przechodzi mimo NetworkPolicy | interfejsy Multus; opisać jako ograniczenie |
| `modprobe gtp5g`: Key was rejected | moduł nie ładuje się | Secure Boot włączony w VM → zgłoś człowiekowi |
| `modprobe sctp` nie działa | gNB nie łączy NGAP | `sudo apt install linux-modules-extra-$(uname -r)` |
| UE nie ma internetu, rdzeń OK | ping 8.8.8.8 nie przechodzi | macvlan na `eth0` za NAT-em hypervisora (3.1); test E2E wewnątrz klastra |
| Pody OOMKilled / VM muli | za mało RAM dla VM | człowiek: `multipass stop` + `multipass set local.free5gc.memory=14G` |
| install.sh pada na 24.04 | błędy pip/apt/containerd | sekcja 3.2 |

## 8. Źródła

- https://github.com/niloysh/testbed-automator
- https://github.com/free5gc/free5gc-helm
- https://github.com/niloysh/free5gc-k8s (plan B)
- https://github.com/free5gc/gtp5g
- https://free5gc.org (dokumentacja, release notes)
- https://github.com/Spartan-F117/VAPT_CoreNetwork5G (inspiracja: SBI, DDoS)
- NIST SP 800-190, ETSI GS NFV-SEC 023, Kubernetes docs: RBAC, Pod Security Standards, NetworkPolicy