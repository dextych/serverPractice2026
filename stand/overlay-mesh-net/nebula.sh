#!/bin/bash
# nebula.sh — Nebula overlay (100.64.0.0/16) поверх netns-стенда.
#
#   sudo ./nebula.sh gen          сертификаты + конфиги
#   sudo ./nebula.sh up           (при NEBULA_TRANSPORT=awg сначала поднимает AmneziaWG-underlay)
#                                 запустить все ноды (lighthouse -> relay -> хосты)
#   sudo ./nebula.sh status       интерфейсы nebula1 во всех namespace'ах
#   sudo ./nebula.sh test         overlay-ping + проверка, что мимо транспорта ничего не утекает
#   sudo ./nebula.sh logs hostA   tail лога ноды
#   sudo ./nebula.sh down         остановить Nebula (ОБЯЗАТЕЛЬНО до `make down`);
#                                 underlay гасится отдельно: make awg-down
#
# Роли: ctrl = lighthouse | relay1, relay2 = relay | hostA, hostB = обычные ноды за NAT
#
# Транспорт (NEBULA_TRANSPORT):
#   awg  (по умолчанию) Nebula — ЭТО ВНУТРЕННИЙ СЛОЙ внутри AmneziaWG. Каждая нода биндит
#        UDP-сокет на свой адрес underlay (10.67.0.0/24, интерфейс u-*), поэтому её пакеты
#        физически не могут уйти в eth0 минуя AWG. DPI видит только AWG-трафик на AWG_PORT.
#        Схему underlay и правила пиров см. в awg.sh.
#   raw  Nebula ходит напрямую по сети стенда рядом с остальным трафиком (старое поведение,
#        базовая линия для сравнения «с обфускацией / без»).
#
# Переменные окружения:
#   NEBULA_TRANSPORT=awg|raw   см. выше
#   AWG_PORT=51820             (awg) UDP-порт AmneziaWG на хабах; под DPI_MODE=whitelist поставь 443.
#                              NEBULA_PORT на проводе не виден и от DPI не зависит
#   AWG_MTU=1420               (awg) MTU интерфейсов u-*; NEBULA_MTU должен быть <= AWG_MTU - 60
#   NEBULA_PORT=4242           порт lighthouse/relay внутри underlay (raw: на проводе; под whitelist — 443)
#   NEBULA_CLIENT_PORT=0       порт hostA/hostB (0 = случайный, как рекомендует Nebula)
#   NEBULA_V6=1|0              (raw) 0 = только IPv4. В режиме awg underlay только IPv4, значение игнорируется
#   NEBULA_MTU=1300            MTU интерфейса nebula1
#   NEBULA_LOG=info|debug      уровень логов
#   NEBULA_BIN / NEBULA_CERT   пути к nebula / nebula-cert, если их нет в PATH под sudo
#   AWG_SH=./awg.sh            путь к скрипту underlay
set -euo pipefail

DIR=${NEBULA_DIR:-/var/tmp/nebula-stand}
PORT=${NEBULA_PORT:-4242}
CPORT=${NEBULA_CLIENT_PORT:-0}
V6=${NEBULA_V6:-1}
MTU=${NEBULA_MTU:-1300}
LOG=${NEBULA_LOG:-info}
BIN=${NEBULA_BIN:-nebula}
CERT=${NEBULA_CERT:-nebula-cert}
TRANSPORT=${NEBULA_TRANSPORT:-awg}
AWG_SH=${AWG_SH:-$(dirname "$(readlink -f "$0")")/awg.sh}
AWG_PORT=${AWG_PORT:-51820}
AWG_MTU=${AWG_MTU:-1420}
X="ip netns exec"

case $TRANSPORT in
  awg|raw) ;;
  *) echo "NEBULA_TRANSPORT должен быть awg или raw, а не '$TRANSPORT'" >&2; exit 1 ;;
esac

LH_IP=100.64.0.1
LH_V4=203.0.113.10
LH_V6=2001:db8:100::10

ORDER=(lh relay1 relay2 hostA hostB)
declare -A NS=( [lh]=ns_ctrl [relay1]=ns_relay1 [relay2]=ns_relay2 [hostA]=ns_hostA [hostB]=ns_hostB )
declare -A OV=( [lh]=100.64.0.1 [relay1]=100.64.0.21 [relay2]=100.64.0.22 [hostA]=100.64.0.11 [hostB]=100.64.0.12 )

# Адреса underlay берём из awg.sh: единый источник правды.
declare -A UL=()
UL_NET=
if [[ $TRANSPORT == awg ]]; then
  [[ -x $AWG_SH ]] || { echo "нет $AWG_SH: он нужен для NEBULA_TRANSPORT=awg" >&2; exit 1; }
  UL_NET=$("$AWG_SH" mesh-net)
  for n in "${ORDER[@]}"; do UL[$n]=$("$AWG_SH" mesh-addr "$n"); done
