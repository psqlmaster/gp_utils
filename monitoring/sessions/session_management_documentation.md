# Документация по управлению сессиями в ArenadataDB (Greenplum 6, PostgreSQL 9.4)

Этот документ описывает реализацию управления таймаутами запросов и простаивающих сессий в Greenplum 6 (на базе PostgreSQL 9.4). Включает конфигурации, функции и таблицы для ограничения времени выполнения запросов, завершения простаивающих сессий, мониторинга прерванных запросов и управления индивидуальными таймаутами ролей.

## 1. Обзор

Решение предоставляет следующие возможности:
- Ограничение времени выполнения запросов с помощью параметра `statement_timeout`.
- Завершение простаивающих сессий с настраиваемыми таймаутами.
- Мониторинг запросов, прерванных из-за `statement_timeout`.
- Хранение и управление индивидуальными настройками таймаутов для ролей.

**Примечание:**
- Параметр `statement_timeout` ограничивает время выполнения отдельных запросов, а не всей сессии. Сессия остаётся активной после прерывания запроса.
- Параметр `idle_in_transaction_session_timeout` отсутствует в PostgreSQL 9.4 (добавлен в 9.6). Для завершения простаивающих сессий используется кастомная функция `adm.terminate_inactive_connections_2`.

## 2. Настройка таймаута запросов

### 2.1 Установка statement_timeout

Для ограничения времени выполнения запросов для конкретной роли используется команда `ALTER ROLE`.

```sql
ALTER ROLE test_role SET statement_timeout = '2h'; -- Ограничивает выполнение запросов до 2 часов
```

Для сброса настройки `statement_timeout`:

```sql
ALTER ROLE test_role RESET statement_timeout;
```

**Примечание:** Если запрос превышает заданное время, он прерывается с ошибкой `canceling statement due to statement timeout`, но сессия остаётся активной.

## 3. Мониторинг прерванных запросов

### 3.1 Функция: adm.get_aborted_queries_with_statement_timeout_by_days

Функция возвращает список запросов, прерванных из-за превышения `statement_timeout`, за указанное количество дней (максимум 10 дней).

```sql
CREATE OR REPLACE FUNCTION
adm.get_aborted_queries_with_statement_timeout_by_days (
    days_limit int
)
RETURNS TABLE (
    role_name text,
    config_timeout text,
    duration_query interval,
    start_query timestamp,
    finish_query timestamp,
    DATABASE TEXT,
    host text,
    port int,
    session text,
    query text
)
AS $$
BEGIN
    IF days_limit > 10 THEN
        RAISE EXCEPTION 'Ошибка: превышен лимит дней. Максимум разрешено 10 дней. Указано: %', days_limit;
    END IF;
    RETURN QUERY
    SELECT
        r.rolname::text AS role_name,
        r.rolconfig::text,
        (l.logtime - l.logsessiontime)::interval AS duration_query,
        l.logsessiontime::TIMESTAMP AS start_query,
        l.logtime::TIMESTAMP AS finish_query,
        l.logdatabase::text AS database,
        l.loghost::text AS host,
        l.logport::int AS port,
        l.logsession::text AS session,
        l.logdebug::text AS query
    FROM
        pg_roles r
    RIGHT JOIN gp_toolkit.gp_log_database l ON r.rolname = l.loguser
    WHERE
        r.rolconfig IS NOT NULL
        AND l.logtime > NOW() - (days_limit || ' days')::interval
        AND l.logmessage = 'canceling statement due to statement timeout'
    ORDER BY
        l.logtime DESC;
END;
$$
LANGUAGE plpgsql;

COMMENT ON FUNCTION adm.get_aborted_queries_with_statement_timeout_by_days(INT) IS
'Функция возвращает список отменённых запросов по причине "statement_timeout" за указанное количество дней (максимум 10).
Автор: Alexander Shcheglov, esqlmaster (Telegram), 2025
Аргументы:
- days_limit (INT): количество дней для выборки (максимум 10)
Ограничения:
- Если указано более 10 дней, будет выведено предупреждение.';
```

**Примеры использования:**

```sql
SELECT * FROM adm.get_aborted_queries_with_statement_timeout_by_days(5); -- Запросы за последние 5 дней
SELECT * FROM adm.get_aborted_queries_with_statement_timeout_by_days(12); -- Превышено, предупреждение
```

