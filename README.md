# Стенд: overlay mesh за NAT с имитацией DPI

Воспроизводимый сетевой стенд на одной машине (Linux network namespaces + veth + nftables).
Нужен, чтобы проверять обфускацию транспорта, NAT-traversal и overlay-сеть (Nebula и аналоги) в условиях, близких к реальной фильтрации. Поддерживаются IPv4 и IPv6.

Стенд не трогает сетевые настройки хоста: всё живёт в изолированных namespace'ах, а удаляется одной командой.

## Содержание

1. [Требования](#требования)
2. [Топология и адресация](#топология-и-адресация)
3. [Быстрый старт](#быстрый-старт)
4. [Команды](#команды)
5. [Параметры](#параметры)
6. [Как работать со стендом](#как-работать-со-стендом)
7. [Сценарии экспериментов](#сценарии-экспериментов)
8. [Устройство NAT и DPI](#устройство-nat-и-dpi)
9. [Частые проблемы](#частые-проблемы)
10. [Ограничения](#ограничения)

## Требования

- Linux, права root (`sudo`).
- Утилиты: `iproute2` (`ip`, `tc`), `nftables` (`nft`), `ping` (iputils), `make`, `bash`.
- Для тестов и отладки: `python3`, `tcpdump`, желательно `conntrack-tools`.
- Опции ядра: `CONFIG_NET_NS`, `VETH`, `BRIDGE`, `NF_TABLES`, `NFT_NAT`, `NFT_MASQ`, `NF_CONNTRACK`, `NET_SCH_NETEM`.
  Для DPI на Suricata дополнительно `NFT_QUEUE`.

Быстрая проверка ядра: `zcat /proc/config.gz | grep -E 'NET_NS|VETH|BRIDGE|NF_TABLES|NFT_NAT|NFT_MASQ|NET_SCH_NETEM'`.

## Топология и адресация

```
[hostA]--LAN-A--[natA]--WAN-A--+                  +--[ctrl]
                (cone)         |                  |
                             [dpi]---br-inet------+--[relay1]
                (random)       |                  |
[hostB]--LAN-B--[natB]--WAN-B--+                  +--[relay2]
```

| Зона | IPv4 | IPv6 | Узлы |
|---|---|---|---|
| LAN-A | 10.10.1.0/24 | 2001:db8:a1::/64 | hostA `.2`, natA `.1` |
| WAN-A | 192.0.2.0/24 | 2001:db8:a0::/64 | natA `.2`, dpi `.1` |
| LAN-B | 10.10.2.0/24 | 2001:db8:b1::/64 | hostB `.2`, natB `.1` |
| WAN-B | 198.51.100.0/24 | 2001:db8:b0::/64 | natB `.2`, dpi `.1` |
| INET | 203.0.113.0/24 | 2001:db8:100::/64 | dpi `.1`, ctrl `.10`, relay1 `.11`, relay2 `.12` |
| Overlay | 100.64.0.0/16 | | задаётся при настройке overlay, на стенде не создаётся |

Namespace'ы: `ns_hostA`, `ns_natA`, `ns_hostB`, `ns_natB`, `ns_dpi`, `ns_ctrl`, `ns_relay1`, `ns_relay2`.

Интерфейсы: у хостов, ctrl и relay'ев `eth0`; у NAT'ов `lan` и `wan`; в `ns_dpi` это `toA`, `toB` (к NAT'ам) и бридж `br-inet` (к inet-зоне).

Роли узлов:

| Узел | Роль |
|---|---|
| hostA, hostB | клиенты за NAT, будущие узлы overlay |
| natA | NAT с сохранением порта (cone-подобный) |
| natB | NAT со случайным портом (symmetric-подобный, «тяжёлый» случай для hole punching) |
| dpi | транзитный роутер между NAT'ами и «интернетом»: фильтрация (имитация ТСПУ) и параметры канала |
| ctrl | контроллер / lighthouse |
| relay1, relay2 | relay-узлы и точки выхода |

### IPv6

NAT для IPv6 не используется. На natA и natB работает stateful firewall: исходящие с LAN разрешены, входящие новые с WAN отбрасываются. Используются префиксы `2001:db8::/32` (документационные). ULA здесь не подходит: без NPTv6 у ctrl нет обратного маршрута.

## Быстрый старт

```bash
sudo make up        # развернуть
sudo make test      # проверить связность и NAT/firewall
sudo make test-dpi  # убедиться, что DPI режет WireGuard-подобные пакеты
sudo make down      # снести
```

Ожидаемый результат `make test`: все строки `[ OK ]`, включая негативные («заблокировано, как и задумано»). Любой `[FAIL]` значит ошибку в сборке стенда.

`make up` идемпотентен: перед сборкой он всегда вызывает `down`.

## Команды

| Команда | Что делает |
|---|---|
| `make help` | список команд (работает без root) |
| `make up` | собрать стенд целиком |
| `make down` | удалить все namespace'ы |
| `make test` | связность по v4/v6 + негативные проверки NAT и firewall |
| `make test-dpi` | отправить WG-подобные пакеты и показать счётчики DPI |
| `make dpi` | переприменить правила DPI (режим из `DPI_MODE`) |
| `make netem` / `make netem-off` | задать / снять задержку и потери |
| `make mtu` | выставить MTU на WAN-линках (`WAN_MTU`) |
| `make show` | адреса, маршруты, правила nft, qdisc |
| `make cap N=<ns> IF=<iface>` | `tcpdump` внутри namespace |
| `make sh N=<ns>` | интерактивный шелл внутри namespace |

## Параметры

Передаются в командной строке: `sudo make up DPI_MODE=whitelist NETEM="delay 50ms 10ms loss 1%"`.

| Параметр | По умолчанию | Описание |
|---|---|---|
| `DPI_MODE` | `sig` | `sig`: режем сигнатуры WireGuard; `whitelist`: пропускаем только UDP 53/443; `off`: DPI выключен |
| `NETEM` | `delay 15ms 3ms loss 0.25%` | параметры `tc netem`; применяются в каждую сторону |
| `WAN_MTU` | `1500` | MTU WAN-линков (natA↔dpi, natB↔dpi) |
| `N` | `ns_hostA` | namespace для `cap` и `sh` |
| `IF` | `any` | интерфейс для `cap` |

Задержка навешивается на `toA`, `toB` и `br-inet` в `ns_dpi`, поэтому RTT примерно вдвое больше значения `delay`.

## Как работать со стендом

### Запуск команд внутри узла

```bash
sudo ip netns exec ns_hostA ping -c3 203.0.113.10
sudo ip netns exec ns_relay1 ss -ulnp
sudo make sh N=ns_hostB          # шелл внутри namespace
```

Любой сервис (Nebula, Hysteria2, AmneziaWG) запускается так же: `sudo ip netns exec ns_relay1 <команда>`. Конфиги и бинарники берутся из обычной файловой системы хоста.

### Наблюдение за трафиком

```bash
sudo make cap N=ns_dpi IF=toA        # то, что приходит на dpi со стороны WAN-A (уже после NAT)
sudo make cap N=ns_natA IF=lan       # трафик клиента до NAT
sudo make cap N=ns_natA IF=wan       # он же после NAT
sudo make cap N=ns_ctrl IF=eth0      # что видит контроллер
```

Сравнение `lan` и `wan` на NAT-узле показывает подмену адреса и порта. На ctrl исходный адрес клиента не виден никогда.

### Таблица трансляций

```bash
sudo ip netns exec ns_natA conntrack -L
sudo ip netns exec ns_natB conntrack -L
```

### Счётчики DPI

```bash
sudo ip netns exec ns_dpi nft list table inet dpi
```

Счётчик `counter` у каждого правила показывает число отброшенных пакетов. Именно эти цифры идут в отчёт как доказательство работы фильтрации.

### Перед `make down`

Процессы, запущенные внутри namespace, удерживают его. Остановите их до удаления стенда:

```bash
for n in ns_hostA ns_natA ns_hostB ns_natB ns_dpi ns_ctrl ns_relay1 ns_relay2; do
  sudo ip netns pids $n | xargs -r sudo kill
done
sudo make down
```

## Сценарии экспериментов

### 1. Проверка типа NAT

Цель: убедиться, что natA сохраняет порт, а natB выдаёт случайный.

Терминал 1 (смотрим внешний порт на стороне inet):
```bash
sudo make cap N=ns_dpi IF=br-inet
```

Терминал 2 (с каждого клиента шлём UDP с фиксированного локального порта на два разных адреса):
```bash
for h in ns_hostA ns_hostB; do
  sudo ip netns exec $h python3 -c "
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.bind(('0.0.0.0', 40000))
for d in ('203.0.113.10', '203.0.113.11'):
    s.sendto(b'x', (d, 5000))
"
done
```

Ожидаемо: у hostA через natA внешний порт остаётся `40000` для обоих направлений, у hostB через natB внешние порты разные и не равны `40000`. Подтвердить можно через `conntrack -L`.

### 2. Проверка DPI

```bash
sudo make dpi DPI_MODE=sig
sudo make test-dpi
```

Счётчики `wg-init` должны вырасти (6 пакетов: 3 по v4, 3 по v6). Затем:

```bash
sudo make dpi DPI_MODE=whitelist
sudo make test-dpi        # теперь режется любой UDP, кроме 53 и 443
sudo make dpi DPI_MODE=off
```

Цель эксперимента: голый WireGuard режется, обфусцированный транспорт проходит. Обфусцированный трафик не совпадает с сигнатурой `sig` (длина и первые байты другие), а в режиме `whitelist` ему нужно ходить по UDP/443.

### 3. Измерение MTU

Максимальный размер payload без фрагментации: MTU минус 28 байт для IPv4 (20 IP + 8 ICMP) и минус 48 для IPv6 (40 IP + 8 ICMP).

```bash
# голый путь, MTU 1500: 1472 должно пройти, 1473 нет (IPv4)
sudo ip netns exec ns_hostA ping -c2 -M do -s 1472 203.0.113.10
sudo ip netns exec ns_hostA ping -c2 -M do -s 1473 203.0.113.10
# IPv6: 1452 проходит, 1453 нет
sudo ip netns exec ns_hostA ping -6 -c2 -M do -s 1452 2001:db8:100::10

# занизить MTU WAN-линков и повторить
sudo make mtu WAN_MTU=1400
sudo ip netns exec ns_hostA ping -c2 -M do -s 1372 203.0.113.10
```

Замеры повторяют в трёх конфигурациях: голый путь, с обфускацией, с обфускацией и overlay. Разница между ними показывает накладные расходы каждого слоя.

### 4. Задержка и потери

```bash
sudo make netem NETEM="delay 30ms 5ms loss 0.5%"
sudo ip netns exec ns_hostA ping -c 50 203.0.113.10     # смотрим avg и mdev
sudo make netem-off
```

Для измерений в трёх режимах (direct, через relay, через обфускацию) снимайте RTT и jitter на каждом.

### 5. Отказ relay (failover)

```bash
# имитация падения relay1
sudo ip netns exec ns_relay1 ip link set eth0 down
# или точечно: сбросить весь трафик к relay1 на dpi
sudo ip netns exec ns_dpi nft add rule inet dpi forward ip daddr 203.0.113.11 drop

# вернуть
sudo ip netns exec ns_relay1 ip link set eth0 up
sudo ip netns exec ns_dpi nft flush chain inet dpi forward   # внимание: сотрёт и правила DPI, затем make dpi
sudo make dpi
```

Время восстановления связности фиксируйте непрерывным `ping` с отметками времени: `ping -D`.

## Устройство NAT и DPI

### NAT (natA, natB)

- `table ip nat`, цепочка `postrouting`, правило `oifname "wan" masquerade`.
- natA: порт сохраняется, если не конфликтует. Получается NAT, при котором hole punching обычно удаётся.
- natB: `masquerade random`, порт выбирается случайно для каждого соединения. Это приближение symmetric NAT, при котором прямое соединение часто невозможно и нужен relay.
- `table inet fw`: `forward` с политикой `drop`. Разрешены established/related и всё, что пришло с интерфейса `lan`. Работает одинаково для v4 и v6.

### DPI (dpi)

- `table inet dpi`, цепочка `forward` (политика `accept`), правила добавляются командой `make dpi`.
- `sig`: WireGuard initiation (UDP-пакет длиной 156, первые 4 байта payload `01 00 00 00`) и response (длина 92, `02 00 00 00`).
- `whitelist`: `udp dport != { 53, 443 } drop`.
- Правила стоят в `forward`, поэтому видят пакеты уже после NAT.
- Таблица `inet` покрывает IPv4 и IPv6 одними правилами.

## Частые проблемы

| Симптом | Причина и решение |
|---|---|
| `Запускать через sudo` | Makefile проверяет uid. Запускайте `sudo make ...` |
| `Operation not supported` / `No such file` при `nft` | В ядре нет нужных опций. См. раздел «Требования» |
| `Cannot find device` при `tc ... netem` | Не собрано `NET_SCH_NETEM` или стенд не поднят |
| `make test` падает сразу после `up` | Подождите 1-2 секунды и повторите; проверьте `make show`, что адреса не в `tentative` |
| `down` не удаляет, namespace «висит» | Внутри остались процессы. См. «Перед `make down`» |
| v6-пинг до ctrl не проходит | Проверьте `ip -6 route` в `ns_dpi` (должны быть маршруты на `2001:db8:a1::/64` и `2001:db8:b1::/64`) |
| После перезагрузки хоста стенда нет | Namespace'ы не переживают ребут. Достаточно снова `sudo make up` |
| Хост не может достучаться до узлов стенда | Так и задумано: стенд изолирован. Заходите через `ip netns exec` |

## Ограничения

- Стенд эмулирует лишь сигнатурную фильтрацию (по длине и первым байтам) и белый список портов. Анализ TLS/SNI и поведенческий анализ реального ТСПУ не воспроизводятся. Для них можно подключить Suricata через `nfqueue`.
- Выход в настоящий интернет и работу через Cloudflare стенд не имитирует; такие тесты делаются отдельно на реальном VPS.
- Поведение `masquerade random` лишь приближает symmetric NAT; на реальном оборудовании результаты могут отличаться.
- Стенд не сохраняется между перезагрузками и рассчитан на одну машину.