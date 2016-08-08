col type format a8
col member format a50
set linesize 200
select group#,type,member from v$logfile;
