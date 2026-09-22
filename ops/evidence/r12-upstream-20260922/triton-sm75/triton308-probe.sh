#!/bin/bash
# triton308-probe.sh — 对比实验：默认 venv（Triton 3.8.0）能否编出 SM75 GDN 内核
W=/home/ai-agent/builds/upgrade-test
cd $W/wt-r12 || exit 1
LOG=/tmp/triton38-server.log
PIDF=/tmp/triton38-server.pid
echo "=== 1) 用默认 venv（3.8.0）起服务 :48990 ==="
if [ -f "$PIDF" ] && kill -0 "$(cat $PIDF)" 2>/dev/null; then
  echo "already pid=$(cat $PIDF)"
else
  setsid nohup /home/ai-agent/builds/fastllm-video-venv/bin/python tools/fastllm_triton_server.py --host 127.0.0.1 --port 48990 > "$LOG" 2>&1 < /dev/null &
  echo $! > "$PIDF"
  sleep 3
fi
echo "pid=$(cat $PIDF)"
echo "=== 2) health ==="
curl -s --max-time 8 http://127.0.0.1:48990/health; echo
echo "=== 3) POST /compile（与 3.2.0 实验同 payload）==="
curl -s --max-time 300 -X POST http://127.0.0.1:48990/compile -H 'Content-Type: application/json' \
  -d '{"op":"chunk_gdn_prefill","arch":75,"dtype":"fp16","state_dtype":"fp32","chunks":8,"chunk_size":64,"k_dim":128,"v_dim":128,"block_v":32,"num_warps":4,"num_stages":3}' \
  -o /tmp/triton38-compile.json
echo "=== 4) 结果 ==="
python3 - <<'PY'
import json
try:
    d=json.load(open('/tmp/triton38-compile.json'))
    if d.get('ok'):
        print('OK=True sm75_mma=%s' % d.get('sm75_mma'))
    else:
        print('OK=False')
        print('error:', str(d.get('error'))[:400])
        tb=str(d.get('traceback') or '')
        print('traceback tail:', tb[-400:] if tb else '(none)')
except Exception as e:
    print('parse-fail:', e)
    print(open('/tmp/triton38-compile.json').read()[:500])
PY
echo "=== 5) 3.8.0 AttrsDescriptor 存在性 ==="
/home/ai-agent/builds/fastllm-video-venv/bin/python -c "
import triton
print('triton', triton.__version__)
try:
    from triton.backends.compiler import AttrsDescriptor
    print('AttrsDescriptor: EXISTS')
except Exception as e:
    print('AttrsDescriptor: MISSING ->', type(e).__name__, e)
"
echo "=== 6) server 日志 ==="
tail -8 "$LOG" 2>/dev/null
