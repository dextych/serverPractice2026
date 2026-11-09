#!/usr/bin/env bash
# AmneziaWG-транспорт для стенда.
#
# 1) Точка-точка (как раньше): hostA <-> relay1, подсеть 10.66.0.0/24
#      up | test | status
#
# 2) Mesh-underlay для Nebula: Nebula работает ВНУТРИ AmneziaWG, а не рядом с ним.
#      mesh-up | mesh-test | mesh-status | mesh-conf | mesh-down | mesh-addr <узел> | mesh-net
#
#    Топология underlay (подсеть 10.67.0.0/24, последний октет как у overlay 100.64.0.x):
#
#      hostA, hostB (за NAT) --- клиенты, держат PersistentKeepalive ко всем хабам
#      lh (ctrl), relay1, relay2 --- хабы с публичными endpoint'ами, полносвязны между собой
#
#    Пира hostA <-> hostB в underlay НЕТ намеренно: WireGuard не умеет hole punching,
#    а natB (random) его всё равно ломает. Overlay между клиентами идёт через Nebula-relay,
#    и этот relay-трафик тоже едет внутри AWG.
#
#    down останавливает оба режима.
#
# Параметры: AWG_PORT=51820 (под DPI_MODE=whitelist: 443)
#            AWG_MTU=1420   (<= WAN_MTU - 80; NEBULA_MTU должен быть <= AWG_MTU - 60)
#            AWG_STATE_DIR=/var/tmp/awg-lab
set -Eeuo pipefail

ACTION="${1:-help}"
STATE_DIR="${AWG_STATE_DIR:-/var/tmp/awg-lab}"
PORT="${AWG_PORT:-51820}"
AWG_MTU="${AWG_MTU:-1420}"

# ---- точка-точка (hostA <-> relay1) -------------------------------------------
CLIENT_NS="ns_hostA"
SERVER_NS="ns_relay1"
CLIENT_IF="hostA"
SERVER_IF="relay1"
CLIENT_ADDR="10.66.0.2/24"
SERVER_ADDR="10.66.0.1/24"
CLIENT_TUN_ADDR="10.66.0.2"
SERVER_TUN_ADDR="10.66.0.1"

# ---- mesh-underlay ----------------------------------------------------------
MESH_NET="10.67.0.0/24"
MESH_DIR="$STATE_DIR/mesh"
MESH_ORDER=(lh relay1 relay2 hostA hostB)
HUBS=(lh relay1 relay2)
CLIENTS=(hostA hostB)
declare -A M_NS=( [lh]=ns_ctrl [relay1]=ns_relay1 [relay2]=ns_relay2 [hostA]=ns_hostA [hostB]=ns_hostB )
# Имена интерфейсов уникальны намеренно: userspace-реализация кладёт UAPI-сокет в
# /var/run/amneziawg/<iface>.sock, а /var/run общий для всех namespace'ов.
declare -A M_IF=( [lh]=u-lh [relay1]=u-r1 [relay2]=u-r2 [hostA]=u-hA [hostB]=u-hB )
declare -A M_IP=( [lh]=10.67.0.1 [relay1]=10.67.0.21 [relay2]=10.67.0.22 [hostA]=10.67.0.11 [hostB]=10.67.0.12 )
# Публичные (в рамках стенда) endpoint'ы хабов в inet-зоне. Клиенты за NAT endpoint'а не имеют.
declare -A M_PUB=( [lh]=203.0.113.10 [relay1]=203.0.113.11 [relay2]=203.0.113.12 )

# Параметры обфускации AmneziaWG. Для каждой пары пиров H1-H4, S1, S2 обязаны совпадать,
# поэтому у всего стенда они одни. Jc/Jmin/Jmax могут отличаться.
obf_params() {
  cat <<CFG
Jc = 5
Jmin = 8
Jmax = 80
S1 = 30
S2 = 90
H1 = 123456789
H2 = 223456789
H3 = 323456789
H4 = 423456789
CFG
}

