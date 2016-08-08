col name for a13
col value for a20
col unit for a30
set lines 122
SELECT NAME, VALUE, UNIT, TIME_COMPUTED
FROM V$DATAGUARD_STATS
WHERE NAME IN ('transport lag', 'apply lag');

