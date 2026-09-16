#!/bin/bash
# run_smoke_r5.sh — r5 (fork sm75-2080Ti @e3b65d3b, upstream 61c288a9c merged + #726/#663 carry) staging window.
# Flow: preflight -> prod baseline probe -> stop prod -> start test stack (8081) -> probe -> stop test -> restore prod.
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
LOG=$W/test-stack-r5.log
SMOKE=$W/smoke-r5.log
STATUS=$W/smoke-r5.status

exec > >(tee -a "$SMOKE") 2>&1
echo "================ SMOKE R5 START $(date '+%F %T') ================"

echo "--- PHASE0 preflight (prod 未动) ---"
BSTAT=$(cat $W/build-r5.status 2>/dev/null | paste -sd'|')
echo "build-r5.status=$BSTAT"
if ! grep -q BUILD_OK $W/build-r5.status 2>/dev/null; then echo "ABORT: build not ok"; echo "SMOKE_ABORT_preflight" > $STATUS; exit 1; fi
BSO=$(find $W/build-r5 -name "libfastllm_tools.so" -not -path "*/CMakeFiles/*" | head -1)
[ -n "$BSO" ] || { echo "ABORT: no .so"; echo "SMOKE_ABORT_no_so" > $STATUS; exit 1; }
ls -l "$BSO"; md5sum "$BSO"

ovl=$W/overlay-r5/ftllm
if [ ! -d $W/overlay-r5 ]; then
  mkdir -p $W/overlay-r5
  cp -a $W/build-r5/tools/ftllm $ovl || { echo "ABORT overlay cp"; exit 1; }
fi
echo "-- overlay .so:"; ls -l $ovl/libfastllm_tools.so* 2>/dev/null
echo "-- 门控串检查 (应为非0):"; strings -a $ovl/libfastllm_tools.so | grep -c "ALLOW_YARN_WITH_DFLASH" || true
echo "-- 新上游串检查 (MTP 提案路径, 非0 说明新代码已进 .so):"; strings -a $ovl/libfastllm_tools.so | grep -c "proposal_q" || true
echo "-- .so 指纹对照: 生产当前 md5 = $(md5sum $V/lib/python3.13/site-packages/ftllm/libfastllm_tools.so 2>/dev/null | cut -d' ' -f1)"
echo "-- import 冒烟:"
PYTHONPATH=$W/overlay-r5 $VPY -c "import ftllm; print('ftllm from:', ftllm.__file__)" || { echo "ABORT import"; exit 1; }
PYTHONPATH=$W/overlay-r5 $VPY -c "import ftllm.openai_server.fastllm_completion as fc; print('openai_server import OK')" || { echo "ABORT import2"; exit 1; }
echo "PREFLIGHT_OK"

echo "--- PHASE0b prod baseline probe (8080, 生产仍在线) $(date '+%T') ---"
$VPY $W/r5_probe.py http://127.0.0.1:8080 $W/r5-probe-prod-baseline.json PROD_BASE || echo "BASELINE_PROBE_INCOMPLETE"

echo "--- PHASE1 stop prod $(date '+%T') ---"
sudo systemctl stop fastllm-qwen38-tp4
for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done
systemctl is-active fastllm-qwen38-tp4 && echo "WARN: prod still active"
sleep 5
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader

echo "--- PHASE2 start test stack $(date '+%T') ---"
cd $W
nohup $VPY $W/fastllm_test_launch_r5.py > $LOG 2>&1 &
TPID=$!
echo $TPID > $W/test-r5.pid
echo "test pid=$TPID"

echo "--- PHASE3 wait ready (max 1800s) ---"
READY=0
for i in $(seq 1 360); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then READY=1; echo "READY http=$code after ~$((i*5))s"; break; fi
  if ! kill -0 $TPID 2>/dev/null; then echo "TEST_PROCESS_DIED"; break; fi
  sleep 5
done
if [ "$READY" = "0" ]; then echo "NOT_READY"; tail -60 $LOG; fi

if [ "$READY" = "1" ]; then
  echo "--- PHASE4 probe (8081) $(date '+%T') ---"
  $VPY $W/r5_probe.py http://127.0.0.1:8081 $W/r5-probe-test.json R5_TEST || echo "PROBE_INCOMPLETE"
  $VPY $W/r5_extra.py http://127.0.0.1:8081 $W/r5-extra-test.json R5_TEST || echo "EXTRA_PROBE_INCOMPLETE"
  echo "-- 日志关键行 --"
  grep -nE "fastllm-experimental|Yarn|DFlash2|context window limit|KV Cache Token limit|AutoWarmup|prefix cache|Traceback|Error" $LOG | tail -25
  echo "-- 指纹/回归计数 --"
  printf "long_prefill_seeded=%s\n" "$(grep -c 'long prefill cache seeded' $LOG)"
  printf "draft_desync_aligned_msg=%s\n" "$(grep -c 'draft cache is not aligned' $LOG)"
  printf "accept_selector_q=%s\n" "$(grep -c 'rejection(selector_q,target_p)' $LOG)"
  printf "accept_proposal_q=%s\n" "$(grep -c 'rejection(proposal_q,target_p)' $LOG)"
  printf "prefix_cache_restored=%s\n" "$(grep -c 'prefix cache restored' $LOG)"
  printf "seeded_lines:\n"; grep -o 'long prefill cache seeded: tokens=[0-9]*, chunk=[0-9]*' $LOG | tail -5
  printf "aligned_lines:\n"; grep -o 'not enabled: draft cache is not aligned with the target cache' $LOG | tail -3
  echo "-- GPU --"
  nvidia-smi --query-gpu=index,memory.used,temperature.gpu --format=csv,noheader
fi

echo "--- PHASE5 stop test $(date '+%T') ---"
kill $TPID 2>/dev/null
sleep 10
kill -9 $TPID 2>/dev/null
for i in $(seq 1 30); do kill -0 $TPID 2>/dev/null || break; sleep 1; done
echo "等待显存释放..."
for i in $(seq 1 45); do
  used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0)
  if [ "$used" -lt 3000 ]; then break; fi
  sleep 2
done
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader

echo "--- PHASE6 restore prod $(date '+%T') ---"
sudo systemctl start fastllm-qwen38-tp4
RP=0
for i in $(seq 1 180); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "PROD_READY http=$code after ~$((i*5))s"; break; fi
  sleep 5
done
[ "$RP" = "0" ] && { echo "PROD_NOT_READY"; tail -40 /home/ai-agent/fastllm-video-repro/results/server-prod.service.log 2>/dev/null; }

echo "--- PHASE7 prod quick verify $(date '+%T') ---"
if [ "$RP" = "1" ]; then
  KEY=$(sed -n 's/^VLLM_API_KEY=//p' /home/ai-agent/qwen38-0.2x.env | head -1 | tr -d '"' | tr -d "'")
  curl -s -m 120 http://127.0.0.1:8080/v1/chat/completions -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
    -d '{"model":"Qwen3.8-27B-W8A16","messages":[{"role":"user","content":"Reply with exactly PROD_RESTORE_OK and nothing else."}],"max_tokens":32,"temperature":0,"chat_template_kwargs":{"enable_thinking":false}}' | head -c 300; echo
fi

echo "SMOKE_DONE ready=$READY prod=$RP" > $STATUS
echo "================ SMOKE R5 END $(date '+%F %T') ================"
