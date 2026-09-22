#!/bin/bash
# run_exp_window.sh — 「前缀缓存导出批量发布」修复 同窗 A/B 验证（2026-09-22）
# 臂A = overlay-r12      （= 现役 .so 6e131be595，GC 单事务修复版）
# 臂B = overlay-r12-exp  （= + 导出批量发布 1747548d…）
# 归因证据：生产线程采样 → 导出线程 71% 时间卡在 fsync/fdatasync 等 jbd2 提交
#           （每个分片 4 次落盘确认：intent/暂存fsync/登记事务/目录同步）
# 度量：每发请求「回答结束 → [Prefix SSD] committed」滞后（= 该窗口内重复问同一题走冷路径）
# 生产：trap 兜底自动拉起；SWITCH=1 时窗口末尾自动切生产（switch_to_r12_exp.sh）
set -u
trap '' HUP
trap 'echo HUP_IGNORED' HUP
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
LOG=$W/exp-window.log
STATUS=$W/exp-window.status
SWITCH=${SWITCH:-0}
exec > >(tee -a "$LOG") 2>&1
echo "========= EXP-BATCH WINDOW START $(date '+%F %T') switch=$SWITCH ========="
SO_A=$(md5sum $W/overlay-r12/ftllm/libfastllm_tools.so | cut -d' ' -f1)
SO_B=$(md5sum $W/overlay-r12-exp/ftllm/libfastllm_tools.so | cut -d' ' -f1)
echo "armA_so=$SO_A  armB_so=$SO_B"
PROD_OK=0
QUOTA=$((24*1024*1024*1024))
SSD_A=/home/ai-agent/prefix_ssd_exptest_a
SSD_B=/home/ai-agent/prefix_ssd_exptest_b

restore_on_exit() {
  if ! systemctl is-active --quiet fastllm-qwen38-tp4; then
    echo "--- TRAP: restoring prod $(date '+%T') ---"
    sudo systemctl start fastllm-qwen38-tp4
  fi
}
trap restore_on_exit EXIT INT TERM

stop_prod() {
  echo "--- stop prod $(date '+%T') ---"
  sudo systemctl stop fastllm-qwen38-tp4
  for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done
  sleep 4
}
start_prod() {
  echo "--- restore prod $(date '+%T') ---"
  sudo systemctl start fastllm-qwen38-tp4
  PROD_OK=0
  for i in $(seq 1 240); do
    code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then PROD_OK=1; echo "PROD_READY after ~$((i*5))s"; break; fi
    sleep 5
  done
  echo "prod_ready=$PROD_OK"
  bash $W/scripts/warmup_prod.sh 360 2>&1 | tail -1
}
launch() {  # $1 tag  $2 pythonpath  $3 ssd
  local TAG=$1 PP=$2 SSD=$3
  echo "--- [$TAG] launch pp=$PP ssd=$SSD quota=$QUOTA $(date '+%T') ---"
  ARGV_FILE=argv-r12-accept.json DFLASH_TB=force GCFIX_PYTHONPATH=$PP GCFIX_SSD=$SSD \
    GCFIX_DISK_BYTES=$QUOTA nohup $VPY $W/fastllm_test_launch_r12_gcfix.py > $W/test-stack-$TAG.log 2>&1 &
  local TPID=$!
  echo $TPID > $W/test-$TAG.pid
  local READY=0
  for i in $(seq 1 72); do
    local code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
    if [ "$code" = "401" ] || [ "$code" = "200" ]; then READY=1; echo "[$TAG] READY http=$code ~$((i*5))s"; break; fi
    kill -0 $TPID 2>/dev/null || { echo "[$TAG] DIED ~$((i*5))s"; break; }
    sleep 5
  done
  if [ "$READY" != "1" ]; then echo "[$TAG] tail:"; tail -15 $W/test-stack-$TAG.log; return 1; fi
  echo "[$TAG] ssd_boot=$(grep -ac 'Prefix SSD' $W/test-stack-$TAG.log) errs=$(grep -acE 'Traceback|CUDA error|out of memory' $W/test-stack-$TAG.log)"
  if ! python3 - "$TAG" <<'PY'
import json, sys, urllib.request
chk = json.load(open('/home/ai-agent/builds/upgrade-test/argv-r12-accept.json'))['argv']
expect = chk[chk.index('--model_name') + 1]
key = ''
for line in open('/home/ai-agent/qwen38-0.2x.env'):
    if line.strip().startswith('VLLM_API_KEY='):
        key = line.split('=', 1)[1].strip().strip('"').strip("'"); break
req = urllib.request.Request('http://127.0.0.1:8081/v1/models', headers={'Authorization': f'Bearer {key}'})
ids = [x.get('id') for x in json.load(urllib.request.urlopen(req, timeout=10)).get('data', [])]
print(f"[{sys.argv[1]}] served_ids={ids} expect={expect}")
sys.exit(0 if expect in ids else 3)
PY
  then echo "[$TAG] MODEL_NAME_CHECK_FAIL"; tail -6 $W/test-stack-$TAG.log; return 1; fi
  return 0
}
killstack() {
  local TAG=$1
  kill $(cat $W/test-$TAG.pid) 2>/dev/null; sleep 8; kill -9 $(cat $W/test-$TAG.pid) 2>/dev/null
  pkill -9 -f fastllm_test_launch_r12_gcfix 2>/dev/null
  local j=0
  while [ $j -lt 60 ]; do
    local used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0)
    [ "$used" -lt 3000 ] && break
    sleep 2; j=$((j+1))
  done
  nvidia-smi --query-gpu=index,memory.used --format=csv,noheader | tr "\n" " "; echo
}

