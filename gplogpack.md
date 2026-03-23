## gplogpack

/* BSD 3-Clause License
Copyright (c) 2025, Alexander Shcheglov
All rights reserved. */

### Description
**gplogpack** is a high-performance distributed log harvester for Greenplum/ADB clusters. It collects logs from all segments (including Master/Coordinator) in parallel, correctly handles log rotation across midnight boundaries, filters by specific time ranges, and packages everything into a single compressed `.tar.gz` archive.

### Key Features
- **Parallelism**: Uses `xargs -P` to fetch logs from multiple hosts simultaneously.
- **Midnight Handling**: Automatically identifies and pulls all relevant log files if the requested range spans across multiple days.
- **Granular Filtering**: Filter by Segment ID (`content`) or Role (`primary` / `mirror`).
- **Context Preservation**: Prepends `[hostname segID role]` to every log line, ensuring multi-line SQL statements remain identifiable.

---

### Implementation Script

Run this script as the `gpadmin` user on the Master/Coordinator host. Adjust the first four variables to define your search criteria.

```sh
# Configuration: Database name, segment number (empty “” - all, -1 - master), role (“‘p’” or “‘m’” or “‘p’,'m'”), and time period:
db="adb"; \
SEG=""; \
ROLE_FILTER="'p','m'"; \
S="2026-03-23 19:05:40"; E="2026-03-23 20:10:40"; \
DIR_NAME="gp_logs_$(date +%H%M%S)"; OUT_DIR="/tmp/$DIR_NAME"; mkdir -p $OUT_DIR; \
echo "Collecting logs to: $OUT_DIR (Target SEG: ${SEG:-ALL}, Role: ${ROLE_FILTER:-'p'})"; \
psql $db -AtF' ' -c "SELECT hostname, content, datadir, role FROM gp_segment_configuration WHERE role IN (${ROLE_FILTER:-'p'}) $([ -n "$SEG" ] && echo "AND content = $SEG") ORDER BY content, role" | \
xargs -r -P 8 -n 4 sh -c 'ssh -n -o BatchMode=yes "$2" "ls $4/pg_log/gpdb-20* 2>/dev/null | sort | awk -v s=\"${0% *}\" -v e=\"${1% *}\" \"{f=\\\$0; gsub(/.*\\//,\\\"\\\",f)} f >= \\\"gpdb-\\\"s || f ~ s { p=1 } p { print \\\$0; if (f >= \\\"gpdb-\\\"e && f !~ e) exit }\" | xargs -r zcat -f | awk -v h=\"$2\" -v c=\"$3\" -v r=\"$5\" -v s=\"$0\" -v e=\"$1\" \"\\\$1~/^[0-9]{4}-/{o=(\\\$1\\\" \\\"\\\$2>=s && \\\$1\\\" \\\"\\\$2<=e)} o { print \\\"[\\\" h \\\" seg\\\" c \\\" \\\" r \\\"] \\\" \\\$0 }\"" > '$OUT_DIR'/seg_$3_$5_$2.log' "$S" "$E" && \
tar -czf "${OUT_DIR}.tar.gz" -C /tmp "$DIR_NAME" && chmod 644 "${OUT_DIR}.tar.gz" && rm -rf "$OUT_DIR" && \
echo "Done! Archive created: ${OUT_DIR}.tar.gz. To inspect: tar -tvf ${OUT_DIR}.tar.gz"
```

---

### Usage Examples

#### 1. Fetching specific Segment logs (Primary & Mirror)
If you need to investigate a specific segment (e.g., Segment ID 3) and compare its Primary and Mirror logs:

```bash
db="adb"; SEG="3"; ROLE_FILTER="'p','m'"; S="2026-03-23 19:05:40"; E="2026-03-23 20:10:40";
# ... run script ...
# Resulting archive content:
tar -tzf /tmp/gp_logs_003148.tar.gz
# gp_logs_003148/
# gp_logs_003148/seg_3_p_sdw2.log
# gp_logs_003148/seg_3_m_sdw1.log
```

#### 2. Fetching Mirror logs only for a specific segment
Useful for checking synchronization issues or health status on standbys:

```bash
db="adb"; SEG="3"; ROLE_FILTER="'m'"; S="2026-03-23 19:05:40"; E="2026-03-23 20:10:40";
# ... run script ...
# Resulting archive content:
tar -tzf /tmp/gp_logs_003504.tar.gz
# gp_logs_003504/
# gp_logs_003504/seg_3_m_sdw1.log
```

#### 3. Full Cluster Collection (All segments, All roles)
Comprehensive collection for root cause analysis of cluster-wide issues:

```bash
db="adb"; SEG=""; ROLE_FILTER="'p','m'"; S="2026-03-23 19:05:40"; E="2026-03-23 20:10:40";
# ... run script ...
# Archive will contain logs from all Primary and Mirror hosts:
tar -tvf /tmp/gp_logs_003803.tar.gz
# -rw-r--r-- gpadmin/gpadmin  seg_1_p_sdw1.log
# -rw-r--r-- gpadmin/gpadmin  seg_-1_m_mdw2.log
# -rw-r--r-- gpadmin/gpadmin  seg_0_m_sdw2.log
# -rw-r--r-- gpadmin/gpadmin  seg_0_p_sdw1.log
# ... etc ...
```

---

### Working with Archives

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
