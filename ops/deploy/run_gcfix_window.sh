#!/bin/bash
# run_gcfix_window.sh — 前缀缓存门闩修复（gcfix）候选验证窗口（2026-09-22）
# 同窗 A/B: 旧 r12 .so (overlay-r12) vs gcfix .so (overlay-r12-gcfix)，唯一变量= .so。
# 每臂: 小配额(3GiB) SSD 缓存 + fill 6x8K + 2 连冷轮(2x32K) + 3s + 5 暖波(2 并发)
#       + 0.1s 锁占据采样（gcfix_probe.py）；第二臂追加带数据重启 + 烟测。
# 生产: 脚本自带 trap，任何退出路径都会拉起 fastllm-qwen38-tp4。
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
LOG=$W/gcfix-window.log
STATUS=$W/gcfix-window.status
exec > >(tee -a "$LOG") 2>&1
echo "========= GCFIX WINDOW START $(date "+%F %T") ========="
SO_OLD=$(md5sum $W/overlay-r12/ftllm/libfastllm_tools.so | cut -d' ' -f1)
SO_NEW=$(md5sum $W/overlay-r12-gcfix/ftllm/libfastllm_tools.so | cut -d' ' -f1)
echo "old_so=$SO_OLD  new_so=$SO_NEW"
PROD_OK=0
QUOTA=$((3*1024*1024*1024))
SSD_OLD=/home/ai-agent/prefix_ssd_gcfixtest_old
SSD_NEW=/home/ai-agent/prefix_ssd_gcfixtest_new

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
  grep -a "Prefix SSD" $W/test-stack-$TAG.log | head -3
  # served 模型名硬校验（防 404 烧窗口；模型名 ≠ argv 则视为失败）
  if ! python3 - "$TAG" <<'PY'
import json, sys, urllib.request
W = '/home/ai-agent/builds/upgrade-test'
chk = json.load(open(f'{W}/argv-r12-accept.json'))['argv']
expect = chk[chk.index('--model_name') + 1]
key = ''
for line in open('/home/ai-agent/qwen38-0.2x.env'):
    if line.strip().startswith('VLLM_API_KEY='):
        key = line.split('=', 1)[1].strip().strip('"').strip("'"); break
req = urllib.request.Request('http://127.0.0.1:8081/v1/models', headers={'Authorization': f'Bearer {key}'})
ids = [x.get('id') for x in json.load(urllib.request.urlopen(req, timeout=10)).get('data', [])]
tag = sys.argv[1]
print(f"[{tag}] served_ids={ids} expect={expect}")
sys.exit(0 if expect in ids else 3)
PY
  then echo "[$TAG] MODEL_NAME_CHECK_FAIL"; tail -6 $W/test-stack-$TAG.log; return 1; fi
  return 0
}
killstack() {  # $1 tag
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

echo "--- preflight: argv 文件端口/模型自检 ---"
python3 - <<'PY'
import json
d = json.load(open('/home/ai-agent/builds/upgrade-test/argv-r12-accept.json'))['argv']
i = d.index('--port'); j = d.index('--model_name')
assert d[i+1] == '8081', f"port not 8081: {d[i+1]}"
assert d[j+1] == 'Qwen3.8-27B', f"model not Qwen3.8-27B: {d[j+1]}"
print(f"argv ok: port={d[i+1]} model={d[j+1]}")
PY
pkill -9 -f gcfix_probe 2>/dev/null; true

echo "--- [prod-baseline] probe 8080 $(date "+%T") ---"
$VPY $W/trial_probe2.py http://127.0.0.1:8080 $W/probe-gcfix-prod.json > $W/probe-gcfix-prod.out 2>&1 || echo "[prod] PROBE_FAIL"
tail -5 $W/probe-gcfix-prod.out

stop_prod
rm -rf $SSD_OLD $SSD_NEW; mkdir -p $SSD_OLD $SSD_NEW

echo "========== ARM A: 旧 r12 .so =========="
if launch gcfix-old $W/overlay-r12 $SSD_OLD; then
  $VPY /home/ai-agent/bench-scratch/gcfix_probe.py --base http://127.0.0.1:8081 \
    --cache $SSD_OLD --log $W/test-stack-gcfix-old.log --out /tmp/gcfixprobe-old --tag old \
    --fill 6 --trials 1 --waves 5
fi
killstack gcfix-old

echo "========== ARM B: gcfix .so =========="
if launch gcfix-new $W/overlay-r12-gcfix $SSD_NEW; then
  $VPY /home/ai-agent/bench-scratch/gcfix_probe.py --base http://127.0.0.1:8081 \
    --cache $SSD_NEW --log $W/test-stack-gcfix-new.log --out /tmp/gcfixprobe-new --tag new \
    --fill 6 --trials 1 --waves 5
fi
killstack gcfix-new

echo "========== ARM B2: gcfix 带数据重启（Recover/索引快路径）+ 功能回归 =========="
if launch gcfix-new2 $W/overlay-r12-gcfix $SSD_NEW; then
  $VPY $W/trial_probe2.py http://127.0.0.1:8081 $W/probe-gcfix-new2.json > $W/probe-gcfix-new2.out 2>&1 || echo "[gcfix-new2] PROBE_FAIL"
  grep -aE "\[PASS\]|\[FAIL\]" $W/probe-gcfix-new2.out | tail -8
  for m in f5de00c56dd1 30f8a5c9ee88 2adaf2269e77; do grep -q "$m" $W/probe-gcfix-new2.out && echo "  md5 $m OK" || echo "  md5 $m MISS"; done
  $VPY /home/ai-agent/bench-scratch/gcfix_probe.py --base http://127.0.0.1:8081 \
    --cache $SSD_NEW --log $W/test-stack-gcfix-new2.log --out /tmp/gcfixprobe-smoke --tag smoke \
    --fill 0 --trials 0 --smoke 1
  echo "[gcfix-new2] errs=$(grep -acE 'Traceback|CUDA error|out of memory' $W/test-stack-gcfix-new2.log) recover=$(grep -ac 'recover' $W/test-stack-gcfix-new2.log)"
fi
killstack gcfix-new2

start_prod
echo
echo "===== 臂汇总（同窗 A/B）====="
for f in /tmp/gcfixprobe-old/SUMMARY.txt /tmp/gcfixprobe-new/SUMMARY.txt /tmp/gcfixprobe-smoke/SUMMARY.txt; do
  [ -f "$f" ] && { echo "-- $f"; cat "$f"; } || echo "-- $f MISSING"
done
echo "GCFIX_WINDOW_DONE $(date "+%F %T") prod=$PROD_OK so_old=$SO_OLD so_new=$SO_NEW" > $STATUS
cat $STATUS
echo "========= GCFIX WINDOW END $(date "+%F %T") ========="
