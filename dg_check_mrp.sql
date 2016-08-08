set time on
set lines 132
set pagesize 9999
col client_pid format a12
SELECT PID, PROCESS, STATUS, 
       CLIENT_PROCESS, CLIENT_PID, 
       THREAD#, SEQUENCE#, BLOCK#, 
       BLOCKS, DELAY_MINS 
FROM V$MANAGED_STANDBY
;
