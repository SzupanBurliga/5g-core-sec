# setup-notes — co zadziałało, wersje, problemy

Notatki techniczne dla drugiej osoby i następnej sesji. Kto skończy pierwszy,
dopisuje, co zadziałało, żeby druga osoba poszła szybciej.

## Wersje (uzupełnij po Fazie 0–1)

| Element | Wartość | Skąd |
| --- | --- | --- |
| OS VM | _(np. Ubuntu 22.04)_ | `lsb_release -a` |
| Jądro | _(np. 5.15.x)_ | `uname -r` |
| CNI podstawowe | _(Calico? Cilium? Flannel?)_ | `ls /etc/cni/net.d/`, `kubectl get pods -n kube-system` |
| free5GC | v3.2.0 | niloysh/free5gc-k8s README |
| gtp5g | _(np. v0.8.2)_ | `bin/install-gtp5g.sh`, `lsmod` |
| Kubernetes | _(wersja z testbed-automator)_ | `kubectl version` |
| UERANSIM | _(tag z repo)_ | manifesty ueransim |

## Decyzje projektowe (kod)

- **Wariant rdzenia:** plan B — niloysh/free5gc-k8s (free5GC v3.2.0), nie Helm 1B.
  Scenariusze i hardening są identyczne dla obu (testujemy warstwę k8s).
- **Etykiety/porty w skryptach i manifestach** wzięte z opisu manifestów niloysh:
  namespace `free5gc`; `app=free5gc`, `nf=amf|smf|upf|nrf|ausf|udm|udr|nssf|pcf`;
  SBI `8000`; MongoDB `27017`; WebUI NodePort `30505`. Zmienne w `scripts/lib.sh`
  (`NS`, `NF_LIST`, `SBI_PORT`, …) — jeśli realne nazwy się różnią, popraw tam.
- **Do zweryfikowania przy pierwszym uruchomieniu** (`kubectl get svc,secret -n free5gc`):
  - nazwa usługi MongoDB i etykieta (`app=mongodb`) w 02/06,
  - realna nazwa sekretu MongoDB w `06-secrets.yaml` (`resourceNames`),
  - czy usługi NF nazywają się dokładnie jak wartość `nf` (fallback na podIP jest w kodzie).

## Znane punkty uwagi

- **CNI a NetworkPolicy:** jeśli podstawowe CNI to Flannel, NetworkPolicy nie jest
  egzekwowana → S3 "po" nie pokaże różnicy. Sprawdź w Fazie 1 i zgłoś człowiekowi.
- **Multus (N2/N3/N4):** NetworkPolicy nie obejmuje interfejsów macvlan/Multus.
  Opisane jako ograniczenie w S3 i `results/summary.md`. Nie obchodzimy go.
- **Jądro ≥ 6.2 a gtp5g v0.8.2:** nie zbuduje się. Wtedy nowszy gtp5g z
  github.com/free5gc/gtp5g i weryfikacja z UPF v3.2.0, albo zgłoszenie człowiekowi.
- **Secure Boot:** jeśli włączony, niepodpisany gtp5g zostanie odrzucony → człowiek.

## Trade-offy hardeningu (uzupełnij w Fazie 4)

- **UPF a PodSecurity restricted:** UPF wymaga NET_ADMIN/gtp5g; namespace trzyma
  `enforce=baseline`. Jeśli reszta rdzenia ma iść na `restricted`, przenieś UPF
  do osobnego namespace. _(opisz tu, co faktycznie zrobiłeś)_
- **Reguła, którą trzeba było poluzować:** _(jeśli harden.sh zatrzymał się na
  którymś kroku — który plik, co zmieniłeś, dlaczego)_

## Łatki testbed-automator (jeśli Ubuntu 24.04)

Skopiuj repo do `~/src/testbed-automator`, zmiany rób tam, opisz każdą tutaj:
co się wysypało, co zmieniłeś, dlaczego (PEP 668 / klucze apt signed-by /
containerd SystemdCgroup / moduły jądra / wersja k8s w pkgs.k8s.io).

- _(brak wpisów — uzupełnij po stawianiu)_