echo "--- preflight ---"
python3 - <<'PY'
import json
d = json.load(open('/home/ai-agent/builds/upgrade-test/argv-r12-accept.json'))['argv']
i = d.index('--port'); j = d.index('--model_name')
assert d[i+1] == '8081' and d[j+1] == 'Qwen3.8-27B', f"argv 口径不对: {d[i+1]} {d[j+1]}"
print(f"argv ok: port={d[i+1]} model={d[j+1]}")
PY
[ "$SO_A" = "6e131be595e50ab911047d63ba999211" ] || { echo "ABORT: armA so 不是现役 v2 ($SO_A)"; exit 2; }
[ "$SO_B" = "1747548d1553aa416591cc96e847c568" ] || { echo "ABORT: armB so 不是新构建 ($SO_B)"; exit 2; }
printf "armB_export_print_in_so: "; strings -a $W/overlay-r12-exp/ftllm/libfastllm_tools.so | grep -c "export: chunks="
printf "armB_flushpending_in_so: "; strings -a $W/overlay-r12-exp/ftllm/libfastllm_tools.so | grep -c ":batch:"
printf "armA_export_print_in_so(应0): "; strings -a $W/overlay-r12/ftllm/libfastllm_tools.so | grep -c "export: chunks="
pkill -9 -f exp_probe 2>/dev/null; true

stop_prod
rm -rf $SSD_A $SSD_B /tmp/expwindow; mkdir -p $SSD_A $SSD_B /tmp/expwindow/A /tmp/expwindow/B

echo "========== ARM A: overlay-r12（现役基线 6e131be595）=========="
if launch exp-a $W/overlay-r12 $SSD_A; then
  $VPY $W/exp_probe.py --base http://127.0.0.1:8081 --cache $SSD_A --log $W/test-stack-exp-a.log --out /tmp/expwindow/A --tag A
  echo "[A] errs=$(grep -acE 'Traceback|CUDA error|out of memory' $W/test-stack-exp-a.log)"
  echo "[A] 栈日志 committed 行:"; grep -a "committed" $W/test-stack-exp-a.log | tail -6
fi
killstack exp-a

echo "========== ARM B: overlay-r12-exp（批量发布 1747548d）=========="
if launch exp-b $W/overlay-r12-exp $SSD_B; then
  $VPY $W/exp_probe.py --base http://127.0.0.1:8081 --cache $SSD_B --log $W/test-stack-exp-b.log --out /tmp/expwindow/B --tag B
  echo "[B] errs=$(grep -acE 'Traceback|CUDA error|out of memory' $W/test-stack-exp-b.log)"
  echo "[B] 栈日志 committed 行:"; grep -a "committed" $W/test-stack-exp-b.log | tail -6
  echo "[B] export 计时行:"; grep -a "export: chunks=" $W/test-stack-exp-b.log | tail -12
fi
killstack exp-b

echo "========== ARM B2: 带数据重启（Recover 路径）+ 功能回归 =========="
if launch exp-b2 $W/overlay-r12-exp $SSD_B; then
  $VPY $W/trial_probe2.py http://127.0.0.1:8081 $W/probe-exp-b2.json > $W/probe-exp-b2.out 2>&1 || echo "[b2] PROBE_FAIL"
  grep -aE "\[PASS\]|\[FAIL\]" $W/probe-exp-b2.out | tail -10
  echo "[b2] recover_lines=$(grep -ac 'full recovery starting' $W/test-stack-exp-b2.log) errs=$(grep -acE 'Traceback|CUDA error|out of memory' $W/test-stack-exp-b2.log)"
  grep -a "Prefix SSD" $W/test-stack-exp-b2.log | head -10
fi
killstack exp-b2

if [ "$SWITCH" = "1" ]; then
  echo "========== SWITCH 到生产（export 批量发布）=========="
  bash $W/wt-r12/ops/deploy/switch_to_r12_exp.sh
  PROD_OK=1
else
  start_prod
fi

echo
echo "===== 汇总：A(现役) vs B(批量发布) ====="
for f in /tmp/expwindow/A/SUMMARY.txt /tmp/expwindow/B/SUMMARY.txt; do
  echo "-- $f"
  grep -aE "objects_start|^\[|export:|gc:|EXP_PROBE_DONE" "$f" 2>/dev/null | head -30 || echo MISSING
done
echo "EXP_WINDOW_DONE $(date '+%F %T') prod=$PROD_OK switch=$SWITCH soA=$SO_A soB=$SO_B" > $STATUS
cat $STATUS
echo "========= EXP-BATCH WINDOW END $(date '+%F %T') ========="
