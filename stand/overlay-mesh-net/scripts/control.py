#!/usr/bin/env python3
"""Интерфейс управления статическим стендом overlay-mesh в формате JSON, только для чтения.

Модуль намеренно не изменяет сеть. Он описывает топологию и проверяет текущие
сетевые пространства имён Linux, чтобы внешний API мог использовать стабильный
JSON-контракт без разбора человекочитаемого вывода `make`.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from typing import Any

CONTRACT_VERSION = "1.0"

NODES: list[dict[str, Any]] = [
    {"id": "hostA", "namespace": "ns_hostA", "role": "host", "zone": "lan_a", "overlay_ip": "100.64.0.11"},
    {"id": "natA", "namespace": "ns_natA", "role": "nat", "zone": "edge_a", "overlay_ip": None},
    {"id": "hostB", "namespace": "ns_hostB", "role": "host", "zone": "lan_b", "overlay_ip": "100.64.0.12"},
    {"id": "natB", "namespace": "ns_natB", "role": "nat", "zone": "edge_b", "overlay_ip": None},
    {"id": "dpi", "namespace": "ns_dpi", "role": "dpi_router", "zone": "wan", "overlay_ip": None},
    {"id": "ctrl", "namespace": "ns_ctrl", "role": "lighthouse", "zone": "inet", "overlay_ip": "100.64.0.1"},
    {"id": "relay1", "namespace": "ns_relay1", "role": "relay", "zone": "inet", "overlay_ip": "100.64.0.21"},
    {"id": "relay2", "namespace": "ns_relay2", "role": "relay", "zone": "inet", "overlay_ip": "100.64.0.22"},
]

LINKS: list[dict[str, Any]] = [
    {"id": "lan_a", "endpoints": [{"node": "hostA", "interface": "eth0"}, {"node": "natA", "interface": "lan"}], "ipv4": "10.10.1.0/24", "ipv6": "2001:db8:a1::/64", "kind": "lan"},
    {"id": "wan_a", "endpoints": [{"node": "natA", "interface": "wan"}, {"node": "dpi", "interface": "toA"}], "ipv4": "192.0.2.0/24", "ipv6": "2001:db8:a0::/64", "kind": "wan"},
    {"id": "lan_b", "endpoints": [{"node": "hostB", "interface": "eth0"}, {"node": "natB", "interface": "lan"}], "ipv4": "10.10.2.0/24", "ipv6": "2001:db8:b1::/64", "kind": "lan"},
    {"id": "wan_b", "endpoints": [{"node": "natB", "interface": "wan"}, {"node": "dpi", "interface": "toB"}], "ipv4": "198.51.100.0/24", "ipv6": "2001:db8:b0::/64", "kind": "wan"},
    {"id": "inet", "endpoints": [{"node": "dpi", "interface": "br-inet"}, {"node": "ctrl", "interface": "eth0"}, {"node": "relay1", "interface": "eth0"}, {"node": "relay2", "interface": "eth0"}], "ipv4": "203.0.113.0/24", "ipv6": "2001:db8:100::/64", "kind": "bridge"},
]


def emit(value: Any) -> None:
    json.dump(value, sys.stdout, ensure_ascii=False, indent=2, sort_keys=False)
    sys.stdout.write("\n")


def error(code: str, message: str, *, exit_code: int = 2) -> int:
    emit({"contract_version": CONTRACT_VERSION, "error": {"code": code, "message": message}})
    return exit_code


def topology() -> dict[str, Any]:
    return {
        "contract_version": CONTRACT_VERSION,
        "topology": {
            "id": "default",
            "name": "Стенд overlay-mesh-net по умолчанию",
            "status": "static",
            "capabilities": {
                "read_topology": True,
                "read_status": True,
                "create_node": False,
                "delete_node": False,
                "change_links": False,
                "manage_overlay": False,
            },
            "nodes": NODES,
            "links": LINKS,
        },
    }


def run_ip(args: list[str]) -> tuple[bool, Any, str | None]:
    if not shutil.which("ip"):
        return False, None, "Утилита ip из пакета iproute2 не установлена"
    try:
        result = subprocess.run(
            ["ip", *args], check=False, capture_output=True, text=True, timeout=5
        )
    except subprocess.TimeoutExpired:
        return False, None, "Истекло время ожидания команды"
    if result.returncode != 0:
        return False, None, result.stderr.strip() or f"Команда ip завершилась с кодом {result.returncode}"
    try:
        return True, json.loads(result.stdout), None
    except json.JSONDecodeError:
        return False, None, "Команда ip вернула некорректный JSON"


def node_status(node: dict[str, Any]) -> dict[str, Any]:
    namespace = node["namespace"]
    # Проверяем пространство имён напрямую: `ip netns exec ... true` не выводит JSON.
    if shutil.which("ip"):
        try:
            probe = subprocess.run(
                ["ip", "netns", "exec", namespace, "true"],
                check=False, capture_output=True, text=True, timeout=3,
            )
            exists = probe.returncode == 0
            ns_error = None if exists else (probe.stderr.strip() or "Сетевое пространство имён не существует")
        except subprocess.TimeoutExpired:
            exists, ns_error = False, "Истекло время ожидания проверки сетевого пространства имён"
    else:
        exists, ns_error = False, "Утилита ip из пакета iproute2 не установлена"

    result: dict[str, Any] = {
        **node,
        "state": "unknown",
        "namespace_exists": exists,
        "interfaces": [],
        "overlay": {"interface": "nebula1", "state": "unknown", "addresses": []},
    }
    if not exists:
        result["state"] = "stopped"
        result["diagnostic"] = ns_error
        result["overlay"]["state"] = "absent"
        return result

    ok, interfaces, probe_error = run_ip(["-j", "-n", namespace, "address", "show"])
    if not ok:
        result["diagnostic"] = probe_error
        return result

    result["state"] = "running"
    result["interfaces"] = [
        {
            "name": iface.get("ifname"),
            "state": iface.get("operstate", "UNKNOWN").lower(),
            "mtu": iface.get("mtu"),
            "addresses": [
                {"family": addr.get("family"), "address": addr.get("local"), "prefixlen": addr.get("prefixlen")}
                for addr in iface.get("addr_info", [])
            ],
        }
        for iface in interfaces
    ]
    overlay_iface = next((i for i in interfaces if i.get("ifname") == "nebula1"), None)
    if overlay_iface:
        result["overlay"] = {
            "interface": "nebula1",
            "state": "up" if "UP" in overlay_iface.get("flags", []) else overlay_iface.get("operstate", "UNKNOWN").lower(),
            "addresses": [
                {"family": addr.get("family"), "address": addr.get("local"), "prefixlen": addr.get("prefixlen")}
                for addr in overlay_iface.get("addr_info", [])
            ],
        }
    else:
        result["overlay"]["state"] = "absent"
    return result


def status() -> dict[str, Any]:
    nodes = [node_status(node) for node in NODES]
    states = [node["state"] for node in nodes]
    if all(state == "running" for state in states):
        overall = "running"
    elif all(state == "stopped" for state in states):
        overall = "stopped"
    else:
        overall = "degraded"
    return {
        "contract_version": CONTRACT_VERSION,
        "observed_at": datetime.now(timezone.utc).isoformat(),
        "state": overall,
        "nodes": nodes,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("topology", "status"), help="запрос только для чтения")
    parser.add_argument("--json", action="store_true", help="вывести JSON (сейчас это единственный формат вывода)")
    args = parser.parse_args()
    if not args.json:
        return error("json_required", "Укажите --json: это единственный поддерживаемый формат машинного вывода.")
    if args.command == "topology":
        emit(topology())
        return 0
    emit(status())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