need_ns() {
  local ns="$1"
  ip netns list | awk '{print $1}' | grep -Fxq "$ns" || {
    echo "namespace $ns не существует; сначала выполни make up" >&2
    exit 1
  }
}

stop_one() {
  local ns="$1" config="$2" iface="$3"
  if ip netns list | awk '{print $1}' | grep -Fxq "$ns"; then
    ip netns exec "$ns" awg-quick down "$config" >/dev/null 2>&1 || true
    ip netns exec "$ns" ip link del "$iface" >/dev/null 2>&1 || true
  fi
}

# =============================================================================
# Точка-точка hostA <-> relay1
# =============================================================================
ensure_keys() {
  install -d -m 700 "$STATE_DIR"
  if [[ ! -s "$STATE_DIR/server.key" || ! -s "$STATE_DIR/client.key" ]]; then
    umask 077
    awg genkey > "$STATE_DIR/server.key"
    awg genkey > "$STATE_DIR/client.key"
  fi
  chmod 600 "$STATE_DIR/server.key" "$STATE_DIR/client.key"
}

write_configs() {
  local server_priv client_priv server_pub client_pub
  server_priv="$(<"$STATE_DIR/server.key")"
  client_priv="$(<"$STATE_DIR/client.key")"
  server_pub="$(printf '%s\n' "$server_priv" | awg pubkey)"
  client_pub="$(printf '%s\n' "$client_priv" | awg pubkey)"

  cat > "$STATE_DIR/relay1.conf" <<CFG
[Interface]
PrivateKey = $server_priv
Address = $SERVER_ADDR
ListenPort = $PORT
$(obf_params)

[Peer]
PublicKey = $client_pub
AllowedIPs = $CLIENT_TUN_ADDR/32
CFG

  cat > "$STATE_DIR/hostA.conf" <<CFG
[Interface]
PrivateKey = $client_priv
Address = $CLIENT_ADDR
$(obf_params)

[Peer]
PublicKey = $server_pub
Endpoint = 203.0.113.11:$PORT
AllowedIPs = $SERVER_TUN_ADDR/32
PersistentKeepalive = 25
CFG
  chmod 600 "$STATE_DIR/relay1.conf" "$STATE_DIR/hostA.conf"
}

p2p_down() {
  stop_one "$CLIENT_NS" "$STATE_DIR/hostA.conf" "$CLIENT_IF"
  stop_one "$SERVER_NS" "$STATE_DIR/relay1.conf" "$SERVER_IF"
}

up() {
  need_ns "$CLIENT_NS"
  need_ns "$SERVER_NS"
  ensure_keys
  write_configs
  down   # оба режима делят UDP-порт на relay1, поэтому поднимаем по одному
  echo "AmneziaWG: запуск сервера в $SERVER_NS:$PORT"
  ip netns exec "$SERVER_NS" awg-quick up "$STATE_DIR/relay1.conf"
  echo "AmneziaWG: запуск клиента в $CLIENT_NS"
  ip netns exec "$CLIENT_NS" awg-quick up "$STATE_DIR/hostA.conf"
  echo "AmneziaWG поднят; адреса $CLIENT_TUN_ADDR <-> $SERVER_TUN_ADDR"
}

status() {
  local ns iface
  for ns in "$CLIENT_NS" "$SERVER_NS"; do
    if [[ "$ns" == "$CLIENT_NS" ]]; then
      iface="$CLIENT_IF"
    else
      iface="$SERVER_IF"
    fi

    echo "=== $ns ($iface) ==="
    if ip netns list | awk '{print $1}' | grep -Fxq "$ns"; then
      ip netns exec "$ns" awg show "$iface" 2>/dev/null \
        || echo "интерфейс $iface не запущен"
    else
      echo "namespace не существует"
    fi
  done
}

test_tunnel() {
  need_ns "$CLIENT_NS"
  need_ns "$SERVER_NS"
  ip netns exec "$CLIENT_NS" ping -I "$CLIENT_IF" -c 3 -W 2 "$SERVER_TUN_ADDR"
  echo
  status
}

