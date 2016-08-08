set serveroutput on size 1000000
set lines 132
set pagesize 9999 feed off ver off trims on
DECLARE
cursor c1 is
select db_unique_name from v$database;
v_db_unique_name VARCHAR2(100);

cursor c2 is
select thread#, low_sequence#, high_sequence# 
from v$archive_gap;

cursor c3 is
select max(r.sequence#) last_seq_received, max(l.sequence#) last_seq_sent 
from v$archived_log r, v$log l
where r.dest_id = 2 
and l.archived= 'YES';
v_last_seq_received NUMBER;
v_last_seq_sent NUMBER;

BEGIN
open c1; fetch c1 into v_db_unique_name; close c1;
-- open c3; fetch c3 into v_last_seq_received, v_last_seq_sent; close c3;

dbms_output.put_line('# ---------------------------------------------------- #');
dbms_output.put_line('DB Unique Name: '|| v_db_unique_name);
-- if v_last_seq_received is not null then
--   dbms_output.put_line('Last Archive Received: '||v_last_seq_received);
-- end if;
-- if v_last_seq_sent is not null then
--   dbms_output.put_line('Last Archive Sent: '||v_last_seq_sent);
-- end if;

for r2 in c2 loop
  dbms_output.put_line('Gap Detected for thread#: '||r2.thread# ||' - ' ||'Low: '||r2.low_sequence#||' - '||'High: '||r2.high_sequence#);
end loop;

dbms_output.put_line('# ---------------------------------------------------- #');
END;
/
