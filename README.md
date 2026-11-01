# Интеграция API-сервера и сетевого стенда (Overlay Mesh Net)

Данный проект представляет собой серверный API-слой на Node.js (Express), предназначенный для оркестрации, мониторинга и получения телеметрии сетевого стенда эмуляции ячеистой сети (`overlay-mesh-net`).

---

## 1. Архитектура и стек технологий

- **Runtime & Среда:** Node.js (ES Modules, v22+), WSL2 / Docker Desktop
- **Web-фреймворк:** Express 4.x
- **Управление дочерними процессами:** `execa` (асинхронное взаимодействие с Docker CLI)

---

## 2. Проделанная работа

### 2.1. Централизованная обработка ошибок
Спроектирована и внедрена трехуровневая система обработки исключений:
1. **Кастомный класс `AppError`** (`src/infrastructure/errors/appError.js`):
   - Стандартизирует формат ошибок приложения.
   - Поддерживает установку HTTP-статуса (например, `502 Bad Gateway`, `400 Bad Request`) и машиночитаемого кода ошибки (`code`).
2. **Асинхронная обертка `catchAsync`** (`src/infrastructure/errors/catchAsync.js`):
   - Автоматически пробрасывает необработанные отклоненные промисы в глобальный обработчик через `next(err)`.
3. **Глобальный middleware `errorHandler`** (`src/infrastructure/errors/errorHandler.js`):
   - Унифицированно перехватывает все типы ошибок: экземпляры `AppError`, системные ошибки валидации/уникальности ORM (Sequelize) и непредвиденные падения с кодом `500`.

### 2.2. Сервисный слой взаимодействия со стендом (`Stand`)
Реализован класс `src/services/stand.js` для безопасного вызова команд внутри контейнера:
- Взаимодействие со скриптом управления стендом `scripts/control.py` через `docker compose exec -T`.
- **Защита от зависаний (Timeout):** Добавлен тайм-аут выполнения команды (5000 мс). Если Docker или контейнер не отвечает вовремя, вызов прерывается с генерацией понятной ошибки `STAND_UNAVAILABLE` (502).

---

## 3. Спецификация реализованных эндпоинтов

### `GET /api/stand/status`
Возвращает текущее состояние пространств имен стенда.
- **Успешный ответ (200 OK):**
  ```json
  {
      "contract_version": "1.0",
      "observed_at": "2026-11-01T18:40:00.494542+00:00",
      "state": "running",
      "nodes": [
          {
              "id": "hostA",
              "namespace": "ns_hostA",
              "role": "host",
              "zone": "lan_a",
              "overlay_ip": "100.64.0.11",
              "state": "running",
              "namespace_exists": true,
              "interfaces": [
                  {
                      "name": "lo",
                      "state": "unknown",
                      "mtu": 65536,
                      "addresses": [
                          {
                              "family": "inet",
                              "address": "127.0.0.1",
                              "prefixlen": 8
                          },
                          {
                              "family": "inet6",
                              "address": "::1",
                              "prefixlen": 128
                          }
                      ]
                  },
                  {
                      "name": "eth0",
                      "state": "up",
                      "mtu": 1500,
                      "addresses": [
                          {
                              "family": "inet",
                              "address": "10.10.1.2",
                              "prefixlen": 24
                          },
                          {
                              "family": "inet6",
                              "address": "2001:db8:a1::2",
                              "prefixlen": 64
                          },
                          {
                              "family": "inet6",
                              "address": "fe80::b00e:c3ff:fe6d:340",
                              "prefixlen": 64
                          }
                      ]
                  }
              ],
              "overlay": {
                  "interface": "nebula1",
                  "state": "absent",
                  "addresses": []
              }
          }, ...
  ```

### `GET /api/stand/topology`
Возвращает JSON-схему топологии сети, конфигурацию адресации (IPv4/IPv6) и параметры симуляции (MTU, задержки).
- **Ошибка недоступности стенда (502 Bad Gateway):**
  ```json
  {
    "success": false,
    "error": {
        "message": "Стенд недоступен или выключен: Command failed with exit code 1: docker compose exec -T stand python3 ./scripts/control.py topology --json\n\nservice \"stand\" is not running",
        "code": "STAND_UNAVAILABLE"
    }
  }
  ```

---

## 4. Инструкция по запуску и тестированию

### 1. Запуск API-сервера
Из корневой директории `serverPractice2026`:
```bash
# Установка зависимостей
npm install

# Запуск в режиме разработки с автоперезагрузкой
npm run dev
```
Сервер будет доступен по адресу `http://localhost:3030`.

### 2. Проверка через Postman / cURL
```bash
# Проверка статуса стенда
curl -X GET http://localhost:3030/api/stand/status

# Получение топологии сети
curl -X GET http://localhost:3030/api/stand/topology
```