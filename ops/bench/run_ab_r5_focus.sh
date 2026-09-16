#!/bin/bash
# run_ab_r5_focus.sh — 定向复测窗口：prodA(8080) -> r5(8081) -> prodC(8080) 三腿三明治。
# 只跑 digits（计数类，输出可逐字节对照）64K/128K，每档 cold+warm 各 3 次重复 + 200 请求内存探针。
# 每腿都记录「引擎侧」证据：该腿日志切片内的 [Decode] alive=1 Speed 分布 + pos_accept_rate 行 + seeded/restored/desync。
# 生产只在中间腿下线；结束时自动恢复生产。
set -u
W=/home/ai-agent/builds/upgrade-test
V=/home/ai-agent/builds/fastllm-video-venv
VPY=$V/bin/python
PLOG=/home/ai-agent/fastllm-video-repro/results/server-prod.service.log
TLOG=$W/test-stack-ab-r5-focus.log
ABLOG=$W/ab-r5-focus-window.log
STATUS=$W/ab-r5-focus.status
D=$W/focus-artifacts
mkdir -p $D
exec > >(tee -a "$ABLOG") 2>&1
echo "================ AB R5 FOCUS WINDOW START $(date '+%F %T') ================"
echo "prod .so md5 = $(md5sum $V/lib/python3.13/site-packages/ftllm/libfastllm_tools.so 2>/dev/null | cut -d' ' -f1)"
echo "r5   .so md5 = $(md5sum $W/overlay-r5/ftllm/libfastllm_tools.so 2>/dev/null | cut -d' ' -f1)"
echo "GPU temps at start: $(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader | paste -sd/)"

extract_leg () {   # extract_leg <logfile> <offset> <legname>
  local LOG=$1 OFF=$2 NAME=$3
  tail -n +$((OFF + 1)) "$LOG" > $D/$NAME-slice.log
  grep -E "\[Decode\].*alive = 1" $D/$NAME-slice.log | grep -oE "Speed[: ]+[0-9.]+" | awk '{print $NF}' | sort -n > $D/$NAME-decode.txt
  grep -oE "pos_accept_rate=\[[^]]*\]" $D/$NAME-slice.log > $D/$NAME-accept.txt
  local N=$(wc -l < $D/$NAME-decode.txt)
  printf "%s decode n=%s  " "$NAME" "$N"
  if [ "$N" -gt 0 ]; then
    awk '{a[NR]=$1} END{printf "min=%.1f p25=%.1f median=%.1f p75=%.1f max=%.1f\n", a[1], a[int(NR*0.25)+1], a[int((NR+1)/2)], a[int(NR*0.75)], a[NR]}' $D/$NAME-decode.txt
  else echo "(no samples)"; fi
  printf "%s 切片计数: seeded=%s restored=%s desync=%s accept_lines=%s\n" "$NAME" \
    "$(grep -c 'long prefill cache seeded' $D/$NAME-slice.log)" \
    "$(grep -c 'prefix cache restored' $D/$NAME-slice.log)" \
    "$(grep -c 'draft cache is not aligned' $D/$NAME-slice.log)" \
    "$(wc -l < $D/$NAME-accept.txt)"
}

echo "--- LEG A: prod suite #1 (8080, 生产在线) $(date '+%T') ---"
A0=$(wc -l < $PLOG 2>/dev/null || echo 0)
$VPY $W/ab_r5_focus.py http://127.0.0.1:8080 $W/ab-r5-focus-prodA.json PROD_A || echo LEG_A_INCOMPLETE
extract_leg $PLOG $A0 prodA
echo "-- prod temps: $(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader | paste -sd/)"

echo "--- LEG B: stop prod $(date '+%T') ---"
sudo systemctl stop fastllm-qwen38-tp4
for i in $(seq 1 40); do systemctl is-active --quiet fastllm-qwen38-tp4 || break; sleep 1; done
sleep 4
: > $TLOG
nohup $VPY $W/fastllm_test_launch_r5.py > $TLOG 2>&1 &
TPID=$!
echo $TPID > $W/test-r5-focus.pid
RB=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8081/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RB=1; echo "TEST_READY http=$code after ~$((i*5))s"; break; fi
  kill -0 $TPID 2>/dev/null || { echo TEST_PROCESS_DIED; break; }
  sleep 5
done
if [ "$RB" = "1" ]; then
  echo "--- LEG B2: r5 定向套件 (8081) $(date '+%T') ---"
  B0=0
  $VPY $W/ab_r5_focus.py http://127.0.0.1:8081 $W/ab-r5-focus-test.json R5_TEST || echo LEG_B_INCOMPLETE
  extract_leg $TLOG $B0 r5
  echo "-- test temps: $(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader | paste -sd/)"
else
  echo "LEG_B_NOT_READY"; tail -40 $TLOG
fi

echo "--- LEG C: stop test stack $(date '+%T') ---"
kill $TPID 2>/dev/null; sleep 10; kill -9 $TPID 2>/dev/null
for i in $(seq 1 30); do kill -0 $TPID 2>/dev/null || break; sleep 1; done
for i in $(seq 1 60); do
  used=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits -i 0)
  [ "$used" -lt 3000 ] && break
  sleep 2
done
nvidia-smi --query-gpu=index,memory.used --format=csv,noheader

echo "--- LEG C2: restore prod $(date '+%T') ---"
sudo systemctl start fastllm-qwen38-tp4
RC=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RC=1; echo "PROD_READY http=$code after ~$((i*5))s"; break; fi
  sleep 5
done
if [ "$RC" = "1" ]; then
  echo "--- LEG C3: prod 定向套件 #2 (8080) $(date '+%T') ---"
  C0=$(wc -l < $PLOG 2>/dev/null || echo 0)
  $VPY $W/ab_r5_focus.py http://127.0.0.1:8080 $W/ab-r5-focus-prodC.json PROD_C || echo LEG_C_INCOMPLETE
  extract_leg $PLOG $C0 prodC
  echo "-- prod temps: $(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader | paste -sd/)"
else
  echo "PROD_NOT_READY"; tail -40 $PLOG
fi

echo "AB_R5_FOCUS_DONE prod=$RC test=$RB $(date '+%F %T')" > $STATUS
echo "================ AB R5 FOCUS WINDOW END $(date '+%F %T') ================"
