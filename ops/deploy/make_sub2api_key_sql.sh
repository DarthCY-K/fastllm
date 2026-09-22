#!/bin/bash
# make_sub2api_key_sql.sh — 用当前 env 里的生产 key 生成 sub2api(156) 的 UPDATE SQL（文件 600，用完即毁）。
# 输出 /tmp/sub2api_update_key.sql，绝不回显密钥。
set -u
E=/home/ai-agent/qwen38-0.2x.env
OUT=/tmp/sub2api_update_key.sql
K=$(sed -n 's/^VLLM_API_KEY=//p' $E | head -1 | tr -d '"')
chmod 600 $E
[ ${#K} -eq 64 ] || { echo "KEY_LEN_UNEXPECTED=${#K}"; exit 2; }
umask 077
printf "update accounts set credentials = jsonb_set(credentials, '{api_key}', to_jsonb('%s'::text)), updated_at = now() where id = 13;\n" "$K" > $OUT
printf "select id, name, credentials->>'base_url' as base_url, length(credentials->>'api_key') as key_len, left(md5(credentials->>'api_key'),8) as key_pfx from accounts where id=13;\n" >> $OUT
chmod 600 $OUT
ls -l $OUT
echo "SQL_READY key_len=${#K} md5pfx=$(printf '%s' "$K" | md5sum | cut -c1-8)"
