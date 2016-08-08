col type for a15
set lines 122
set pages 33
col item for a20
col units for a15

select to_char(start_time, 'DD-MON-RR HH24:MI:SS') start_time,
       item,  sofar, units
from v$recovery_progress
where (item='Active Apply Rate'
       or item='Average Apply Rate'
       or item='Redo Applied')
/
