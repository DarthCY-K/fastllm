\pset pager off
\pset border 2
\echo === 复位 account#13（轮换导致的自动禁用）===
update accounts
   set status = 'active',
       schedulable = true,
       error_message = null,
       temp_unschedulable_until = null,
       temp_unschedulable_reason = null,
       updated_at = now()
 where id = 13;
\echo === 复核 ===
select id, name, status, schedulable, error_message,
       credentials->>'base_url' as base_url,
       length(credentials->>'api_key') as key_len,
       left(md5(credentials->>'api_key'),8) as key_pfx
  from accounts where id = 13;
