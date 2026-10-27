#!/bin/bash
# nebula.sh — Nebula overlay (100.64.0.0/16) поверх netns-стенда.
#
#   sudo ./nebula.sh gen            сертификаты + конфиги
#   sudo ./nebula.sh up             запустить все ноды (lighthouse -> relay -> хосты)
#   sudo ./nebula.sh status         интерфейсы nebula1 во всех namespace'ах
#   sudo ./nebula.sh test           overlay-ping + определение пути hostA->hostB (direct/relay)
#   sudo ./nebula.sh logs hostA     tail лога ноды
#   sudo ./nebula.sh down           остановить (ОБЯЗАТЕЛЬНО до `make down`)
#
# Роли:  ctrl = lighthouse | relay1, relay2 = relay | hostA, hostB = обычные ноды за NAT
#
# Переменные окружения:
#   NEBULA_PORT=4242          порт lighthouse/relay (под DPI_MODE=whitelist поставь 443)
#   NEBULA_CLIENT_PORT=0      порт hostA/hostB (0 = случайный, как рекомендует Nebula)
#   NEBULA_V6=1|0             0 = только IPv4 (смотреть relay-путь без v6-хитростей)
#   NEBULA_MTU=1300           MTU интерфейса nebula1
#   NEBULA_LOG=info|debug     уровень логов
#   NEBULA_BIN / NEBULA_CERT  пути к nebula / nebula-cert, если их нет в PATH под sudo
set -euo pipefail

DIR=${NEBULA_DIR:-/var/tmp/nebula-stand}
PORT=${NEBULA_PORT:-4242}
CPORT=${NEBULA_CLIENT_PORT:-0}
V6=${NEBULA_V6:-1}
MTU=${NEBULA_MTU:-1300}
LOG=${NEBULA_LOG:-info}
BIN=${NEBULA_BIN:-nebula}
CERT=${NEBULA_CERT:-nebula-cert}
X="ip netns exec"

LH_IP=100.64.0.1
LH_V4=203.0.113.10
LH_V6=2001:db8:100::10

ORDER=(lh relay1 relay2 hostA hostB)
declare -A NS=( [lh]=ns_ctrl [relay1]=ns_relay1 [relay2]=ns_relay2 [hostA]=ns_hostA [hostB]=ns_hostB )
declare -A OV=( [lh]=100.64.0.1 [relay1]=100.64.0.21 [relay2]=100.64.0.22 [hostA]=100.64.0.11 [hostB]=100.64.0.12 )

conf() {
  local n=$1 listen port am_lh=false am_relay=false use_relays=false
  [[ $V6 == 1 ]] && listen='"[::]"' || listen='"0.0.0.0"'
  case $n in
    lh)     port=$PORT; am_lh=true ;;
    relay*) port=$PORT; am_relay=true ;;
    *)      port=$CPORT; use_relays=true ;;
  esac

  cat <<EOF
pki:
  ca: $DIR/ca.crt
  cert: $DIR/$n.crt
  key: $DIR/$n.key

EOF

  if [[ $n != lh ]]; then
    if [[ $V6 == 1 ]]; then
      echo "static_host_map:
  \"$LH_IP\": [\"$LH_V4:$PORT\", \"[$LH_V6]:$PORT\"]
"
    else
      echo "static_host_map:
  \"$LH_IP\": [\"$LH_V4:$PORT\"]
"
    fi
  fi

  cat <<EOF
lighthouse:
  am_lighthouse: $am_lh
  interval: 5
EOF
  [[ $n != lh ]] && printf '  hosts:\n    - "%s"\n' "$LH_IP"

  cat <<EOF

listen:
  host: $listen
  port: $port

punchy:
  punch: true
  respond: true
  delay: 1s

relay:
  am_relay: $am_relay
  use_relays: $use_relays
EOF
  if [[ $n == host* ]]; then
    printf '  relays:\n    - "%s"\n    - "%s"\n' "${OV[relay1]}" "${OV[relay2]}"
  fi

  cat <<EOF

tun:
  dev: nebula1
  mtu: $MTU

logging:
  level: $LOG

# Лабораторный firewall: всё разрешено внутри overlay. Для реальных нод так не делать.
firewall:
  outbound:
    - port: any
      proto: any
      host: any
  inbound:
    - port: any
      proto: any
      host: any
EOF
}

gen() {
  mkdir -p "$DIR"
  ( cd "$DIR"
    [[ -f ca.crt ]] || $CERT ca -name nebula-stand -duration 8760h
    for n in "${ORDER[@]}"; do
      [[ -f $n.crt ]] || $CERT sign -name "$n" -ip "${OV[$n]}/16"
      conf "$n" > "$n.yml"
    done )
  echo "сертификаты и конфиги: $DIR"
}

start() {
  nohup $X "${NS[$1]}" "$BIN" -config "$DIR/$1.yml" >"$DIR/$1.log" 2>&1 &
  echo $! >"$DIR/$1.pid"
  echo "  $1 (${NS[$1]}) pid $!"
}

down() {
  local n
  for n in "${ORDER[@]}"; do
    if [[ -f $DIR/$n.pid ]]; then kill "$(cat "$DIR/$n.pid")" 2>/dev/null || true; rm -f "$DIR/$n.pid"; fi
  done
}

up() {
  local n
  for n in "${ORDER[@]}"; do
    $X "${NS[$n]}" true 2>/dev/null || { echo "нет ${NS[$n]}: сначала sudo make up"; exit 1; }
  done
  down
  gen
  echo "=== старт ==="
  for n in "${ORDER[@]}"; do
    start "$n"
    [[ $n == lh ]] && sleep 1
  done
  sleep 3
  status
}

