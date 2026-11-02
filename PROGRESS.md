# PROGRESS — dziennik postępu

Odhaczaj zadania, dopisuj datę, wynik i problemy. Cel: następna sesja / druga
osoba podejmuje pracę bez pytania. Każda osoba ma własną VM — stan klastra się
nie współdzieli, współdzielone jest tylko to repo.

Format wpisu: `- [x] <zadanie> — RRRR-MM-DD — wynik / problem`

---

## Stan kodu repozytorium

- [x] Szkielet repo (scripts/, manifests/, results/, docs/) — 2026-11-02
- [x] scripts/lib.sh, preflight.sh, setup.sh, baseline.sh — 2026-11-02
- [x] scripts/scenarios/s1..s6 — 2026-11-02
- [x] manifests/hardening/01..06 + scripts/harden.sh — 2026-11-02
- [x] scripts/run.sh, summary.sh — 2026-11-02
- [x] shellcheck + walidacja YAML — 2026-11-02

## Faza 0 — Preflight
- [ ] `scripts/preflight.sh` uruchomiony w VM → `results/preflight.txt`
- [ ] Ocena względem CLAUDE.md sek. 3 (WSL? RAM? SecureBoot? SCTP?)
- [ ] Wersja OS/jądra zapisana w `docs/setup-notes.md`

## Faza 1 — Klaster + rdzeń 5G
- [ ] testbed-automator: `kubectl get nodes` Ready, pody Running
- [ ] CNI ustalone i zapisane; test egzekwowania NetworkPolicy
- [ ] gtp5g załadowany (`lsmod | grep gtp5g`)
- [ ] free5GC v3.2.0 (mongodb, networks5g, free5gc, webui) — pody Running
- [ ] Abonent dodany (API WebUI / `setup.sh subscriber`)
- [ ] UERANSIM gNB (NGAP w logach AMF) + UE
- [ ] Test E2E ping → `results/e2e-ping.txt`
- [ ] **Przypomnienie: snapshot VM przed Fazą 3**

## Faza 2 — Baseline (przed)
- [ ] `scripts/run.sh before` (lub sam `baseline.sh results/before`)

## Faza 3 — Scenariusze (przed)
- [ ] S1 eskalacja / S2 token SA / S3 sieć / S4 secrets / S5 Trivy
- [ ] S6 wyczerpanie zasobów — **po zgodzie człowieka** (`--yes-s6`)

## Faza 4 — Hardening + pomiar po
- [ ] `scripts/harden.sh` (01→06, ping-check po każdym kroku)
- [ ] Trade-offy zapisane w `docs/setup-notes.md` (UPF, Multus)
- [ ] `scripts/run.sh after`

## Faza 5 — Wyniki
- [ ] `scripts/summary.sh` → `results/summary.md`
- [ ] Skrypty demo + komendy asciinema

---

## Notatki / problemy

- 2026-11-02: Kod napisany na podstawie CLAUDE.md. `setup.sh` NIE uruchamiany —
  czeka na przegląd człowieka. Etykiety/porty wzięte z opisu manifestów niloysh
  (ns free5gc; nf=amf|smf|upf|nrf|ausf|udm|udr|nssf|pcf; SBI 8000; mongo 27017;
  WebUI 30505). Przy pierwszym uruchomieniu zweryfikuj realne nazwy usług/secretów
  (`kubectl get svc,secret -n free5gc`) i w razie potrzeby popraw selektory w
  manifestach hardeningu (zwłaszcza `app=mongodb`, nazwa sekretu w 06).
