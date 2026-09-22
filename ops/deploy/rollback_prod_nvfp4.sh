#!/bin/bash
# rollback_prod_nvfp4.sh — 回滚：把生产 argv 恢复为 ET-FP8 基线并重启，等就绪。
set -u
R=/home/ai-agent/fastllm-video-repro
A=$R/results/argv-prod-tp4.json
BK=$A.bak-pre-nvfp4-20260916
W=/home/ai-agent/builds/upgrade-test
PLOG=$R/results/server-prod.service.log
STATUS=$W/rollback-nvfp4.status
[ -f $BK ] || { echo "NO_BACKUP"; exit 2; }
echo "===== ROLLBACK-NVFP4 START $(date '+%F %T') ====="
cp -a $BK $A
python3 -c "import json;print('argv model path =', [x for x in json.load(open('$A'))['argv'] if 'models/' in x or 'staging/' in x][0])"
W0=$(wc -l < $PLOG)
sudo systemctl restart fastllm-qwen38-tp4
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then
    echo "ROLLBACK_READY http=$code after ~$((i*5))s"
    tail -n +$((W0+1)) $PLOG | grep -E "AutoWarmup GPU 0|DFlash2\] enabled" | head -3
    echo "ROLLBACK_DONE $(date '+%F %T')" > $STATUS
    exit 0
  fi
  sleep 5
done
echo "ROLLBACK_NOT_READY"; echo "ROLLBACK_FAILED" > $STATUS; exit 1
