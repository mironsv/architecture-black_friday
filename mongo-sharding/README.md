# TASK 2

## Mongo Sharding

Сервисы:

- `configSvr` — config server (replica set `configReplSet`, порт `27017`)
- `mongodb1` — shard 1 (1 нода, порт `27018`)
- `mongodb2` — shard 2 (1 нода, порт `27019`)
- `mongosRouter` — router (порт `27020`)
- `pymongo_api` — приложение, подключается к `mongosRouter`

---

## Как скриптом проверить что шардирование Mongo работает

```bash
./mongo-sharding/setup_sharding.sh
```


## Как вручную пошагово проверить что шардирование Mongo работает

### 1.Запуск

```bash
cd ./mongo-sharding
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

### 3.Инициализация replica set для шарда mongodb1

```bash
docker compose exec -T mongodb1 mongosh --port 27018  <<'EOF'
rs.initiate({
  _id: "shard1",
  members: [{ _id: 0, host: "mongodb1:27018" }]
})
rs.status().ok
EOF
```

### 4.Инициализация replica set для шарда mongodb2

```bash
docker compose exec -T mongodb2 mongosh --port 27019  <<'EOF'
rs.initiate({
  _id: "shard2",
  members: [{ _id: 0, host: "mongodb2:27019" }]
})
rs.status().ok
EOF
```

### 5.Инициализируем роутер и добавляем 2 шарда в кластер

```bash
docker compose exec -T mongosRouter mongosh --port 27020  <<'EOF'
sh.addShard("shard1/mongodb1:27018")
sh.addShard("shard2/mongodb2:27019")
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