## 4. Управление таймаутами простаивающих сессий

### 4.1 Таблица: adm.role_timeout_limits

Таблица хранит индивидуальные настройки таймаутов для ролей в секундах.

```sql
CREATE TABLE IF NOT EXISTS adm.role_timeout_limits (
    rolname name PRIMARY KEY,
    timeout_seconds int4 NOT NULL CHECK (timeout_seconds > 0),
    created_at timestamp DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT valid_timeout CHECK (timeout_seconds > 0)
);

COMMENT ON TABLE adm.role_timeout_limits IS 'Хранит индивидуальные лимиты таймаутов для ролей в секундах. Переопределяет стандартные таймауты в функции terminate_inactive_connections.';
```

### 4.2 Триггер для обновления updated_at

Триггер автоматически обновляет поле `updated_at` при изменении записи в таблице.

```sql
CREATE OR REPLACE FUNCTION adm.update_role_timeout_timestamp()
    RETURNS TRIGGER
    AS $$
BEGIN
    NEW.updated_at = CURRENT_TIMESTAMP;
    RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER update_role_timeout_timestamp
    BEFORE UPDATE
    ON adm.role_timeout_limits
    FOR EACH ROW
    EXECUTE FUNCTION adm.update_role_timeout_timestamp();
```

## 5. Завершение простаивающих сессий

### 5.1 Функция: adm.terminate_inactive_connections_2

Функция завершает простаивающие сессии на основе заданных таймаутов.

```sql
CREATE OR REPLACE FUNCTION gpadmin.terminate_inactive_connections_2 (
    p_login varchar,
    p_timeout int4
)
RETURNS TABLE (
    log_timestamp timestamp,
    pid int4,
    usename name,
    datname name,
    application_name text,
    client_addr inet,
    state text,
    terminated boolean,
    timeout varchar
)
AS $$
BEGIN
    RETURN QUERY
    SELECT
        current_timestamp AS log_timestamp,
        p.pid,
        p.usename,
        p.datname,
        p.application_name,
        p.client_addr,
        p.state,
        pg_terminate_backend(p.pid) AS terminated,
        ('session timeout' || COALESCE(
            (SELECT timeout_seconds::varchar
             FROM adm.role_timeout_limits
             WHERE rolname = p.usename),
             CASE
                 WHEN p.usename IN (
                     SELECT u.usename
                     FROM pg_user u
                     JOIN pg_group g ON u.usesysid = ANY (g.grolist)
                     WHERE g.groname IN ('ldap_users', 'sync_ldap_users')
                 ) THEN p_timeout::varchar
                 ELSE '172800'
             END
        ) || ' seconds')::varchar AS timeout
    FROM pg_stat_activity p
    WHERE
        p.state IN ('idle', 'idle in transaction', 'idle in transaction (aborted)', 'disabled')
        AND p.usename LIKE p_login
        AND CURRENT_TIMESTAMP - p.state_change > INTERVAL '1 second' * COALESCE(
            (SELECT timeout_seconds
             FROM adm.role_timeout_limits
             WHERE rolname = p.usename),
             CASE
                 WHEN p.usename IN (
                     SELECT u.usename
                     FROM pg_user u
                     JOIN pg_group g ON u.usesysid = ANY (g.grolist)
                     WHERE g.groname IN ('ldap_users', 'sync_ldap_users')
                 ) THEN p_timeout
                 ELSE 172800
             END
        )
        AND p.application_name != 'gp_reserved_gpdiskquota'
        AND p.usename NOT IN ('gpadmin', 'adcc');
END;
$$
LANGUAGE plpgsql
EXECUTE ON ANY;

COMMENT ON FUNCTION gpadmin.terminate_inactive_connections_2(varchar, int4) IS
'Version: 2.0.0 Terminates idle database sessions based on timeout thresholds.
Parameters: p_login (varchar) - username pattern (''%'' for all), p_timeout (int4) - timeout in seconds for ldap_users group (e.g., 1800 = 30 minutes).
Behavior:
- Checks adm.role_timeout_limits for role-specific timeouts (in seconds).
- If no custom timeout, uses p_timeout for ldap_users group, 172800 seconds (48 hours) for others.
- Excludes gpadmin, adcc, and ''gp_reserved_gpdiskquota'' sessions.
- Targets idle, idle in transaction, idle in transaction (aborted), and disabled states.
Crontab recommendation: not more frequent than */3 * * * * (every 3 minutes) to avoid excessive load.
Example:
SELECT adm.terminate_inactive_connections_2(''%'', 1800);
To set custom timeout for a role:
INSERT INTO adm.role_timeout_limits (rolname, timeout_seconds) VALUES
    (''my_role'', 10800); -- 3 hours';
```

