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
CREATE OR REPLACE FUNCTION adm.get_aborted_queries_with_statement_timeout_by_days (
    days_limit int
)
RETURNS TABLE (
    role_name text,
    config_timeout text[],
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
        RAISE EXCEPTION 'Ошибка: Превышен лимит дней. Максимум разрешено 10 дней. Указано: %', days_limit;
    END IF;
    RETURN QUERY
    SELECT
        r.rolname::text AS role_name,
        r.rolconfig::text[],
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
Автор: Alexander Shcheglov, @sqlmaster (Telegram), 2025
Аргументы:
- days_limit (INT): количество дней для выборки (максимум 10)
Ограничения:
- Если указано более 10 дней, будет выведено предупреждение.';
```

**Примеры использования:**

```sql
SELECT * FROM adm.get_aborted_queries_with_statement_timeout_by_days(5); -- последние 5 дней
SELECT * FROM adm.get_aborted_queries_with_statement_timeout_by_days(12); -- превышено, предупреждение
```

**Пример использования:**

```sql
SELECT * FROM adm.get_aborted_queries_with_statement_timeout_by_days(5); -- Запросы за последние 5 дней
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
    EXECUTE PROCEDURE adm.update_role_timeout_timestamp();
```

**Пример добавления записи:**

```sql
INSERT INTO adm.role_timeout_limits (rolname, timeout_seconds) VALUES ('my_role', 10800); -- 3 часа
```

**Пример обновления записи:**

```sql
UPDATE adm.role_timeout_limits SET timeout_seconds = 7200 WHERE rolname = 'my_role'; -- 2 часа
```

**Проверка содержимого таблицы:**

```sql
SELECT * FROM adm.role_timeout_limits;
```

**Пример вывода:**

```
rolname       | timeout_seconds | created_at              | updated_at              |
--------------+-----------------+------------------------+------------------------+
test_role_1   |           10800 | 2025-06-10 13:26:29.521 | 2025-06-10 13:26:29.521 |
test_role_2   |           43200 | 2025-06-11 09:34:14.438 | 2025-06-11 09:34:14.438 |
```

## 5. Завершение простаивающих сессий

### 5.1 Функция: adm.terminate_inactive_connections_2

Функция завершает простаивающие сессии в состояниях `idle`, `idle in transaction`, `idle in transaction (aborted)` или `disabled` на основе заданных таймаутов.

```sql
CREATE OR REPLACE FUNCTION gpadmin.terminate_inactive_connections_2(p_login varchar, p_timeout int4)
    RETURNS SETOF text
    LANGUAGE sql
    VOLATILE
AS $$
    -- Version: 2.0.0
    SELECT
        FORMAT(
            '%s: Session with pid=%s; user=%s; database=%s; application=%s; IP=%s; state=%s; terminated: %s',
            current_timestamp(0),
            pid,
            usename,
            datname,
            application_name,
            client_addr,
            state,
            pg_terminate_backend(
                pid,
                'session timeout ' || COALESCE(
                    (
                        SELECT timeout_seconds::varchar
                        FROM adm.role_timeout_limits
                        WHERE rolname = usename
                    ),
                    CASE
                        WHEN usename IN (
                            SELECT u.usename
                            FROM pg_user u
                            JOIN pg_group g ON u.usesysid = ANY(g.grolist)
                            WHERE g.groname in ('ldap_users', 'sync_ldap_users')
                        ) THEN p_timeout::varchar
                        ELSE '172800'
                    END
                ) || ' seconds'
            )::varchar
        )
    FROM pg_stat_activity
    WHERE
        state IN (
            'idle',
            'idle in transaction',
            'idle in transaction (aborted)',
            'disabled'
        )
        AND usename LIKE p_login
        AND CURRENT_TIMESTAMP - state_change > INTERVAL '1 second' * COALESCE(
            (
                SELECT timeout_seconds
                FROM adm.role_timeout_limits
                WHERE rolname = usename
            ),
            CASE
                WHEN usename IN (
                    SELECT u.usename
                    FROM pg_user u
                    JOIN pg_group g ON u.usesysid = ANY(g.grolist)
                    WHERE g.groname in ('ldap_users', 'sync_ldap_users')
                ) THEN p_timeout
                ELSE 172800
            END
        )
        AND application_name != 'gp_reserved_gpdiskquota'
        AND usename NOT IN ('gpadmin', 'adcc');
$$
EXECUTE ON ANY;

COMMENT ON FUNCTION gpadmin.terminate_inactive_connections_2(varchar, int4) IS
'Version: 2.0.0 Terminates idle DATABASE sessions based ON timeout thresholds.
Parameters: p_login (varchar) - username pattern (''%'' FOR ALL), p_timeout (int4) - timeout IN seconds FOR ldap_users GROUP (e.g., 1800 = 30 minutes).
Behavior:
- Checks adm.role_timeout_limits for role-specific timeouts (in seconds).
- If no custom timeout, uses p_timeout for ldap_users group, 172800 seconds (48 hours) for others.
- Excludes gpadmin, adcc, and ''gp_reserved_gpdiskquota'' sessions.
- Targets idle, idle in transaction, idle in transaction (aborted), and disabled states.
Crontab recommendation: not more frequent than */3 * * * * (every 3 minutes) to avoid excessive load.
Example:
SELECT adm.terminate_inactive_connections_2(''%'', 1800);
To set custom timeout for a role:
INSERT INTO adm.role_timeout_limits (rolname, timeout_seconds) VALUES (''my_role'', 10800); -- 3 hours, 7200 - 2 hours';
```

Завершает простаивающие сессии базы данных на основе заданных таймаутов.  
**Параметры:**
- `p_login (varchar)`: шаблон имени пользователя (`'%'` для всех).
- `p_timeout (int4)`: таймаут в секундах для группы `ldap_users` (например, 1800 = 30 минут).

**Поведение:**
- Проверяет таблицу `adm.role_timeout_limits` для индивидуальных таймаутов (в секундах).
- Если индивидуальный таймаут отсутствует, использует `p_timeout` для группы `ldap_users` или 172800 секунд (48 часов) для остальных.
- Исключает пользователей `gpadmin`, `adcc` и сессии с `application_name` `'gp_reserved_gpdiskquota'`.
- Завершает сессии в состояниях `idle`, `idle in transaction`, `idle in transaction (aborted)`, `disabled`.

**Рекомендация по crontab:** запуск не чаще чем `*/3 * * * *` (каждые 3 минуты) во избежание избыточной нагрузки.

**Пример:**

```sql
SELECT adm.terminate_inactive_connections_2('%', 1800);
```

**Для установки индивидуального таймаута для роли:**

```sql
INSERT INTO adm.role_timeout_limits (rolname, timeout_seconds) VALUES ('my_role', 10800); -- 3 часа
```

**Примечание:** В таблицу `adm.role_timeout_limits` можно помещать роли, для которых нужно увеличить время таймаута, несмотря на стандартные 30 минут или 48 часов. Для ролей, указанных в таблице, действует ограничение `timeout_seconds` из этой таблицы.

**Пример вызова:**

```sql
SELECT adm.terminate_inactive_connections_2('%', 1800); -- Завершает простаивающие сессии для всех пользователей с таймаутом 30 минут для ldap_users, sync_ldap_users и (48 часов) для остальных, для ролей из таблицы adm.role_timeout_limits действуют таймауты из таблицы
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
INSERT INTO adm.role_timeout_limits (rolname, timeout_seconds) VALUES ('test_role', 10800); -- 3 часа
```

Проверьте прерванные запросы за последние 5 дней по `statement_timeout`:

```sql
SELECT * FROM adm.get_aborted_queries_with_statement_timeout_by_days(5);
```

Настройте задачу в crontab для завершения простаивающих сессий:

```sh
*/3 * * * * . "$PROFILE" && "$HOME"/adm/terminate_inactive_connections.sh
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
