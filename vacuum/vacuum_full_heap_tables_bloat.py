#!/usr/bin/python2
# -*- coding: utf-8 -*-
"""
vacuum_full_heap_tables_bloat.py v1.0.0
Author: Alexander Shcheglov, @sqlmaster (Telegram)
Purpose: Perform VACUUM FULL on bloated tables in Greenplum database in parallel 6 processes.

Example starting:
    ./vacuum_tables_parallel.py
"""
import os
import sys
import logging
import subprocess
from datetime import datetime
from multiprocessing import Pool
from logging.handlers import WatchedFileHandler

# Настройка логирования
log_directory = "/home/gpadmin/arenadata_configs/operation_log"
if not os.path.exists(log_directory):
    os.makedirs(log_directory)

log_filename = "vacuum_full_tables_{0}.log".format(datetime.now().strftime('%Y%m%d'))
log_filepath = os.path.join(log_directory, log_filename)

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")

stdout_handler = logging.StreamHandler(sys.stdout)
stdout_handler.setFormatter(formatter)
logger.addHandler(stdout_handler)

file_handler = WatchedFileHandler(log_filepath, mode='a')
file_handler.setFormatter(formatter)
logger.addHandler(file_handler)

DB_CONFIG = {
    "dbname": "adb",
    "user": "gpadmin",
    "host": "127.0.0.1",
    "port": "5432"
}

def get_sql_query():
    return """
        SELECT
            bdinspname AS schema_name,
            bdirelname AS relname
        FROM
            gp_toolkit.gp_bloat_diag
        JOIN pg_catalog.pg_class cl ON
            bdirelid = cl.oid
        WHERE
            relpersistence = 'p' 
            -- AND CAST(bdirelpages AS NUMERIC(12,0)) * 32 / 1024 > 100 -- if needed filter tables size MB
        ORDER BY
            bdirelpages DESC;
    """

def get_table_list():
    try:
        sql_query = get_sql_query()
        psql_cmd = [
            "psql",
            "-d", DB_CONFIG["dbname"],
            "-U", DB_CONFIG["user"],
            "-h", DB_CONFIG["host"],
            "-p", DB_CONFIG["port"],
            "-c", sql_query,
            "-tA"
        ]
        result = subprocess.Popen(psql_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = result.communicate()
        if result.returncode != 0:
            raise subprocess.CalledProcessError(result.returncode, psql_cmd, stderr)
        tables = []
        for line in stdout.strip().split("\n"):
            if line:
                parts = line.split("|")
                if len(parts) == 2:
                    tables.append(tuple(parts))
                else:
                    logger.warning("Invalid line in output: '{0}'".format(line))
        logger.info("Found {0} bloated tables requiring VACUUM FULL.".format(len(tables)))
        return tables
    except subprocess.CalledProcessError as e:
        logger.error("psql execution error: {0}, stderr: {1}".format(e, e.stderr))
        raise
    except Exception as e:
        logger.error("Unknown error fetching table list: {0}".format(e))
        raise

def vacuum_table(table):
    try:
        schemaname, tablename = table
        psql_cmd = [
            "psql",
            "-d", DB_CONFIG["dbname"],
            "-U", DB_CONFIG["user"],
            "-h", DB_CONFIG["host"],
            "-p", DB_CONFIG["port"],
            "-c", "VACUUM FULL {0}.{1};".format(schemaname, tablename)
        ]
        result = subprocess.Popen(psql_cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        stdout, stderr = result.communicate()
        if result.returncode != 0:
            raise subprocess.CalledProcessError(result.returncode, psql_cmd, stderr)
        logger.info("Table {0}.{1} successfully vacuumed.".format(schemaname, tablename))
    except Exception as e:
        logger.error("Error vacuuming table {0}.{1}: {2}".format(schemaname, tablename, e))

def main():
    tables = get_table_list()
    if tables:
        pool = Pool(6)
        pool.map(vacuum_table, tables)
        pool.close()
        pool.join()
    logger.info("VACUUM FULL of all bloated tables completed.")

if __name__ == "__main__":
    main()
