#!/bin/bash
# Faza 1: attach LTE end-to-end peste ZeroMQ, pe macOS ARM64.
#
# Ruleaza cu sudo. Root e necesar din trei motive:
#   - srsepc si srsue creeaza fiecare cate o interfata utun
#   - aliasurile de loopback 127.0.1.100 si 127.0.1.1 nu exista implicit pe
#     macOS, spre deosebire de Linux unde tot 127.0.0.0/8 e legat de lo
#
# Fiecare componenta primeste propriul port de incapsulare SCTP. Doua procese
# pe aceeasi masina nu pot lega acelasi port, iar libsctp-compat refuza
# explicit conflictul in loc sa porneasca fara transport.

set -u

# Override with SRSRAN_PREFIX if the lab lives elsewhere.
LAB="${SRSRAN_PREFIX:-$HOME/sdr-lab}"
ETC="$LAB/etc/srsran"
LOGS="$LAB/logs"
BIN="$LAB/local/bin"
SESSION="faza1"

if [ "$(id -u)" != "0" ]; then
  echo "Ruleaza cu sudo: sudo $0"
  exit 1
fi

command -v tmux >/dev/null || { echo "tmux lipseste: brew install tmux"; exit 1; }

# --- aliasuri de loopback, idempotent ---------------------------------------
for addr in 127.0.1.100 127.0.1.1; do
  if ifconfig lo0 | grep -q "inet $addr "; then
    echo "[setup] $addr exista deja pe lo0"
  else
    ifconfig lo0 alias "$addr" up && echo "[setup] adaugat $addr pe lo0"
  fi
done

mkdir -p "$LOGS" "$LAB/var"
rm -f "$LOGS"/faza1-epc.log "$LOGS"/faza1-enb.log "$LOGS"/faza1-ue.log \
      "$LOGS"/faza1-epc-console.log "$LOGS"/faza1-enb-console.log "$LOGS"/faza1-ue-console.log

# Asteapta un tipar intr-un log, cu limita de timp. Intoarce 1 la expirare.
wait_for() {
  local file="$1" pattern="$2" timeout="$3" label="$4"
  local i=0
  echo "[astept] $label"
  while [ $i -lt "$timeout" ]; do
    if [ -f "$file" ] && grep -qi -- "$pattern" "$file" 2>/dev/null; then
      echo "[ok]     $label"
      return 0
    fi
    sleep 1
    i=$((i + 1))
  done
  echo "[esec]   $label nu a aparut in ${timeout}s"
  echo "         ultimele linii din $(basename "$file"):"
  tail -15 "$file" 2>/dev/null | sed 's/^/         /'
  return 1
}

tmux kill-session -t "$SESSION" 2>/dev/null

# Killing a tmux session does not reach processes that outlived an earlier one.
# Leftovers keep the encapsulation and ZeroMQ ports, and the failure that
# follows looks like a networking problem rather than a stale process.
for proc in srsue srsenb srsepc; do
  if pgrep -x "$proc" >/dev/null 2>&1; then
    echo "[curat] opresc $proc ramas din rularea anterioara"
    pkill -x "$proc"
  fi
done

# An srsRAN process that hit a fatal error, a radio that would not open for
# instance, does not always finish its own shutdown and then ignores SIGTERM.
# Give the polite signal a second, then insist.
sleep 1
for proc in srsue srsenb srsepc; do
  if pgrep -x "$proc" >/dev/null 2>&1; then
    echo "[curat] $proc nu a raspuns la SIGTERM, trimit SIGKILL"
    pkill -9 -x "$proc"
  fi
done

# Give the kernel a moment to release the ports, then say plainly if something
# still holds one instead of starting into a confusing failure.
sleep 1
busy=""
for port in 9899 9900 36412 2152; do
  lsof -nP -iUDP:"$port" -iTCP:"$port" >/dev/null 2>&1 && busy="$busy $port"
done
for port in 2000 2101; do
  lsof -nP -iTCP:"$port" >/dev/null 2>&1 && busy="$busy $port"
done
if [ -n "$busy" ]; then
  echo "[eroare] porturi inca ocupate:$busy"
  echo "         cine le tine:"
  for port in $busy; do lsof -nP -iUDP:"$port" -iTCP:"$port" 2>/dev/null | tail -n +2 | sed 's/^/         /'; done
  exit 1
fi

# --- 1. EPC ------------------------------------------------------------------
tmux new-session -d -s "$SESSION" -n faza1 \
  "LIBSCTP_COMPAT_UDP_ENCAPS_PORT=9899 LIBSCTP_COMPAT_UDP_ENCAPS_REMOTE_PORT=9900 \
   $BIN/srsepc $ETC/epc.conf 2>&1 | tee -a $LOGS/faza1-epc.log; read"
