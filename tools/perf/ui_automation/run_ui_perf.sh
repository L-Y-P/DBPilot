#!/usr/bin/env bash
# ============================================================================
#  tools/perf/ui_automation/run_ui_perf.sh
#
#  驱动真实安装的 DBPilot.app，采集 UI 层性能（应用内测不到的部分）。
#
#  用法：
#    bash tools/perf/ui_automation/run_ui_perf.sh
#
#  前置：
#    1. /Applications/DBPilot.app 是 release 构建；
#    2. MySQL 可连，dbpilot_perf 数据集已导入（tools/perf/gen_datasets.sh）；
#    3. 终端/IDE 已获「辅助功能」授权。
#
#  分工：
#    * 本脚本：真实窗口下的连接、展开、查询、内存；
#    * 应用自身：帧率。启动时带 DBPILOT_FRAME_TRACE=1，应用会周期性打印
#      FRAME_TRACE 行，脚本负责抓回日志并汇总 p50/p95/jank。
#
#  已知限制（实测，勿当 bug）：
#    * Flutter 自绘控件常忽略 AXPress（-25206），部分按钮需按坐标点击；
#    * 直接 keystroke 会被输入法污染，写 SQL 必须用剪贴板粘贴；
#    * AppleScript 只能看到 5 层控件，读深层文本要用 CUA。
# ============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT_DIR:-out/perf-results}"
mkdir -p "$OUT"
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$OUT/ui-perf-$STAMP.txt"
FRAME_LOG="$OUT/frame-trace-$STAMP.log"

log() { printf '%s\n' "$*" | tee -a "$REPORT"; }
texts() {
  osascript -e 'tell application "System Events" to tell process "DBPilot" to return value of every static text of window 1' 2>/dev/null || true
}
now_ms() { python3 -c 'import time;print(int(time.time()*1000))'; }

log "== DBPilot UI 性能采集  $STAMP =="
log ""

# ---------------------------------------------------------------- 0) 启动
pkill -f 'DBPilot.app/Contents/MacOS/DBPilot' 2>/dev/null || true
sleep 1
DBPILOT_FRAME_TRACE=1 /Applications/DBPilot.app/Contents/MacOS/DBPilot > "$FRAME_LOG" 2>&1 &
sleep 8
PID="$(pgrep -f 'DBPilot.app/Contents/MacOS/DBPilot' | head -1 || true)"
if [ -z "${PID:-}" ]; then
  log "启动失败：找不到 DBPilot 进程"
  exit 1
fi
RSS_START="$(ps -o rss= -p "$PID" | tr -d ' ')"
log "app pid = $PID"
log "启动后 RSS = $RSS_START KB"
log "帧采样日志 = $FRAME_LOG"
log ""

# ------------------------------------------------- 1) 连接建立 + 库列表
log "-- 1) 连接建立 --"
START=$(now_ms)
osascript -e 'tell application "System Events" to tell process "DBPilot" to click button "打开" of window 1' >/dev/null 2>&1 || true
READY=false
for _ in $(seq 1 160); do
  if texts | grep -q '张表'; then READY=true; break; fi
  sleep 0.25
done
if [ "$READY" = true ]; then
  log "连接 + 库列表就绪 = $(( $(now_ms) - START )) ms"
else
  log "超时：未出现「N 张表」"
fi
log ""

# ------------------------------------------- 2) 5000 表库展开（侧边栏）
log "-- 2) 5000 张表的库 --"
START=$(now_ms)
osascript -e 'tell application "System Events" to tell process "DBPilot" to click static text "dbpilot_perf" of window 1' >/dev/null 2>&1 || true
for _ in $(seq 1 240); do
  if texts | grep -q 't_0001'; then break; fi
  sleep 0.25
done
log "侧边栏展开（5000 表） = $(( $(now_ms) - START )) ms"
log "展开后 RSS = $(ps -o rss= -p "$PID" | tr -d ' ') KB"
log ""

# ------------------------------------------------------- 3) 查询 + 滚动
log "-- 3) 大结果集查询（5 轮）--"
for i in 1 2 3 4 5; do
  osascript <<'OSA' >/dev/null 2>&1 || true
tell application "System Events"
  tell process "DBPilot" to set frontmost to true
  set the clipboard to "SELECT * FROM narrow_10m LIMIT 5000"
  keystroke "v" using command down
end tell
OSA
  START=$(now_ms)
  osascript -e 'tell application "System Events" to tell process "DBPilot" to click button "执行" of window 1' >/dev/null 2>&1 || true
  sleep 2
  log "  round $i: $(( $(now_ms) - START )) ms（含 2s 固定等待）, RSS = $(ps -o rss= -p "$PID" | tr -d ' ') KB"
done
log ""

# ------------------------------------------------------------- 4) 内存
RSS_END="$(ps -o rss= -p "$PID" | tr -d ' ')"
GROWTH=$(python3 -c "print(round(($RSS_END - $RSS_START) / max($RSS_START,1) * 100, 1))")
log "-- 4) 内存 --"
log "RSS: $RSS_START KB -> $RSS_END KB，增长 $GROWTH%"
log "判据 < 10%: $(python3 -c "print('PASS' if $GROWTH < 10 else 'FAIL')")"
log ""

# ------------------------------------------------------- 5) 帧耗时汇总
log "-- 5) 帧耗时（应用内 FrameTiming 采样）--"
sleep 3
pkill -f 'DBPilot.app/Contents/MacOS/DBPilot' 2>/dev/null || true
sleep 1
FRAME_LINES="$(grep -c 'FRAME_TRACE frames=' "$FRAME_LOG" 2>/dev/null || true)"
log "采样窗口数 = ${FRAME_LINES:-0}"
if [ "${FRAME_LINES:-0}" -gt 0 ]; then
  log "原始行（最多 20 条）："
  grep 'FRAME_TRACE frames=' "$FRAME_LOG" | head -20 | sed 's/^/  /' | tee -a "$REPORT"
  python3 - "$FRAME_LOG" <<'PY' | tee -a "$REPORT"
import re, sys, statistics
path = sys.argv[1]
totals, builds, rasters, janks = [], [], [], []
for line in open(path, errors='replace'):
    if 'FRAME_TRACE frames=' not in line:
        continue
    m = re.search(r'jank=(d+)(([d.]+)%)', line)
    if m:
        janks.append(float(m.group(2)))
    for key, bucket in (('build', builds), ('raster', rasters), ('total', totals)):
        mm = re.search(key + r'(ms) p50=([d.]+) p95=([d.]+) max=([d.]+)', line)
        if mm:
            bucket.append(tuple(float(x) for x in mm.groups()))
def fmt(name, rows):
    if not rows:
        print(f'  {name}: 无数据'); return
    p50 = statistics.median(r[0] for r in rows)
    p95 = statistics.median(r[1] for r in rows)
    mx  = max(r[2] for r in rows)
    print(f'  {name}: p50={p50:.2f}ms p95={p95:.2f}ms max={mx:.2f}ms')
print('  汇总（各窗口分位数的中位数 / 全局最大）：')
fmt('build ', builds); fmt('raster', rasters); fmt('total ', totals)
if janks:
    print(f'  jank 率: 平均 {statistics.mean(janks):.1f}%，最高 {max(janks):.1f}%')
PY
fi
log ""
log "报告已写入：$REPORT"