fi

conf() {
  local n=$1 listen port am_lh=false am_relay=false use_relays=false punch=true hub
  case $n in
    lh) port=$PORT; am_lh=true ;;
    relay*) port=$PORT; am_relay=true ;;
    *) port=$CPORT; use_relays=true ;;
  esac

  if [[ $TRANSPORT == awg ]]; then
    # Бинд на адрес underlay: исходящие пакеты Nebula идут только через u-*.
    # Hole punching внутри AWG не нужен: NAT держит PersistentKeepalive самого AWG.
    listen="\"${UL[$n]}\""
    punch=false
  elif [[ $V6 == 1 ]]; then
    listen='"[::]"'
  else
    listen='"0.0.0.0"'
  fi

  cat <<EOF
pki:
  ca: $DIR/ca.crt
  cert: $DIR/$n.crt
  key: $DIR/$n.key

EOF

  if [[ $n != lh ]]; then
    if [[ $TRANSPORT == awg ]]; then
      printf 'static_host_map:\n  "%s": ["%s:%s"]\n\n' "$LH_IP" "${UL[lh]}" "$PORT"
    elif [[ $V6 == 1 ]]; then
      printf 'static_host_map:\n  "%s": ["%s:%s", "[%s]:%s"]\n\n' "$LH_IP" "$LH_V4" "$PORT" "$LH_V6" "$PORT"
    else
      printf 'static_host_map:\n  "%s": ["%s:%s"]\n\n' "$LH_IP" "$LH_V4" "$PORT"
    fi
  fi

  cat <<EOF
lighthouse:
  am_lighthouse: $am_lh
  interval: 5
EOF
  if [[ $n != lh ]]; then
    printf '  hosts:\n    - "%s"\n' "$LH_IP"
  fi

  if [[ $TRANSPORT == awg ]]; then
    # Анонсируем lighthouse'у только адрес underlay: ни eth0, ни адреса за NAT
    # в overlay-маршрутизацию попасть не должны.
    printf '  local_allow_list:\n    "%s": true\n    "0.0.0.0/0": false\n    "::/0": false\n' "$UL_NET"
    # Хосты ходят только к хабам (прямого пира hostA <-> hostB в underlay нет),
    # поэтому не пытаемся к соседу напрямую: сразу relay, без ошибок отправки в логе.
    printf '  remote_allow_list:\n'
    if [[ $n == host* ]]; then
      for hub in lh relay1 relay2; do
        printf '    "%s/32": true\n' "${UL[$hub]}"
      done
    else
      printf '    "%s": true\n' "$UL_NET"
    fi
    printf '    "0.0.0.0/0": false\n    "::/0": false\n'
  fi

  cat <<EOF

listen:
  host: $listen
  port: $port

punchy:
  punch: $punch
  respond: $punch
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
  if [[ $TRANSPORT == awg ]] && (( MTU > AWG_MTU - 60 )); then
    echo "[WARN] NEBULA_MTU=$MTU > AWG_MTU-60=$((AWG_MTU - 60)): пакеты будут фрагментироваться внутри AWG" >&2
  fi
  ( cd "$DIR"
    [[ -f ca.crt ]] || $CERT ca -name nebula-stand -duration 8760h
    for n in "${ORDER[@]}"; do
      [[ -f $n.crt ]] || $CERT sign -name "$n" -ip "${OV[$n]}/16"
      conf "$n" > "$n.yml"
    done )
  echo "сертификаты и конфиги: $DIR (транспорт: $TRANSPORT)"
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
  if [[ $TRANSPORT == awg ]]; then
    echo "=== underlay: AmneziaWG (UDP/$AWG_PORT, MTU $AWG_MTU) ==="
    AWG_PORT=$AWG_PORT AWG_MTU=$AWG_MTU "$AWG_SH" mesh-up \
      || { echo "underlay не поднялся, Nebula не стартую"; exit 1; }
  fi
  gen
  echo "=== старт Nebula (транспорт: $TRANSPORT) ==="
  for n in "${ORDER[@]}"; do
    start "$n"
    if [[ $n == lh ]]; then sleep 1; fi
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