# =============================================================================
# Mesh-underlay для Nebula
# =============================================================================
is_hub() { [[ -n ${M_PUB[$1]:-} ]]; }

mesh_keys() {
  local n
  install -d -m 700 "$MESH_DIR"
  for n in "${MESH_ORDER[@]}"; do
    [[ -s "$MESH_DIR/$n.key" ]] || ( umask 077; awg genkey > "$MESH_DIR/$n.key" )
    chmod 600 "$MESH_DIR/$n.key"
  done
}

# Правила пиров:
#   хаб    <-> хаб     обе стороны с Endpoint
#   клиент  -> хаб     Endpoint + PersistentKeepalive (держит маппинг в NAT)
#   хаб     -> клиент  без Endpoint: адрес выучится из входящего handshake
#   клиент <-> клиент  пира нет
# AllowedIPs везде строго /32 пира: транзит через хаб в underlay не работает.
mesh_conf() {
  local n p
  declare -A pub=()
  mesh_keys
  for n in "${MESH_ORDER[@]}"; do
    pub[$n]="$(awg pubkey < "$MESH_DIR/$n.key")"
  done

  for n in "${MESH_ORDER[@]}"; do
    {
      echo "[Interface]"
      echo "PrivateKey = $(<"$MESH_DIR/$n.key")"
      echo "Address = ${M_IP[$n]}/32"
      echo "MTU = $AWG_MTU"
      if is_hub "$n"; then echo "ListenPort = $PORT"; fi
      obf_params

      for p in "${MESH_ORDER[@]}"; do
        if [[ $p == "$n" ]]; then continue; fi
        if ! is_hub "$n" && ! is_hub "$p"; then continue; fi
        echo
        echo "[Peer]"
        echo "PublicKey = ${pub[$p]}"
        echo "AllowedIPs = ${M_IP[$p]}/32"
        if is_hub "$p"; then echo "Endpoint = ${M_PUB[$p]}:$PORT"; fi
        if ! is_hub "$n" && is_hub "$p"; then echo "PersistentKeepalive = 25"; fi
      done
    } > "$MESH_DIR/${M_IF[$n]}.conf"
    chmod 600 "$MESH_DIR/${M_IF[$n]}.conf"
  done
}

# Пары "кто куда пингует", которые обязаны работать.
mesh_pairs() {
  local c h i j
  for c in "${CLIENTS[@]}"; do
    for h in "${HUBS[@]}"; do echo "$c $h"; done
  done
  for i in "${!HUBS[@]}"; do
    for j in "${!HUBS[@]}"; do
      if (( i < j )); then echo "${HUBS[$i]} ${HUBS[$j]}"; fi
    done
  done
}

# Обратное направление хаб -> клиент (работает после handshake'а клиента).
mesh_pairs_back() {
  local c h
  for c in "${CLIENTS[@]}"; do
    for h in "${HUBS[@]}"; do echo "$h $c"; done
  done
}

mesh_ping() {   # mesh_ping src dst count
  ip netns exec "${M_NS[$1]}" ping -I "${M_IF[$1]}" -c "$3" -W 1 -n "${M_IP[$2]}" >/dev/null 2>&1
}

# Ждём, пока поднимутся все handshake'и (первые пинги клиентов их инициируют).
mesh_wait() {
  local try src dst bad
  for try in 1 2 3 4 5 6 7 8; do
    bad=0
    while read -r src dst; do
      mesh_ping "$src" "$dst" 1 || bad=1
    done < <(mesh_pairs)
    if (( bad == 0 )); then
      echo "AmneziaWG mesh: все линки underlay подняты"
      return 0
    fi
    sleep 1
  done
  echo "AmneziaWG mesh: не все линки поднялись за 8 с; смотри make awg-mesh-status" >&2
  return 1
}