status() {
  local n
  for n in "${ORDER[@]}"; do
    printf '%-7s ' "$n"
    $X "${NS[$n]}" ip -br addr show nebula1 2>/dev/null || echo "nebula1 нет (смотри $DIR/$n.log)"
  done
}

# Прямой путь hostA->hostB виден на dpi: зашифрованные пакеты (>150 байт, не 1-байтовые punch'и)
# между внешними адресами natA и natB. Если их нет — трафик идёт через relay.
path() {
  local family filter out tp n seen=0
  local -a captures=()

  echo "=== определение пути hostA -> hostB ==="

  for family in ipv4 ipv6; do
    if [[ $family == ipv4 ]]; then
      filter='udp and greater 150 and
        ((src 192.0.2.2 and dst 198.51.100.2) or
         (src 198.51.100.2 and dst 192.0.2.2))'
    else
      [[ $V6 == 1 ]] || {
        echo "[SKIP] IPv6 transport отключён (NEBULA_V6=0)"
        continue
      }

      filter='ip6 and udp and greater 150 and
        ((src 2001:db8:a1::2 and dst 2001:db8:b1::2) or
         (src 2001:db8:b1::2 and dst 2001:db8:a1::2))'
    fi

    out=$(mktemp)
    captures+=("$out")

    echo "--- $family ---"

    # Слушаем внешний интерфейс DPI, через который проходит трафик hostA.
    $X ns_dpi timeout 10 tcpdump -nn -i toA -l \
      "$filter" >"$out" 2>&1 &
    tp=$!

    sleep 1

    # Пакеты достаточно большие, чтобы отличать полезный трафик
    # от коротких пакетов проверки NAT traversal.
    $X ns_hostA ping -c 8 -i 0.3 -W 2 -s 200 \
      "${OV[hostB]}" >/dev/null 2>&1 || true

    sleep 1
    kill "$tp" 2>/dev/null || true
    wait "$tp" 2>/dev/null || true

    if grep -q ' > ' "$out"; then
      echo "[DIRECT] Обнаружен прямой внешний $family трафик"
      grep ' > ' "$out" | head -n 3
      seen=1
    else
      echo "[INFO] Прямой $family трафик между hostA и hostB не обнаружен"
    fi
  done

  if (( seen )); then
    echo "Итог: прямой путь обнаружен хотя бы для одного IP-протокола."
    echo "Примечание: наличие прямого трафика не исключает relay для другого семейства."
  else
    echo "Итог: прямой путь не обнаружен; вероятен relay."
    echo "Проверь адреса NAT, интерфейс toA и tcpdump."
  fi

  for out in "${captures[@]}"; do
    rm -f "$out"
  done
}   

run_test() {
  local pair src dst ok=0 fail=0 skipped=0

  echo "=== overlay IPv4 ping ==="

  for pair in \
    "hostA lh" \
    "hostB lh" \
    "hostA relay1" \
    "hostB relay2" \
    "hostA hostB" \
    "hostB hostA"
  do
    read -r src dst <<< "$pair"

    if $X "${NS[$src]}" ping -4 -c 3 -W 2 -s 200 \
      "${OV[$dst]}" >/dev/null 2>&1; then
      echo "[ OK ]  $src -> $dst (${OV[$dst]})"
      ((ok+=1))
    else
      echo "[FAIL]  $src -> $dst (${OV[$dst]})"
      ((fail+=1))
    fi
  done

  echo
  echo "=== IPv6 transport configuration ==="

  if [[ $V6 == 1 ]]; then
    echo "[INFO] IPv6 включён в конфигурации Nebula."
    echo "[INFO] Проверяем доступность IPv6-маршрутов и адресов внешней сети."

    for n in "${ORDER[@]}"; do
      printf '%-7s ' "$n"
      if $X "${NS[$n]}" ip -6 addr show 2>/dev/null |
        grep -q 'inet6 '; then
        echo "[ OK ] IPv6-адреса присутствуют"
      else
        echo "[WARN] IPv6-адреса не обнаружены"
      fi
    done

    echo
    echo "Проверка IPv6-сокетов Nebula:"
    for n in "${ORDER[@]}"; do
      printf '%-7s ' "$n"
      if $X "${NS[$n]}" ss -H -lun 2>/dev/null |
        grep -Eq '(\[::\]|:::|\*:)' ; then
        echo "[INFO] Найден IPv6 UDP-сокет"
      else
        echo "[WARN] IPv6 UDP-сокет не найден или недоступен"
      fi
    done
  else
    echo "[SKIP] NEBULA_V6=0, IPv6 transport отключён."
    ((skipped+=1))
  fi

  echo
  echo "=== путь hostA -> hostB ==="
  path

  echo
  echo "=== итоги ==="
  echo "Успешные overlay-проверки: $ok"
  echo "Ошибки overlay-проверок:   $fail"
  echo "Пропущенные проверки:      $skipped"

  (( fail == 0 ))
}

[[ $EUID -eq 0 ]] || { echo "нужен root: sudo $0 $*"; exit 1; }
case ${1:-} in
  gen)    gen ;;
  up)     up ;;
  down)   down ;;
  status) status ;;
  test)   run_test ;;
  logs)   tail -n 50 -f "$DIR/${2:?укажи ноду: lh|relay1|relay2|hostA|hostB}.log" ;;
  *)      echo "usage: sudo $0 {gen|up|down|status|test|logs <node>}"; exit 1 ;;
esac