# --- raw: прямой путь hostA->hostB виден на dpi ---------------------------------
# Зашифрованные пакеты (>150 байт, не 1-байтовые punch'и) между внешними адресами
# natA и natB. Если их нет — трафик идёт через relay.
path_raw() {
  local family filter out tp seen=0
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

# --- awg: Nebula обязана ехать только внутри AmneziaWG ---------------------------
# На dpi (interface any = toA, toB и порты inet-зоны) во время overlay-трафика:
#   1. утечки: любой UDP, у которого ни sport, ни dport не равны AWG_PORT -> должно быть 0
#   2. контроль: AWG-пакеты на AWG_PORT должны быть (иначе проверка слепая)
#   3. прямой внешний трафик natA <-> natB должен отсутствовать: hostA->hostB может идти только через relay
# Возвращает 1, если нарушена любая проверка.
path_awg() {
  local leak aw direct tl ta td rc=0

  echo "=== транспорт: Nebula только внутри AmneziaWG (UDP/$AWG_PORT) ==="
  leak=$(mktemp); aw=$(mktemp); direct=$(mktemp)

  $X ns_dpi timeout 12 tcpdump -nn -i any -l "udp and not port $AWG_PORT" >"$leak" 2>&1 &
  tl=$!
  $X ns_dpi timeout 12 tcpdump -nn -i any -l "udp port $AWG_PORT" >"$aw" 2>&1 &
  ta=$!
  $X ns_dpi timeout 12 tcpdump -nn -i any -l "host 192.0.2.2 and host 198.51.100.2" >"$direct" 2>&1 &
  td=$!

  sleep 1
  # Трафик: hostA->hostB (relay-путь), хосты -> lighthouse, relay <-> lighthouse.
  $X ns_hostA ping -c 8 -i 0.3 -W 2 -s 200 "${OV[hostB]}" >/dev/null 2>&1 || true
  $X ns_hostB ping -c 4 -i 0.3 -W 2 -s 200 "${OV[hostA]}" >/dev/null 2>&1 || true
  $X ns_hostA ping -c 3 -W 2 "${OV[lh]}" >/dev/null 2>&1 || true
  $X ns_hostB ping -c 3 -W 2 "${OV[lh]}" >/dev/null 2>&1 || true
  sleep 1

  kill "$tl" "$ta" "$td" 2>/dev/null || true
  wait "$tl" "$ta" "$td" 2>/dev/null || true

  if grep -q ' > ' "$aw"; then
    echo "[ OK ] контроль: на проводе виден AmneziaWG ($(grep -c ' > ' "$aw") пакетов на UDP/$AWG_PORT)"
  else
    echo "[FAIL] на UDP/$AWG_PORT нет пакетов: проверка утечек слепая (underlay не работает?)"
    rc=1
  fi

  if grep -q ' > ' "$leak"; then
    echo "[FAIL] утечка: UDP мимо AmneziaWG ($(grep -c ' > ' "$leak") пакетов)"
    grep ' > ' "$leak" | head -n 5
    rc=1
  else
    echo "[ OK ] мимо AmneziaWG на проводе нет ни одного UDP-пакета (Nebula завёрнута полностью)"
  fi

  if grep -q ' > ' "$direct"; then
    echo "[FAIL] между natA и natB виден прямой трафик (underlay hostA<->hostB быть не должно)"
    grep ' > ' "$direct" | head -n 3
    rc=1
  else
    echo "[ OK ] прямого пути natA <-> natB нет: hostA -> hostB идёт только через Nebula-relay внутри AWG"
  fi

  rm -f "$leak" "$aw" "$direct"
  return $rc
}

run_test() {
  local pair src dst ok=0 fail=0 skipped=0 n

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
      echo "[ OK ] $src -> $dst (${OV[$dst]})"
      ((ok+=1))
    else
      echo "[FAIL] $src -> $dst (${OV[$dst]})"
      ((fail+=1))
    fi
  done

  echo

  if [[ $TRANSPORT == awg ]]; then
    echo "=== IPv6 transport ==="
    echo "[SKIP] underlay AmneziaWG работает по IPv4; IPv6-проверки актуальны только для NEBULA_TRANSPORT=raw"
    ((skipped+=1))
  else
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
  fi

  echo
  if [[ $TRANSPORT == awg ]]; then
    if path_awg; then
      ((ok+=1))
    else
      ((fail+=1))
    fi
  else
    path_raw
  fi

  echo
  echo "=== итоги (транспорт: $TRANSPORT) ==="
  echo "Успешные overlay-проверки: $ok"
  echo "Ошибки overlay-проверок: $fail"
  echo "Пропущенные проверки: $skipped"

  (( fail == 0 ))
}

[[ $EUID -eq 0 ]] || { echo "нужен root: sudo $0 $*"; exit 1; }
case ${1:-} in
  gen) gen ;;
  up) up ;;
  down) down ;;
  status) status ;;
  test) run_test ;;
  logs) tail -n 50 -f "$DIR/${2:?укажи ноду: lh|relay1|relay2|hostA|hostB}.log" ;;
  *) echo "usage: sudo $0 {gen|up|down|status|test|logs <node>}"; exit 1 ;;
esac