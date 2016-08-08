set feed off ver off pages 0 trims on head off
rem
rem copy any archived logs that contain sequence# higher
rem register them @dg_regs.sql
rem
set serveroutput on size 1000000
DECLARE
cursor c1 is
select db_unique_name from v$database;
v_db_unique_name varchar2(100);

-- Commented below as with reset logs it will give you wrong info
-- cursor c2 is
-- select unique thread# as thread, max(sequence#) over (partition by thread#) as last_seq
-- from v$archived_log
-- order by thread#;
-- v_thread number;
-- v_max number;

cursor c2 is
select * from (
select unique thread# as thread, max(sequence#) over (partition by RESETLOGS_TIME) as last_seq
from v$archived_log
order by thread#) where rownum = 1;
v_thread number;
v_max number;

BEGIN
open c1; fetch c1 into v_db_unique_name; close c1;
--open c2; fetch c2 into v_thread, v_max; close c2;
for r2 in c2 loop
  dbms_output.put_line('DB: '||v_db_unique_name||' - '||'Thread#: '||r2.thread||' - '||'Last Sequence: '||r2.last_seq);
end loop;
END;
/
