# TASK 2

## Mongo Sharding

Сервисы:

- `configSvr` — config server (replica set `config_server`, порт `27017`)
- `mongodb1-1`, `mongodb1-2`, `mongodb1-3` — shard 1 (replica set `shard1ReplSet`, порты `27021`, `27022`, `27023`)
- `mongodb2-1`, `mongodb2-2`, `mongodb2-3` — shard 2 (replica set `shard2ReplSet`, порты `27024`, `27025`, `27026`)
- `mongosRouter` — router (порт `27020`)
- `pymongo_api` — приложение, подключается к `mongosRouter`

---

## Как скриптом проверить что шардирование Mongo работает

```bash
./mongo-sharding-repl/setup_sharding.sh
```


## Как вручную пошагово проверить что шардирование Mongo работает

### 1.Запуск

```bash
cd ./mongo-sharding-repl
docker compose up -d
docker compose ps
```

### 2.Инициализация config_server

```bash
docker compose exec -T configSvr mongosh --port 27017  <<'EOF'
rs.initiate({
  _id: "config_server",
  configsvr: true,
  members: [{ _id: 0, host: "configSvr:27017" }]
})
rs.status().ok
EOF
```

### 3.Инициализация replica set для шарда 1 (3 ноды)

```bash
docker compose exec -T mongodb1-1 mongosh --port 27021  <<'EOF'
rs.initiate({
  _id: "shard1ReplSet",
  members: [
    { _id: 0, host: "mongodb1-1:27021" },
    { _id: 1, host: "mongodb1-2:27022" },
    { _id: 2, host: "mongodb1-3:27023" }
  ]
})
rs.status().ok
EOF
```

### 4.Инициализация replica set для шарда 2 (3 ноды)

```bash
docker compose exec -T mongodb2-1 mongosh --port 27024  <<'EOF'
rs.initiate({
  _id: "shard2ReplSet",
  members: [
    { _id: 0, host: "mongodb2-1:27024" },
    { _id: 1, host: "mongodb2-2:27025" },
    { _id: 2, host: "mongodb2-3:27026" }
  ]
})
rs.status().ok
EOF
```

### 5.Инициализируем роутер и добавляем 2 шарда в кластер

```bash
docker compose exec -T mongosRouter mongosh --port 27020  <<'EOF'
sh.addShard("shard1ReplSet/mongodb1-1:27021,mongodb1-2:27022,mongodb1-3:27023")
sh.addShard("shard2ReplSet/mongodb2-1:27024,mongodb2-2:27025,mongodb2-3:27026")
sh.status()
EOF
```

### 6.Включаем шардирование коллекции helloDoc

```bash
docker compose exec -T mongosRouter mongosh --port 27020  <<'EOF'
use somedb

// очищаем коллекцию
db.helloDoc.drop()

// включаем шардирование базы
sh.enableSharding("somedb")

// шардируем коллекцию по name
sh.shardCollection("somedb.helloDoc", { "name": "hashed" })

// проверка: коллекция sharded
sh.status()
EOF
```

### 7.Заполняем коллекцию

```bash
docker compose exec -T mongosRouter mongosh --port 27020  <<'EOF'
use somedb
for (let i = 0; i < 1000; i++) {
  db.helloDoc.insertOne({age:i, name:"ly"+i})
}
db.helloDoc.countDocuments()
EOF
```

### 8.1.Как распределились данные по шардам

```bash
docker compose exec -T mongosRouter mongosh --port 27020  <<'EOF'
use somedb
db.helloDoc.getShardDistribution()
EOF
```

### 8.2.Проверка общего количества документов

```bash
docker compose exec -T mongosRouter mongosh --port 27020  <<'EOF'
use somedb
db.helloDoc.countDocuments()
EOF
```

### 9. Проверка репликации (используя один из узлов реплики):

```bash
docker compose exec -T configSvr mongosh --port 27017 --eval 'rs.status()'
```
```bash
docker compose exec -T mongodb1-1 mongosh --port 27021 --eval 'rs.status()'
```
```bash
docker compose exec -T mongodb2-1 mongosh --port 27024 --eval 'rs.status()'
```