mesh_up() {
  local n out
  for n in "${MESH_ORDER[@]}"; do need_ns "${M_NS[$n]}"; done
  mesh_conf
  down
  echo "AmneziaWG mesh: underlay $MESH_NET, UDP-порт хабов $PORT, MTU $AWG_MTU"
  for n in "${MESH_ORDER[@]}"; do
    echo "  $n (${M_NS[$n]}): ${M_IF[$n]} ${M_IP[$n]}"
    if ! out=$(ip netns exec "${M_NS[$n]}" awg-quick up "$MESH_DIR/${M_IF[$n]}.conf" 2>&1); then
      echo "$out" >&2
      echo "awg-quick не смог поднять ${M_IF[$n]} в ${M_NS[$n]}" >&2
      exit 1
    fi
  done
  mesh_wait
}

mesh_down() {
  local n
  for n in "${MESH_ORDER[@]}"; do
    stop_one "${M_NS[$n]}" "$MESH_DIR/${M_IF[$n]}.conf" "${M_IF[$n]}"
  done
}

mesh_status() {
  local n
  for n in "${MESH_ORDER[@]}"; do
    echo "=== $n (${M_NS[$n]}, ${M_IF[$n]}) ==="
    if ip netns list | awk '{print $1}' | grep -Fxq "${M_NS[$n]}"; then
      ip netns exec "${M_NS[$n]}" awg show "${M_IF[$n]}" 2>/dev/null \
        || echo "интерфейс ${M_IF[$n]} не запущен"
    else
      echo "namespace не существует"
    fi
  done
}

mesh_test() {
  local n src dst ok=0 fail=0
  for n in "${MESH_ORDER[@]}"; do need_ns "${M_NS[$n]}"; done

  echo "=== AmneziaWG underlay: достижимость ==="
  while read -r src dst; do
    if mesh_ping "$src" "$dst" 3; then
      echo "[ OK ] $src -> $dst (${M_IP[$dst]})"
      ((ok+=1))
    else
      echo "[FAIL] $src -> $dst (${M_IP[$dst]})"
      ((fail+=1))
    fi
  done < <(mesh_pairs; mesh_pairs_back)

  echo "=== Негативная: клиент <-> клиент в underlay пира не имеет ==="
  if mesh_ping hostA hostB 1; then
    echo "[FAIL] hostA -> hostB в underlay достижим (пира быть не должно)"
    ((fail+=1))
  else
    echo "[ OK ] hostA -> hostB в underlay: заблокировано, как и задумано (остаётся Nebula-relay)"
    ((ok+=1))
  fi

  echo
  mesh_status
  echo
  echo "Успешные проверки: $ok, ошибки: $fail"
  (( fail == 0 ))
}

# Все действия, кроме mesh-addr/mesh-net/help, требуют root (ip netns).
down() {
  p2p_down
  mesh_down
}

case "$ACTION" in
  up) up ;;
  down) down ;;
  status) status ;;
  test) test_tunnel ;;
  mesh-up) mesh_up ;;
  mesh-down) mesh_down ;;
  mesh-status) mesh_status ;;
  mesh-test) mesh_test ;;
  mesh-conf) mesh_conf; echo "конфиги: $MESH_DIR" ;;
  mesh-addr)
    [[ -n ${M_IP[${2:-}]:-} ]] || { echo "usage: $0 mesh-addr {lh|relay1|relay2|hostA|hostB}" >&2; exit 2; }
    echo "${M_IP[$2]}"
    ;;
  mesh-net) echo "$MESH_NET" ;;
  help|*)
    echo "Использование: $0 {up|down|status|test}                       # hostA <-> relay1"
    echo "               $0 {mesh-up|mesh-test|mesh-status|mesh-conf|mesh-down}   # underlay для Nebula"
    echo "Параметры: AWG_PORT=51820 AWG_MTU=1420 AWG_STATE_DIR=/var/tmp/awg-lab"
    [[ "$ACTION" == help ]] || exit 2
    ;;
esac