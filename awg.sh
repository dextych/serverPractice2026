#!/usr/bin/env bash
# AmneziaWG userspace tunnel between ns_hostA and ns_relay1.
set -Eeuo pipefail

ACTION="${1:-help}"
STATE_DIR="${AWG_STATE_DIR:-/var/tmp/awg-lab}"
CLIENT_NS="ns_hostA"
SERVER_NS="ns_relay1"
CLIENT_IF="hostA"
SERVER_IF="relay1"
PORT="${AWG_PORT:-51820}"
CLIENT_ADDR="10.66.0.2/24"
SERVER_ADDR="10.66.0.1/24"
CLIENT_TUN_ADDR="10.66.0.2"
SERVER_TUN_ADDR="10.66.0.1"

need_ns() {
    local ns="$1"
    ip netns list | awk '{print $1}' | grep -Fxq "$ns" || {
        echo "namespace $ns не существует; сначала выполни make up" >&2
        exit 1
    }
}

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
Jc = 5
Jmin = 8
Jmax = 80
S1 = 30
S2 = 90
H1 = 123456789
H2 = 223456789
H3 = 323456789
H4 = 423456789

[Peer]
PublicKey = $client_pub
AllowedIPs = $CLIENT_TUN_ADDR/32
CFG

    cat > "$STATE_DIR/hostA.conf" <<CFG
[Interface]
PrivateKey = $client_priv
Address = $CLIENT_ADDR
Jc = 5
Jmin = 8
Jmax = 80
S1 = 30
S2 = 90
H1 = 123456789
H2 = 223456789
H3 = 323456789
H4 = 423456789

[Peer]
PublicKey = $server_pub
Endpoint = 203.0.113.11:$PORT
AllowedIPs = $SERVER_TUN_ADDR/32
PersistentKeepalive = 25
CFG
    chmod 600 "$STATE_DIR/relay1.conf" "$STATE_DIR/hostA.conf"
}

stop_one() {
    local ns="$1" config="$2" iface="$3"
    if ip netns list | awk '{print $1}' | grep -Fxq "$ns"; then
        ip netns exec "$ns" awg-quick down "$config" >/dev/null 2>&1 || true
        ip netns exec "$ns" ip link del "$iface" >/dev/null 2>&1 || true
    fi
}

up() {
    need_ns "$CLIENT_NS"
    need_ns "$SERVER_NS"
    ensure_keys
    write_configs
    down
    echo "AmneziaWG: запуск сервера в $SERVER_NS:$PORT"
    ip netns exec "$SERVER_NS" awg-quick up "$STATE_DIR/relay1.conf"
    echo "AmneziaWG: запуск клиента в $CLIENT_NS"
    ip netns exec "$CLIENT_NS" awg-quick up "$STATE_DIR/hostA.conf"
    echo "AmneziaWG поднят; адреса $CLIENT_TUN_ADDR <-> $SERVER_TUN_ADDR"
}

down() {
    stop_one "$CLIENT_NS" "$STATE_DIR/hostA.conf" "$CLIENT_IF"
    stop_one "$SERVER_NS" "$STATE_DIR/relay1.conf" "$SERVER_IF"
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

case "$ACTION" in
    up) up ;;
    down) down ;;
    status) status ;;
    test) test_tunnel ;;
    help|*)
        echo "Использование: $0 {up|down|status|test}"
        echo "Параметры: AWG_PORT=51820 AWG_STATE_DIR=/var/tmp/awg-lab"
        [[ "$ACTION" == help ]] || exit 2
        ;;
esac
