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
info "Запускаю контейнеры..."
$COMPOSE_CMD up -d
$COMPOSE_CMD ps

# Wait for mongod instances
wait_for_service configSvr 27017
wait_for_service mongodb1 27018
wait_for_service mongodb2 27019
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
info "Инициализация shard1 (mongodb1)..."
if [ "$(run_mongo_eval mongodb1 27018 "try{rs.status().ok}catch(e){0}")" != "1" ]; then
  $COMPOSE_CMD exec -T mongodb1 mongosh --port 27018 <<'EOF'
rs.initiate({
  _id: "shard1",
  members: [{ _id: 0, host: "mongodb1:27018" }]
})
rs.status().ok
EOF
else
  info "shard1 уже инициализирован."
fi

# 4) Init shard2 replica set
info "Инициализация shard2 (mongodb2)..."
if [ "$(run_mongo_eval mongodb2 27019 "try{rs.status().ok}catch(e){0}")" != "1" ]; then
  $COMPOSE_CMD exec -T mongodb2 mongosh --port 27019 <<'EOF'
rs.initiate({
  _id: "shard2",
  members: [{ _id: 0, host: "mongodb2:27019" }]
})
rs.status().ok
EOF
else
  info "shard2 уже инициализирован."
fi

# 5) Add shards to mongos (idempotent)
info "Добавляю шарды в mongos..."
sh_status=$($COMPOSE_CMD exec -T mongosRouter mongosh --port 27020 --quiet --eval "sh.status()")
if echo "$sh_status" | grep -q "shard1" && echo "$sh_status" | grep -q "shard2"; then
  info "Оба шарда уже добавлены."
else
  $COMPOSE_CMD exec -T mongosRouter mongosh --port 27020 <<'EOF'
sh.addShard("shard1/mongodb1:27018")
sh.addShard("shard2/mongodb2:27019")
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

info "Готово — шардирование настроено и проверено."

# EOF
