## gplogpack & view [high-performance distributed log harvester](https://github.com/psqlmaster/gp_utils/blob/master/gplogpack.md)

**gplogpack** is a professional-grade tool for parallel log collection and filtering across all Greenplum/ADB segments. It is designed to overcome the limitations of standard utilities, particularly in environments like **ALT Linux** where `gpssh` might be unavailable, or when `gplogfilter` is insufficient because it only works locally.

---

### Table of Contents
1. [Key Advantages](#key-advantages)
2. [1. Archive Collection Mode (Single tar.gz)](#1-archive-collection-mode-in-1-archive-file-targz)
3. [2. Archive Collection Mode (Individual .gz files)](#2-archive-collection-mode-in-many-archive-files-gz)
4. [2.2. Archive Collection Mode (Anonymized .gz files)](#22-archive-collection-mode-in-many-archive-files-gz-with-anonymization)
5. [3. Interactive View Mode](#3-interactive-view-mode)
6. [Parameters Reference](#parameters-reference)
7. [Usage Examples](#usage-examples)
8. [Working with Archives](#working-with-archives)

---

### <a name="key-advantages"></a>Key Advantages
- **Distributed Architecture**: Unlike `gplogfilter`, **gplogpack** fetches and aggregates logs from the entire cluster to a single central point.
- **System Independence**: Works via standard `ssh` and `xargs`, bypassing Python-dependency issues or `gpssh` restrictions often found in hardened OS distributions.
- **On-Host Filtering**: Time and text filtering are performed directly on the segment hosts. Only the matching data is sent over the network, drastically reducing traffic and collection time.
- **Performance Optimized**: Uses **short-circuit evaluation** in `awk`. If no `TEXT_FILTER` is provided, the script skips expensive string conversions (like `tolower()`), ensuring maximum processing speed.
- **Context Preservation**: Every line is prefixed with `[hostname segID role]`. This ensures that even when logs are aggregated, multi-line SQL statements and query plans remain identifiable by their source.
- **On-the-fly Anonymization**: Supports real-time data masking. You can redact IPs, logins, and PII (Cyrillic characters) before the data is ever written to the disk of the collection node.
- **Zero-Storage Impact**: By using anonymization and compression in a single pipeline (pipe), the tool processes data in memory without creating unencrypted temporary files.

---

### 1. Archive Collection Mode in 1 archive file `tar.gz`
Use this script to collect logs into a compressed `.tar.gz` archive for deep analysis.

```sh
# Configuration: SEG - segment number (empty “” - all, -1 - master, 1,3 - 1 & 3 segment), role (“‘p’” or “‘m’” or “‘p’,'m'”), TEXT_FILTER and time period:
SEG=""; \
ROLE_FILTER="'p','m'"; \
TEXT_FILTER=""; \
S="2026-03-23 19:00:00"; E="2026-03-23 20:00:00"; \
DIR_NAME="gp_logs_$(date +%H%M%S)"; OUT_DIR="/tmp/$DIR_NAME"; mkdir -p $OUT_DIR; \
echo "Collecting logs to: $OUT_DIR (Max parallel: 20)"; \
psql postgres -AtF' ' -c "SELECT hostname, content, datadir, role FROM gp_segment_configuration WHERE role IN (${ROLE_FILTER}) $([ -n "$SEG" ] && echo "AND content in ($SEG)") ORDER BY content, role" | \
xargs -r -P 20 -n 4 sh -c 'ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$3" "ls $5/pg_log/gpdb-20* 2>/dev/null | sort | awk -v s=\"${0% *}\" -v e=\"${1% *}\" \"{f=\\\$0; gsub(/.*\\//,\\\"\\\",f)} f >= \\\"gpdb-\\\"s || f ~ s { p=1 } p { print \\\$0; if (f >= \\\"gpdb-\\\"e && f !~ e) exit }\" | xargs -r zcat -f | awk -v h=\"$3\" -v c=\"$4\" -v r=\"$6\" -v s=\"$0\" -v e=\"$1\" -v t=\"$2\" \"\\\$1~/^[0-9]{4}-/{o=(\\\$1\\\" \\\"\\\$2>=s && \\\$1\\\" \\\"\\\$2<=e)} o && (t==\\\"\\\" || tolower(\\\$0) ~ tolower(t)) { print \\\"[\\\" h \\\" seg\\\" c \\\" \\\" r \\\"] \\\" \\\$0 }\"" > '$OUT_DIR'/seg_$4_$6_$3.log' "$S" "$E" "$TEXT_FILTER" && \
tar -czf "${OUT_DIR}.tar.gz" -C /tmp "$DIR_NAME" && chmod 644 "${OUT_DIR}.tar.gz" && rm -rf "$OUT_DIR" && \
echo "Done! Archive: ${OUT_DIR}.tar.gz"
```
**output:**
```text
Done! Archive: /tmp/gp_logs_202043.tar.gz
```

### 2. Archive Collection Mode in many archive files `*.gz`
```sh
# Configuration: SEG - segment number (empty “” - all, -1 - master, 1,3 - 1 & 3 segment), role (“‘p’” or “‘m’” or “‘p’,'m'”), TEXT_FILTER and time period:
SEG="-1,2"; \
ROLE_FILTER="'p','m'"; \
TEXT_FILTER=""; \
S="2026-03-23 19:00:00"; E="2026-03-23 20:00:00"; \
DIR_NAME="gp_logs_$(date +%H%M%S)"; OUT_DIR="/tmp/$DIR_NAME"; mkdir -p $OUT_DIR; \
echo "Collecting logs to: $OUT_DIR (Individual .gz files)"; \
psql postgres -AtF' ' -c "SELECT hostname, content, datadir, role FROM gp_segment_configuration WHERE role IN (${ROLE_FILTER}) $([ -n "$SEG" ] && echo "AND content in ($SEG)") ORDER BY content, role" | \
xargs -r -P 20 -n 4 sh -c 'ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$3" "ls $5/pg_log/gpdb-20* 2>/dev/null | sort | awk -v s=\"${0% *}\" -v e=\"${1% *}\" \"{f=\\\$0; gsub(/.*\\//,\\\"\\\",f)} f >= \\\"gpdb-\\\"s || f ~ s { p=1 } p { print \\\$0; if (f >= \\\"gpdb-\\\"e && f !~ e) exit }\" | xargs -r zcat -f | awk -v h=\"$3\" -v c=\"$4\" -v r=\"$6\" -v s=\"$0\" -v e=\"$1\" -v t=\"$2\" \"\\\$1~/^[0-9]{4}-/{o=(\\\$1\\\" \\\"\\\$2>=s && \\\$1\\\" \\\"\\\$2<=e)} o && (t==\\\"\\\" || tolower(\\\$0) ~ tolower(t)) { print \\\"[\\\" h \\\" seg\\\" c \\\" \\\" r \\\"] \\\" \\\$0 }\"" | gzip > '$OUT_DIR'/seg_$4_$6_$3.log.gz' "$S" "$E" "$TEXT_FILTER" && \
chmod 644 $OUT_DIR/*.gz && echo -e "\nDone! Created files:" && ls -lh "$OUT_DIR"/*.gz
```
**output:**
```text
Done! Created files:
-rw-r--r-- 1 gpadmin gpadmin 1.3K Apr 12 20:16 /tmp/gp_logs_201610/seg_-1_m_mdw2.log.gz
-rw-r--r-- 1 gpadmin gpadmin  41K Apr 12 20:16 /tmp/gp_logs_201610/seg_-1_p_mdw1.log.gz
-rw-r--r-- 1 gpadmin gpadmin  775 Apr 12 20:16 /tmp/gp_logs_201610/seg_2_m_sdw1.log.gz
-rw-r--r-- 1 gpadmin gpadmin  40K Apr 12 20:16 /tmp/gp_logs_201610/seg_2_p_sdw2.log.gz
```
---

### 2.2. Archive Collection Mode in many archive files `*.gz` (with Anonymization)
```sh
# Configuration: SEG - segment number (empty “” - all, -1 - master, 1,3 - 1 & 3 segment), role (“‘p’” or “‘m’” or “‘p’,'m'”), TEXT_FILTER and time period,
# ANONYMIZE - If set to “true”, the logs will be processed using anonymization rules.
SEG="2"; \
ROLE_FILTER="'p','m'"; \
TEXT_FILTER=""; \
ANONYMIZE="true"; \
S="2026-03-23 19:00:00"; E="2026-03-23 20:00:00"; \
DIR_NAME="gp_logs_$(date +%H%M%S)"; OUT_DIR="/tmp/$DIR_NAME"; mkdir -p $OUT_DIR; \
MASK_CMD="sed -E 's/[А-Яа-яЁё]/x/g; s/[0-9]{1,3}(\.[0-9]{1,3}){3}/X.X.X.X/g; s/\.int\.bank\.ru/.xxx.ru/g; s/(ndp|srv|apl|gml|vnl)-/xxx-/g; s/gpbu[0-9]+/USER_ID/g; s/DC=[a-zA-Z0-9]+/DC=XXX/g'"; \
echo "Collecting logs to: $OUT_DIR (Anonymize: $ANONYMIZE)"; \
psql postgres -AtF' ' -c "SELECT hostname, content, datadir, role FROM gp_segment_configuration WHERE role IN (${ROLE_FILTER}) $([ -n "$SEG" ] && echo "AND content in ($SEG)") ORDER BY content, role" | \
xargs -r -P 20 -n 4 sh -c 'ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$5" "ls $7/pg_log/gpdb-20* 2>/dev/null | sort | awk -v s=\"${0% *}\" -v e=\"${1% *}\" \"{f=\\\$0; gsub(/.*\\//,\\\"\\\",f)} f >= \\\"gpdb-\\\"s || f ~ s { p=1 } p { print \\\$0; if (f >= \\\"gpdb-\\\"e && f !~ e) exit }\" | xargs -r zcat -f | awk -v h=\"$5\" -v c=\"$6\" -v r=\"$8\" -v s=\"$0\" -v e=\"$1\" -v t=\"$2\" \"\\\$1~/^[0-9]{4}-/{o=(\\\$1\\\" \\\"\\\$2>=s && \\\$1\\\" \\\"\\\$2<=e)} o && (t==\\\"\\\" || tolower(\\\$0) ~ tolower(t)) { print \\\"[\\\" h \\\" seg\\\" c \\\" \\\" r \\\"] \\\" \\\$0 }\"" | ( [ "$3" = "true" ] && eval "$4" || cat ) | gzip > '$OUT_DIR'/seg_$6_$8_$5.log.gz' "$S" "$E" "$TEXT_FILTER" "$ANONYMIZE" "$MASK_CMD" && \
chmod 644 $OUT_DIR/*.gz && echo -e "\nDone! Created files:" && ls -lh "$OUT_DIR"/*.gz
```
---

### 3. Interactive View Mode
Use this script for immediate troubleshooting. It fetches the logs and opens them in `less`.

```sh
# Configuration: SEG - segment number (empty “” - all, -1 - master, 1,3 - 1 & 3 segment), role (“‘p’” or “‘m’” or “‘p’,'m'”), TEXT_FILTER and time period:
SEG="-1"; \
ROLE_FILTER="'p'"; \
TEXT_FILTER=""; \
S="2026-03-23 19:00:00"; E="2026-03-23 20:00:00"; \
DIR_NAME="gp_logs_$(date +%H%M%S)"; OUT_DIR="/tmp/$DIR_NAME"; mkdir -p $OUT_DIR; \
echo "Fetching logs for interactive view..."; \
psql postgres -AtF' ' -c "SELECT hostname, content, datadir, role FROM gp_segment_configuration WHERE role IN (${ROLE_FILTER}) $([ -n "$SEG" ] && echo "AND content in ($SEG)") ORDER BY content, role" | \
xargs -r -P 20 -n 4 sh -c 'ssh -n -o BatchMode=yes -o ConnectTimeout=5 "$3" "ls $5/pg_log/gpdb-20* 2>/dev/null | sort | awk -v s=\"${0% *}\" -v e=\"${1% *}\" \"{f=\\\$0; gsub(/.*\\//,\\\"\\\",f)} f >= \\\"gpdb-\\\"s || f ~ s { p=1 } p { print \\\$0; if (f >= \\\"gpdb-\\\"e && f !~ e) exit }\" | xargs -r zcat -f | awk -v h=\"$3\" -v c=\"$4\" -v r=\"$6\" -v s=\"$0\" -v e=\"$1\" -v t=\"$2\" \"\\\$1~/^[0-9]{4}-/{o=(\\\$1\\\" \\\"\\\$2>=s && \\\$1\\\" \\\"\\\$2<=e)} o && (t==\\\"\\\" || tolower(\\\$0) ~ tolower(t)) { print \\\"[\\\" h \\\" seg\\\" c \\\" \\\" r \\\"] \\\" \\\$0 }\"" > '$OUT_DIR'/seg_$4_$6_$3.log' "$S" "$E" "$TEXT_FILTER" && \
(cat $OUT_DIR/seg* | less) && rm -rf $OUT_DIR && echo "Cleanup done."
```

---

### Parameters Reference

| Variable | Description |
| :--- | :--- |
| `SEG` | Segment ID. `""` for ALL, `"-1"` for Master, `"1,2,5"` for a subset. |
| `ROLE_FILTER` | `'p'` (Primary), `'m'` (Mirror), or both `'p','m'`. |
| `TEXT_FILTER` | Case-insensitive Extended Regex. Supports `|`, `.*`, `()`. |
| `S` / `E` | Start and End timestamps (YYYY-MM-DD HH:MM:SS). |

---

### Usage Examples

#### 1. Subset of Segments (Example: Segments 1, 2, and 5)
Collect logs from three specific segments to investigate localized issues.
```sh
SEG="1,2,5"; ROLE_FILTER="'p'"; TEXT_FILTER=""; S="2026-03-24 10:00:00"; E="2026-03-24 11:00:00";
```

#### 2. Full Cluster Dump (No filtering)
Fastest mode. Collects everything from all segments across the cluster.
```sh
SEG=""; ROLE_FILTER="'p','m'"; TEXT_FILTER=""; S="2026-03-24 00:00:00"; E="2026-03-24 23:59:59";
```

#### 3. Specific IP or Version Search
The dot works as a wildcard, matching IPs or versions effectively.
```sh
SEG=""; ROLE_FILTER="'p'"; TEXT_FILTER="192.168.1.50"; S="2026-03-24 00:00:00"; E="2026-03-24 23:59:59";
```

#### 4. Searching for Global Errors (Multiple Keywords)
Find any critical event using the OR (`|`) operator.
```sh
SEG=""; ROLE_FILTER="'p'"; TEXT_FILTER="panic|fatal|error|critical|oom"; S="2026-03-24 00:00:00"; E="2026-03-24 23:59:59";
```

#### 5. Master Session Investigation
Track a specific session ID on the Master/Coordinator only.
```sh
SEG="-1"; ROLE_FILTER="'p'"; TEXT_FILTER="con184201"; S="2026-03-24 10:00:00"; E="2026-03-24 12:00:00";
```

#### 6. Midnight Boundary Analysis
Automatically pulls files from multiple dates if the range crosses midnight.
```sh
SEG="5"; ROLE_FILTER="'p','m'"; TEXT_FILTER="failover|retry"; S="2026-03-23 23:50:00"; E="2026-03-24 00:30:00";
```

#### 7. SQL Object Search (with Quoting)
Find errors specifically related to a quoted table name.
```sh
SEG=""; ROLE_FILTER="'p'"; TEXT_FILTER="\"order_items\""; S="2026-03-24 14:00:00"; E="2026-03-24 15:00:00";
```

#### 8. Pattern Matching (Wildcards)
Find logs where two words appear in the same line regardless of what is between them.
```sh
SEG=""; ROLE_FILTER="'p'"; TEXT_FILTER="user.*denied"; S="2026-03-24 00:00:00"; E="2026-03-24 23:59:59";
```

#### 9. Synchronization & Mirror Lag
Compare Primary and Mirror behavior for a specific segment during a lag event.
```sh
SEG="12"; ROLE_FILTER="'p','m'"; TEXT_FILTER="replication|sender|receiver"; S="2026-03-24 08:00:00"; E="2026-03-24 09:00:00";
```
---

#### Working with Archives

**List archive content:**
```bash
tar -tvzf /tmp/gp_logs_XXXXXX.tar.gz
```

**Stream logs directly from archive (no extraction needed):**
```bash
# Search for a keyword across all logs in the compressed archive
tar -xzOf /tmp/gp_logs_XXXXXX.tar.gz | grep -i "error_keyword"

# Read a specific segment's log
tar -xzOf /tmp/gp_logs_XXXXXX.tar.gz gp_logs_XXXXXX/seg_0_p_sdw1.log | less
```
---

#### Full Cluster Collection (All segments, All roles)
Comprehensive collection for root cause analysis of cluster-wide issues:

```bash
SEG=""; ROLE_FILTER="'p','m'"; S="2026-03-23 19:05:40"; E="2026-03-23 20:10:40";
```
#### Archive will contain logs from all Primary and Mirror hosts:
```bash
tar -tvf /tmp/gp_logs_111934.tar.gz
```
**output:**
```txt
drwxr-xr-x gpadmin/gpadmin   0 2026-04-07 11:19 gp_logs_111934/
-rw-r--r-- gpadmin/gpadmin 846733 2026-04-07 11:19 gp_logs_111934/seg_1_p_sdw1.log
-rw-r--r-- gpadmin/gpadmin   8860 2026-04-07 11:19 gp_logs_111934/seg_-1_m_mdw2.log
-rw-r--r-- gpadmin/gpadmin   6296 2026-04-07 11:19 gp_logs_111934/seg_0_m_sdw2.log
-rw-r--r-- gpadmin/gpadmin 846652 2026-04-07 11:19 gp_logs_111934/seg_0_p_sdw1.log
-rw-r--r-- gpadmin/gpadmin   6299 2026-04-07 11:19 gp_logs_111934/seg_2_m_sdw1.log
-rw-r--r-- gpadmin/gpadmin 630147 2026-04-07 11:19 gp_logs_111934/seg_-1_p_mdw1.log
-rw-r--r-- gpadmin/gpadmin   6299 2026-04-07 11:19 gp_logs_111934/seg_1_m_sdw2.log
-rw-r--r-- gpadmin/gpadmin 846648 2026-04-07 11:19 gp_logs_111934/seg_3_p_sdw2.log
-rw-r--r-- gpadmin/gpadmin   6271 2026-04-07 11:19 gp_logs_111934/seg_3_m_sdw1.log
-rw-r--r-- gpadmin/gpadmin 846689 2026-04-07 11:19 gp_logs_111934/seg_2_p_sdw2.log
```

---

#### Working with Archives

**List files in the archive:**
```bash
tar -tzf /tmp/gp_logs_XXXXXX.tar.gz
```

**Extract logs:**
```bash
tar -xzf /tmp/gp_logs_XXXXXX.tar.gz
```

**View logs from a specific segment without full extraction:**
```bash
tar -xzOf /tmp/gp_logs_XXXXXX.tar.gz gp_logs_XXXXXX/seg_0_p_sdw1.log | less
```
---
*Copyright (c) 2026, Alexander Shcheglov. BSD 3-Clause License.*

