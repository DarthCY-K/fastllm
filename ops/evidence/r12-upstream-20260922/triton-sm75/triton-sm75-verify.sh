#!/bin/bash
# triton-sm75-verify.sh — r12 验证：SM75 Triton GDN 预填充内核能否用 Triton 3.2.0 编出
W=/home/ai-agent/builds/upgrade-test
cd $W/wt-r12 || exit 1
LOG=$W/triton-sm75-server.log
PIDF=$W/triton-sm75-server.pid
echo "=== 1) 端口检查 ==="
ss -ltn 2>/dev/null | grep -q 48989 && echo "WARN: 48989 already in use" || echo "port 48989 free"
echo "=== 2) 启动编译服务（3.2.0 独立环境）==="
if [ -f "$PIDF" ] && kill -0 "$(cat $PIDF)" 2>/dev/null; then
  echo "already running pid=$(cat $PIDF)"
else
  setsid nohup $HOME/.venvs/fastllm-triton-sm75/bin/python tools/fastllm_triton_server.py --host 127.0.0.1 --port 48989 > "$LOG" 2>&1 < /dev/null &
  echo $! > "$PIDF"
  sleep 3
fi
echo "pid=$(cat $PIDF)"
echo "=== 3) health ==="
curl -s --max-time 8 http://127.0.0.1:48989/health; echo
echo "=== 4) POST /compile chunk_gdn_prefill (arch=75, state=fp32) ==="
START=$(date +%s)
curl -s --max-time 600 -X POST http://127.0.0.1:48989/compile -H 'Content-Type: application/json' \
  -d '{"op":"chunk_gdn_prefill","arch":75,"dtype":"fp16","state_dtype":"fp32","chunks":8,"chunk_size":64,"k_dim":128,"v_dim":128,"block_v":32,"num_warps":4,"num_stages":3}' \
  -o $W/triton-sm75-compile.json
echo "elapsed=$(( $(date +%s) - START ))s"
echo "=== 5) 结果摘要 ==="
python3 - <<'PY'
import json
p='/home/ai-agent/builds/upgrade-test/triton-sm75-compile.json'
try:
    raw=open(p).read()
    d=json.loads(raw)
    if d.get('ok'):
        print('OK=True sm75_mma=%s arch=%s dtype=%s state=%s' % (d.get('sm75_mma'), d.get('arch'), d.get('dtype'), d.get('state_dtype')))
        for k,v in (d.get('kernels') or {}).items():
            print('  kernel %-22s shared=%s warps=%s name=%s' % (k, v.get('shared'), v.get('num_warps'), v.get('kernel')))
    else:
        print('OK=False')
        print('error:', str(d.get('error'))[:800])
        tb = str(d.get('traceback') or '')
        print('traceback tail:', tb[-500:] if tb else '(none)')
except Exception as e:
    print('parse-fail:', e)
    print(raw[:1200])
PY
echo "=== 6) server 日志尾部（若有）==="
tail -5 "$LOG" 2>/dev/null