**Примеры использования:**

```sql
SELECT adm.terminate_inactive_connections_2('%', 1800); -- Завершает простаивающие сессии для всех пользователей
```

```sql
INSERT INTO adm.role_timeout_limits (rolname, timeout_seconds) VALUES
    ('my_role', 10800); -- 3 часа
```

**Пример вызова:**

```sql
SELECT adm.terminate_inactive_connections_2('%', 1800); -- Завершает простаивающие сессии для всех пользователей с таймаутом 30 минут для ldap_users, sync_ldap_users и 48 часов для остальных
```

## 6. Ограничения и рекомендации

### Ограничение statement_timeout:
- Применяется только к запросам, а не к сессиям.
- Не завершает сессии в состоянии `active`. Для этого требуется дополнительная логика.

### Ограничение функции adm.terminate_inactive_connections_2:
- Завершает только простаивающие сессии (`idle`, `idle in transaction`, `idle in transaction (aborted)`, `disabled`).
- Не влияет на сессии в состоянии `active`.

### Рекомендации по crontab:
- Запуск функции `adm.terminate_inactive_connections_2` не чаще, чем каждые 3 минуты (`*/3 * * * *`), чтобы избежать избыточной нагрузки на систему.

### Мониторинг:
- Регулярно проверяйте логи с помощью функции `adm.get_aborted_queries_with_statement_timeout_by_days`, чтобы выявлять запросы, прерываемые из-за таймаутов.


## 7. Пример полного использования

Настройте таймаут запросов для роли (прервёт активные запросы):

```sql
ALTER ROLE test_role SET statement_timeout = '5h';
```

Добавьте индивидуальный таймаут для простаивающих сессий:

```sql
INSERT INTO adm.role_timeout_limits (rolname, timeout_seconds) VALUES
    ('test_role', 10800); -- 3 часа
```

Проверьте прерванные запросы за последние 5 дней по `statement_timeout`:

```sql
SELECT * FROM adm.get_aborted_queries_with_statement_timeout_by_days(5);
```

Настройте задачу в crontab для завершения простаивающих сессий:

```sh
*/3 * * * * . "$PROFILE" && "$HOME"/ori_works/terminate_inactive_connections.sh
```

Скрипт `terminate_inactive_connections.sh`:

```sh
#!/bin/bash
LOCKFILE=$(dirname $0)/locks/$(basename $0 .sh).lock
flock -n "$LOCKFILE" /usr/lib/gpdb/bin/psql -U gpadmin -d adb -c "select gpadmin.terminate_inactive_connections_2('%', 1800)" | grep Session >> "$MASTER_DATA_DIRECTORY/pg_log/terminate_backend_by_function-$(date +%Y-%m-%d).log" 2>&1
```

Проверьте прерванные сессии за текущий месяц со статусом: `idle`, `idle in transaction`, `idle in transaction (aborted)`, `disabled`:

```sh
grep -in srv-ndp-v-nsi-adb $MASTER_DATA_DIRECTORY/pg_log/terminate_backend_by_function-2025-06-*.log
```

**Пример вывода:**

```
/data/master/gpseg-1/pg_log/terminate_backend_by_function-2025-06-01.log:1:2025-06-01 09:00:01+03: Session with pid=33748; user=srv-ndp-v-nsi-adb; database=adb; application=PostgreSQL JDBC Driver; IP=10.177.16.102; state=idle; terminated: true
/data/master/gpseg-1/pg_log/terminate_backend_by_function-2025-06-07.log:5:2025-06-07 13:00:02+03: Session with pid=18493; user=srv-ndp-v-nsi-adb; database=adb; application=PostgreSQL JDBC Driver; IP=10.177.16.102; state=idle; terminated: true
```

