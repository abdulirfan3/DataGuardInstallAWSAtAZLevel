set pages 0 feed off ver off trims on echo off
select 'starting database recovery....' from dual;
alter database recover managed standby database using current logfile disconnect;
select 'sleeping 60 seconds to query media recovery process...' from dual;
host sleep 60;
set lines 300;
select 'make sure media recovery process is running(look for MRP0 process)...' from dual;
set pages 100 feed on ver on
select process,status,client_process,sequence#,THREAD#,block#,active_agents,known_agents from v$managed_standby;
