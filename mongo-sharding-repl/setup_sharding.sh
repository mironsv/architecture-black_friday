#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

COMPOSE_CMD="docker compose"
if ! $COMPOSE_CMD version >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
fi

RETRY_LIMIT=30
SLEEP_SECONDS=2

info() { echo -e "\n✅ $*"; }
warn() { echo -e "\n⚠️ $*"; }

wait_for_service() {
  local svc=$1 port=$2
  local i=0
  info "Ожидаю готовности $svc (порт $port)..."
  until $COMPOSE_CMD exec -T "$svc" mongosh --port "$port" --quiet --eval "db.adminCommand({ping:1})" >/dev/null 2>&1; do
    i=$((i+1))
    if [ "$i" -ge "$RETRY_LIMIT" ]; then
      warn "Сервис $svc не отвечает после $((RETRY_LIMIT*SLEEP_SECONDS)) секунд."
      return 1
    fi
    sleep $SLEEP_SECONDS
  done
  info "$svc готов!"
}

run_mongo_eval() {
  local svc=$1 port=$2 eval_js="$3"
  $COMPOSE_CMD exec -T "$svc" mongosh --port "$port" --quiet --eval "$eval_js"
}

# 1) up

# Проверка репликации (использует контейнерный клиент)
check_replication() {
  run_mongo_eval configSvr 27017 "try{rs.status()}catch(e){print(e);}"
  run_mongo_eval mongodb1-1 27021 "try{rs.status()}catch(e){print(e);}"
  run_mongo_eval mongodb2-1 27024 "try{rs.status()}catch(e){print(e);}"
}

info "Запускаю контейнеры..."
$COMPOSE_CMD up -d
$COMPOSE_CMD ps

# Wait for mongod instances
wait_for_service configSvr 27017
wait_for_service mongodb1-1 27021
wait_for_service mongodb1-2 27022
wait_for_service mongodb1-3 27023
wait_for_service mongodb2-1 27024
wait_for_service mongodb2-2 27025
wait_for_service mongodb2-3 27026
wait_for_service mongosRouter 27020

# 2) Init config server replica set (idempotent)
info "Инициализация config server..."
if [ "$(run_mongo_eval configSvr 27017 "try{rs.status().ok}catch(e){0}")" != "1" ]; then
  $COMPOSE_CMD exec -T configSvr mongosh --port 27017 <<'EOF'
rs.initiate({
  _id: "config_server",
  configsvr: true,
  members: [{ _id: 0, host: "configSvr:27017" }]
})
rs.status().ok
EOF
else
  info "config server уже инициализирован."
fi

# 3) Init shard1 replica set
info "Инициализация shard1 (mongodb1-1 mongodb1-2 mongodb1-3)..."
if [ "$(run_mongo_eval mongodb1-1 27021 "try{rs.status().ok}catch(e){0}")" != "1" ]; then
  $COMPOSE_CMD exec -T mongodb1-1 mongosh --port 27021 <<'EOF'
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
else
  info "shard1 уже инициализирован."
fi

# 4) Init shard2 replica set
info "Инициализация shard2 (mongodb2-1 mongodb2-2 mongodb2-3)..."
if [ "$(run_mongo_eval mongodb2-1 27024 "try{rs.status().ok}catch(e){0}")" != "1" ]; then
  $COMPOSE_CMD exec -T mongodb2-1 mongosh --port 27024 <<'EOF'
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
else
  info "shard2 уже инициализирован."
fi

# 5) Add shards to mongos (idempotent)
info "Добавляю шарды в mongos..."
sh_status=$($COMPOSE_CMD exec -T mongosRouter mongosh --port 27020 --quiet --eval "sh.status()")
if echo "$sh_status" | grep -q "shard1ReplSet" && echo "$sh_status" | grep -q "shard2ReplSet"; then
  info "Оба шарда уже добавлены."
else
  $COMPOSE_CMD exec -T mongosRouter mongosh --port 27020 <<'EOF'
sh.addShard("shard1ReplSet/mongodb1-1:27021,mongodb1-2:27022,mongodb1-3:27023")
sh.addShard("shard2ReplSet/mongodb2-1:27024,mongodb2-2:27025,mongodb2-3:27026")
sh.status()
EOF
fi

# 6) Enable sharding for collection somedb.helloDoc and shard by name (idempotent)
info "Настраиваю шардирование коллекции somedb.helloDoc..."
# check if collection already sharded
is_sharded=$($COMPOSE_CMD exec -T mongosRouter mongosh --port 27020 --quiet --eval "sh.status()" | grep -A2 "Sharding on DB" || true)
# We will try to enable sharding if necessary
$COMPOSE_CMD exec -T mongosRouter mongosh --port 27020 <<'EOF'
use somedb
// очищаем коллекцию (безопасно — если её нет, ошибок нет)
db.helloDoc.drop()
sh.enableSharding("somedb")
// shard collection по name хешированием
try { sh.shardCollection("somedb.helloDoc", { "name": "hashed" }) } catch(e) { }
sh.status()
EOF

# 7) Fill collection (only if not already filled)
# Получаем число напрямую без `use somedb` чтобы избежать сообщения "switched to db somedb;"
count=$($COMPOSE_CMD exec -T mongosRouter mongosh --port 27020 --quiet --eval "db.getSiblingDB('somedb').helloDoc.countDocuments()")
if [ -z "$count" ] || [ "$count" -lt 1000 ]; then
  info "Заполняю коллекцию 1000 документами..."
  $COMPOSE_CMD exec -T mongosRouter mongosh --port 27020 <<'EOF'
use somedb
for (let i = 0; i < 1000; i++) {
  db.helloDoc.insertOne({age:i, name:"ly"+i})
}
print('count=' + db.helloDoc.countDocuments())
EOF
else
  info "Коллекция уже содержит $count документов — пропускаю вставку."
fi

# 8) Show distribution and total
info "Показываю распределение по шардам и общее количество..."
$COMPOSE_CMD exec -T mongosRouter mongosh --port 27020 <<'EOF'
use somedb
print('\n--- Shard distribution ---')
printjson(db.helloDoc.getShardDistribution())
print('\n--- Total count ---')
print('count=' + db.helloDoc.countDocuments())
EOF

info "Проверяю статус репликаций..."
check_replication

info "Готово — репликация и шардирование настроены и проверены."

# EOF
