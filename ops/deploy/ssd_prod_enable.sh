#!/bin/bash
# ssd_prod_enable.sh — 产线启用 SSD 持久前缀缓存（#747）并做跨重启 e2e 复验
set -u
trap "" HUP
W=/home/ai-agent/builds/upgrade-test
VPY=/home/ai-agent/builds/fastllm-video-venv/bin/python
PLOG=/home/ai-agent/fastllm-video-repro/results/server-prod.service.log
STATUS=$W/ssd-prod.status
exec > >(tee -a $W/ssd-prod.log) 2>&1
echo "===== SSD-PROD ENABLE START $(date '+%F %T') ====="
S0=$(wc -l < $PLOG)
echo "--- restart #1 (SSD on) $(date '+%T') ---"
sudo -S -p '' systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "READY ~$((i*5))s"; break; fi
  sleep 5
done
[ "$RP" = "1" ] || { echo "SSD_PROD_FAILED ready=0 stage=restart1" > $STATUS; exit 5; }
echo "--- startup window SSD/Traceback lines ---"
tail -n +$((S0+1)) $PLOG | grep -aE "Prefix SSD|Traceback" | head -8
echo "--- probe1 (md5 parity) ---"
$VPY $W/trial_probe2.py http://127.0.0.1:8080 $W/ssd-prod-probe1.json || echo PROBE1_INCOMPLETE
echo "--- ssd e2e run1 cold $(date '+%T') ---"
$VPY $W/scripts/ssd_prefix_probe.py http://127.0.0.1:8080 ssdprod-run1-cold 2>&1 | tail -1
echo "--- wait committed (<=150s) ---"
C=0
for i in $(seq 1 30); do C=$(tail -n +$((S0+1)) $PLOG | grep -ac "Prefix SSD. committed"); [ "$C" -ge 1 ] && break; sleep 5; done
echo "committed_count=$C"
tail -n +$((S0+1)) $PLOG | grep -a "Prefix SSD. committed" | tail -2
S1=$(wc -l < $PLOG)
echo "--- restart #2 (persistence test) $(date '+%T') ---"
sudo -S -p '' systemctl restart fastllm-qwen38-tp4
RP=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then RP=1; echo "READY ~$((i*5))s"; break; fi
  sleep 5
done
[ "$RP" = "1" ] || { echo "SSD_PROD_FAILED ready=0 stage=restart2" > $STATUS; exit 6; }
echo "--- ssd e2e run2 (expect restored) $(date '+%T') ---"
$VPY $W/scripts/ssd_prefix_probe.py http://127.0.0.1:8080 ssdprod-run2-restart 2>&1 | tail -1
echo "--- restored/loaded lines ---"
tail -n +$((S1+1)) $PLOG | grep -aE "Prefix SSD. (loaded|restored)" | tail -3
echo "--- probe2 (md5 parity after restore) ---"
$VPY $W/trial_probe2.py http://127.0.0.1:8080 $W/ssd-prod-probe2.json || echo PROBE2_INCOMPLETE
echo "errors_w1=$(tail -n +$((S0+1)) $PLOG | head -n $((S1-S0)) | grep -ac 'FastLLM Error') errors_w2=$(tail -n +$((S1+1)) $PLOG | grep -ac 'FastLLM Error')"
echo "desync=$(tail -n +$((S0+1)) $PLOG | grep -ac 'draft cache is not aligned')"
echo "ssd_dir=$(du -sh /home/ai-agent/prefix_ssd_prod 2>/dev/null | cut -f1) files=$(find /home/ai-agent/prefix_ssd_prod -type f 2>/dev/null | wc -l)"
echo "SSD_PROD_DONE ready=$RP" > $STATUS
cat $STATUS
echo "===== SSD-PROD ENABLE END $(date '+%F %T') ====="
