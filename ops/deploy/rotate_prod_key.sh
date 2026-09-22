#!/bin/bash
# rotate_prod_key.sh — 轮换推理机服务 API key（只改 env 文件 + 重启 + 验证），不打印任何密钥明文。
# 前置：先跑 apply_nslog_redact.py（否则新 key 又会被写进日志）。
# 后续（手动/另一脚本）：更新 sub2api account#13 的 credentials->>'api_key'，再验中继链路。
set -u
E=/home/ai-agent/qwen38-0.2x.env
BK=$E.bak-pre-rotate-20260916
R=/home/ai-agent/fastllm-video-repro
W=/home/ai-agent/builds/upgrade-test
PLOG=$R/results/server-prod.service.log
STATUS=$W/rotate-key.status
LOG=$W/rotate-key.log
exec > >(tee -a $LOG) 2>&1
echo "===== ROTATE-KEY START $(date '+%F %T') ====="

# 0) 前置断言：launcher 确实读这个 env 文件；脱敏补丁已就位
grep -q "qwen38-0.2x.env" $R/fastllm_prod_launch.py || { echo "ABORT launcher env not this file"; echo ROTATE_ABORT_LAUNCHER > $STATUS; exit 2; }
grep -rq 'api_key": "\[REDACTED\]"' /home/ai-agent/builds/fastllm-video-venv/lib/python3.13/site-packages/ftllm || { echo "ABORT nslog patch missing"; echo ROTATE_ABORT_PATCH > $STATUS; exit 2; }

[ -f $BK ] || { cp -a $E $BK && chmod 600 $BK && echo "env backup -> $BK"; }
OLD=$(sed -n 's/^VLLM_API_KEY=//p' $E | head -1)
NEW=$(openssl rand -hex 32)
python3 - <<PY
import re
p = "$E"
s = open(p, encoding="utf-8").read()
s2, n = re.subn(r"(?m)^VLLM_API_KEY=.*$", "VLLM_API_KEY=" + "$NEW", s, count=1)
assert n == 1, "VLLM_API_KEY line not found"
open(p, "w", encoding="utf-8").write(s2)
PY
chmod 600 $E
fp() { printf '%s' "$1" | md5sum | cut -c1-8; }
echo "old: len=${#OLD} md5pfx=$(fp "$OLD")"
echo "new: len=${#NEW} md5pfx=$(fp "$NEW")"

W0=$(wc -l < $PLOG)
echo "--- restart $(date '+%T') ---"
sudo systemctl restart fastllm-qwen38-tp4
T=0
for i in $(seq 1 240); do
  code=$(curl -s -o /dev/null -m 3 -w "%{http_code}" http://127.0.0.1:8080/v1/models 2>/dev/null)
  if [ "$code" = "401" ] || [ "$code" = "200" ]; then T=$((i*5)); echo "PROD_READY after ~${T}s"; break; fi
  sleep 5
done
[ "$T" -eq 0 ] && { echo "PROD_NOT_READY"; echo ROTATE_NOT_READY > $STATUS; exit 3; }

echo "--- 密钥行为验证 ---"
NEWC=$(curl -s -o /dev/null -m 8 -w "%{http_code}" -H "Authorization: Bearer $NEW" http://127.0.0.1:8080/v1/models)
OLDC=$(curl -s -o /dev/null -m 8 -w "%{http_code}" -H "Authorization: Bearer $OLD" http://127.0.0.1:8080/v1/models)
NONEC=$(curl -s -o /dev/null -m 8 -w "%{http_code}" http://127.0.0.1:8080/v1/models)
echo "new_key=$NEWC (期望200)  old_key=$OLDC (期望401)  no_auth=$NONEC (期望401)"

echo "--- 日志脱敏验证（自重启起） ---"
printf "redacted_lines=%s  new_key_leaks=%s  old_key_leaks=%s\n" \
  "$(tail -n +$((W0+1)) $PLOG | grep -c "api_key='\[REDACTED\]'" || true)" \
  "$(tail -n +$((W0+1)) $PLOG | grep -c -- "$NEW" || true)" \
  "$(tail -n +$((W0+1)) $PLOG | grep -c -- "$OLD" || true)"

echo "--- 重启 soak 看护（它也用同一把 key） ---"
bash $W/scripts/restart_soak.sh >/dev/null 2>&1 && echo "soak restarted"
sleep 15; tail -1 $W/soak.log 2>/dev/null

OK=0
[ "$NEWC" = "200" ] && [ "$OLDC" = "401" ] && [ "$NONEC" = "401" ] && OK=1
echo "ROTATE_KEY_DONE ok=$OK new=$NEWC old=$OLDC noauth=$NONEC $(date '+%F %T')" > $STATUS
echo "下一步：把 sub2api(156) account#13 的 credentials->>'api_key' 更新为当前 env 里的新 key，再验中继。"
echo "===== ROTATE-KEY END $(date '+%F %T') ====="
