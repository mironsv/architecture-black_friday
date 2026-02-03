# TASK 2

## Mongo Sharding

Сервисы:

- `configsvr1`, `configsvr2`, `configsvr3` — config server (replica set `configReplSet`, порт `27017`)
- `mongodb1-1`, `mongodb1-2`, `mongodb1-3` — shard 1 (replica set `shard1ReplSet`, порты `27021`, `27022`, `27023`)
- `mongodb2-1`, `mongodb2-2`, `mongodb2-3` — shard 2 (replica set `shard2ReplSet`, порты `27024`, `27025`, `27026`)
- `mongosRouter` — router (порт `27020`)
- `pymongo_api` — приложение, подключается к `mongosRouter`

---

## Как проверить что кеширование Redis работает

### 1. запустить скрипт, который стартует все сервисы и наполняет Mongo.
```bash
cd mongo-sharding-repl
./setup_sharding.sh
```
Дождаться сообщения:
✅ Готово — репликация и шардирование настроены и проверены.

### 2. запустить python, который измеряет время запросов
```bash
python3 measure_time.py
```

Запрос 1 выполняется намного дольше последующих запросов.

P.S.
скриншот результата сохранён в файле sharding-repl-cache/Task4 Caching.png