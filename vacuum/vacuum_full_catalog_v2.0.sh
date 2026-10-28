#!/bin/bash
#########################################################################################
# ОПИСАНИЕ: Скрипт экстренного обслуживания системного каталога Greenplum 6 (DB: adb)
# 
#   Выявить (bloat) системных таблиц с помощью запроса select_bloat_system.sql
#   Это приводит к деградации планировщика (slow planning) и избыточному I/O на мастере.
#
# ЧТО ДЕЛАЕТ СКРИПТ:
#   1. Изолирует базу: устанавливает CONNECTION LIMIT 0 и завершает все активные сессии.
#   2. Этап 1: Выполняет VACUUM FULL ANALYZE для локальных системных таблиц (по убыванию размера).
#   3. Этап 2: Выполняет VACUUM FULL ANALYZE для глобальных (Shared) таблиц кластера.
#   4. Этап 3: Выполняет REINDEX SYSTEM для исправления раздутых индексов каталога.
#   5. Финализация: Возвращает исходный лимит подключений.
#
# ВНИМАНИЕ (CRITICAL):
#   - ТРЕБУЕТСЯ ПОЛНЫЙ DOWNTIME: База будет недоступна для любых операций.
#   - МЕСТО НА ДИСКЕ: На мастере должно быть свободно НЕ МЕНЕЕ 30-40 ГБ (размер 
#     крупнейшей таблицы + запас), так как VACUUM FULL создает временную копию файла.
#   - ВРЕМЯ: Для таблицы pg_attribute размером 27 ГБ процесс может занять 1-3 часа.
#
# ЗАПУСК:
#   chmod +x vacuum_full_catalog.sh
#   nohup ./vacuum_full_catalog.sh &
#########################################################################################
source /home/gpadmin/.bashrc
DBNAME='adb'
LOGFILE="/home/gpadmin/vacuum_full_catalog_$(date +%Y%m%d).log"
echo "======= Starting FULL MAINTENANCE for $DBNAME at $(date '+%d-%m-%Y %H:%M:%S') =======" >> $LOGFILE
con_limit=$(psql -AtX -d postgres -c "SELECT datconnlimit FROM pg_database WHERE datname = '${DBNAME}'")
psql -X -d postgres -c "ALTER DATABASE ${DBNAME} CONNECTION LIMIT 0" >> $LOGFILE 2>&1
# Завершаем сессии
echo "Terminating active connections to $DBNAME..." >> $LOGFILE
sql_kill="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '${DBNAME}' AND pid <> pg_backend_pid()"
psql -d postgres -tX -c "${sql_kill}" >> $LOGFILE 2>&1
run_vacuum() {
    local tbl=$1
    echo "Vacuuming: $tbl at $(date '+%H:%M:%S')" >> $LOGFILE
    # Устанавливаем таймаут через переменную окружения PGOPTIONS
    PGOPTIONS="-c statement_timeout=0" psql -aX -d ${DBNAME} -c "VACUUM FULL ANALYZE $tbl" >> $LOGFILE 2>&1
}
# --- ЭТАП 1: ЛОКАЛЬНЫЕ ТАБЛИЦЫ КАТАЛОГА ---
echo "--- Stage 1: Local Catalog Tables ---" >> $LOGFILE
tables=$(psql -AtX -d ${DBNAME} -c "
    SELECT n.nspname || '.' || c.relname 
    FROM pg_class c 
    JOIN pg_namespace n ON n.oid = c.relnamespace 
    WHERE n.nspname = 'pg_catalog' 
      AND c.relkind = 'r' 
      AND c.relisshared = false 
    ORDER BY pg_relation_size(c.oid) DESC")
for table_name in $tables
do
    run_vacuum "$table_name"
done
# --- ЭТАП 2: ОБЩИЕ ТАБЛИЦЫ КЛАСТЕРА (SHARED) ---
echo "--- Stage 2: Shared Catalog Tables ---" >> $LOGFILE
shared_tables=$(psql -AtX -d ${DBNAME} -c "
    SELECT n.nspname || '.' || c.relname 
    FROM pg_class c 
    JOIN pg_namespace n ON n.oid = c.relnamespace 
    WHERE c.relisshared = true 
      AND c.relkind = 'r' 
      AND c.relname <> 'pg_database'
    ORDER BY pg_relation_size(c.oid) DESC")

for table_name in $shared_tables
do
    run_vacuum "$table_name"
done
# --- ЭТАП 3: РЕИНДЕКСАЦИЯ И СТАТИСТИКА ---
echo "--- Stage 3: Reindex and Finalize ---" >> $LOGFILE
echo "Starting system reindex at $(date '+%H:%M:%S')" >> $LOGFILE
reindexdb -s -d ${DBNAME} >> $LOGFILE 2>&1
# Возвращаем лимит подключений
psql -X -d postgres -c "ALTER DATABASE ${DBNAME} CONNECTION LIMIT $con_limit" >> $LOGFILE 2>&1
echo "======= Maintenance Finished at $(date '+%d-%m-%Y %H:%M:%S') =======" >> $LOGFILE