wait_for "$LOGS/faza1-epc.log" "SP-GW Initialized" 30 "srsepc porneste MME si SPGW" || {
  echo; echo "EPC nu a pornit. Sesiunea tmux ramane deschisa: tmux attach -t $SESSION"; exit 1; }

# --- 2. eNB ------------------------------------------------------------------
tmux split-window -t "$SESSION" -v \
  "LIBSCTP_COMPAT_UDP_ENCAPS_PORT=9900 LIBSCTP_COMPAT_UDP_ENCAPS_REMOTE_PORT=9899 \
   $BIN/srsenb $ETC/enb.conf 2>&1 | tee -a $LOGS/faza1-enb.log; read"
wait_for "$LOGS/faza1-enb.log" "S1Setup procedure completed successfully" 40 "eNB se conecteaza la MME prin SCTP" || {
  echo; echo "S1AP nu s-a stabilit. Verifica $LOGS/faza1-epc.log si faza1-enb.log"; exit 1; }

# --- 3. UE -------------------------------------------------------------------
tmux split-window -t "$SESSION" -v \
  "$BIN/srsue $ETC/ue.conf 2>&1 | tee -a $LOGS/faza1-ue.log; read"
tmux select-layout -t "$SESSION" even-vertical
wait_for "$LOGS/faza1-ue.log" "Network attach successful" 60 "UE se ataseaza la retea" || {
  echo; echo "Attach esuat. Verifica $LOGS/faza1-ue.log"; exit 1; }

# --- rezultat ----------------------------------------------------------------
echo
echo "=============================================================="
UE_IP=$(grep -o "IP: [0-9.]*" "$LOGS/faza1-ue.log" | tail -1 | awk '{print $2}')
echo "Attach reusit. IP alocat UE: ${UE_IP:-necunoscut}"

# Numele utun sunt alese de kernel, deci se citesc din log, nu din configuratie.
for pair in "epc:SGi" "ue:UE"; do
  comp="${pair%%:*}"; label="${pair##*:}"
  name=$(grep -o "assigned '[a-z0-9]*'" "$LOGS/faza1-$comp.log" | tail -1 | sed "s/assigned '//;s/'//")
  echo "Interfata $label: ${name:-nu a fost gasita in log}"
done

# --- rute -------------------------------------------------------------------
# macOS installs no subnet route for a utun, so nothing can be sent through
# either tunnel until we say where each address lives.
#
# The two host routes are deliberately crossed. Reaching the SGi goes out
# through the UE's tunnel, and reaching the UE goes out through the SGi's, so a
# packet between them travels the whole path: srsue, the ZeroMQ link, srsenb,
# GTP-U, srsepc. Both addresses are local to this machine, so without the
# crossing the kernel would answer on the loopback and prove nothing.
SGI_IF=$(grep -o "assigned '[a-z0-9]*'" "$LOGS/faza1-epc.log" | tail -1 | sed "s/assigned '//;s/'//")
UE_IF=$(grep -o "assigned '[a-z0-9]*'" "$LOGS/faza1-ue.log" | tail -1 | sed "s/assigned '//;s/'//")

if [ -n "$SGI_IF" ] && [ -n "$UE_IF" ]; then
  route -q -n delete -host 172.16.0.1 >/dev/null 2>&1
  route -q -n delete -host "${UE_IP:-172.16.0.2}" >/dev/null 2>&1
  route -n add -host 172.16.0.1 -interface "$UE_IF" >/dev/null 2>&1 &&
    echo "[ruta] 172.16.0.1 prin $UE_IF"
  route -n add -host "${UE_IP:-172.16.0.2}" -interface "$SGI_IF" >/dev/null 2>&1 &&
    echo "[ruta] ${UE_IP:-172.16.0.2} prin $SGI_IF"
else
  echo "[atentie] nu am putut citi numele interfetelor din log, rutele nu au fost adaugate"
fi

echo
echo "ifconfig pentru interfetele utun active:"
ifconfig | grep -A3 "^utun" | grep -B1 -E "172\.16\.0\." || echo "  (nicio interfata cu adresa 172.16.0.x)"

echo
echo "Sanity check final:"
echo "  ping -c 3 172.16.0.1"
echo
echo "Sesiune tmux: tmux attach -t $SESSION"
echo "Oprire:       tmux kill-session -t $SESSION"
echo "=============================================================="
