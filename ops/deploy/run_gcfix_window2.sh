#!/bin/bash
# run_gcfix_window2.sh — gcfix **v2** 验证窗口（2026-09-22 第二轮）
# v1（f7d1390b）实测无效：暖波仍卡 2.7-2.8s、.lease EX 仍 1.8-3.1s。
# v2 修法：整趟 GC 包进单事务（synchronous=FULL 每条语句一次 fsync 是元凶，实测 1.1ms/次）。
# 本窗口只跑 v2 单臂（同协议、同配额、同机；对照=1 小时前两臂实测基线 2.7~3.1s）。
# 生产: trap 兜底自动拉起 fastllm-qwen38-tp4。
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
LOG=$W/gcfix-window2.log
STATUS=$W/gcfix-window2.status
exec > >(tee -a "$LOG") 2>&1
echo "========= GCFIX-V2 WINDOW START $(date "+%F %T") ========="
SO_NEW=$(md5sum $W/overlay-r12-gcfix/ftllm/libfastllm_tools.so | cut -d' ' -f1)
echo "v1_so=f7d1390b4926e22dc1562734e3b221aa  v2_so=$SO_NEW"
PROD_OK=0
QUOTA=$((3*1024*1024*1024))
SSD_V2=/home/ai-agent/prefix_ssd_gcfixtest_v2

restore_on_exit() {
  if ! systemctl is-active --quiet fastllm-qwen38-tp4; then
    echo "--- TRAP: restoring prod $(date "+%T") ---"
    sudo systemctl start fastllm-qwen38-tp4
  fi
}
trap restore_on_exit EXIT

stop_prod() {
  echo "--- stop prod $(date "+%T") ---"
  sudo systemctl stop fastllm-qwen38-tp4
  for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done
  sleep 4
}
start_prod() {
  echo "--- restore prod $(date "+%T") ---"
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
  echo "--- [$TAG] launch pp=$PP ssd=$SSD quota=$QUOTA $(date "+%T") ---"
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

echo "--- preflight: argv 文件端口/模型自检 + 版本自检 ---"
python3 - <<'PY'
import json
d = json.load(open('/home/ai-agent/builds/upgrade-test/argv-r12-accept.json'))['argv']
i = d.index('--port'); j = d.index('--model_name')
assert d[i+1] == '8081' and d[j+1] == 'Qwen3.8-27B', f"argv 口径不对: {d[i+1]} {d[j+1]}"
print(f"argv ok: port={d[i+1]} model={d[j+1]}")
PY
[ "$SO_NEW" = "f7d1390b4926e22dc1562734e3b221aa" ] && { echo "ABORT: 还是 v1 的 .so（未重建？）"; exit 2; }
printf "gc_evidence_string_in_so: "; strings -a $W/overlay-r12-gcfix/ftllm/libfastllm_tools.so | grep -c "gc: evicted="
pkill -9 -f gcfix_probe 2>/dev/null; true

echo "--- [prod-baseline] probe 8080 $(date "+%T") ---"
$VPY $W/trial_probe2.py http://127.0.0.1:8080 $W/probe-gcfix2-prod.json > $W/probe-gcfix2-prod.out 2>&1 || echo "[prod] PROBE_FAIL"
tail -5 $W/probe-gcfix2-prod.out

stop_prod
rm -rf $SSD_V2; mkdir -p $SSD_V2

echo "========== ARM V2: gcfix v2 .so =========="
if launch gcfix-v2 $W/overlay-r12-gcfix $SSD_V2; then
  $VPY /home/ai-agent/bench-scratch/gcfix_probe.py --base http://127.0.0.1:8081 \
    --cache $SSD_V2 --log $W/test-stack-gcfix-v2.log --out /tmp/gcfixprobe-v2 --tag v2 \
    --fill 6 --trials 1 --waves 5 --dev nvme2n1
fi
echo "--- v2 栈日志的 GC 证据行 ---"
grep -a "\[Prefix SSD\] gc:" $W/test-stack-gcfix-v2.log | tail -12
killstack gcfix-v2

echo "========== ARM V2B: 带数据重启（Recover 路径）+ 功能回归 =========="
if launch gcfix-v2b $W/overlay-r12-gcfix $SSD_V2; then
  $VPY $W/trial_probe2.py http://127.0.0.1:8081 $W/probe-gcfix2-v2b.json > $W/probe-gcfix2-v2b.out 2>&1 || echo "[v2b] PROBE_FAIL"
  grep -aE "\[PASS\]|\[FAIL\]" $W/probe-gcfix2-v2b.out | tail -8
  $VPY /home/ai-agent/bench-scratch/gcfix_probe.py --base http://127.0.0.1:8081 \
    --cache $SSD_V2 --log $W/test-stack-gcfix-v2b.log --out /tmp/gcfixprobe-v2smoke --tag v2smoke \
    --fill 0 --trials 0 --smoke 1 --dev nvme2n1
  echo "[v2b] errs=$(grep -acE 'Traceback|CUDA error|out of memory' $W/test-stack-gcfix-v2b.log)"
fi
killstack gcfix-v2b

start_prod
echo
echo "===== 汇总：基线(v1轮 旧/v1) vs 本轮 v2 ====="
for f in /tmp/gcfixprobe-old/SUMMARY.txt /tmp/gcfixprobe-new/SUMMARY.txt /tmp/gcfixprobe-v2/SUMMARY.txt /tmp/gcfixprobe-v2smoke/SUMMARY.txt; do
  [ -f "$f" ] && { echo "-- $f"; cat "$f"; } || echo "-- $f MISSING"
done
echo "GCFIX_V2_WINDOW_DONE $(date "+%F %T") prod=$PROD_OK so=$SO_NEW" > $STATUS
cat $STATUS
echo "========= GCFIX-V2 WINDOW END $(date "+%F %T") ========="
