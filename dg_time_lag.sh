#!/bin/bash
. $PWD/dg_connect.sh
set_path_sid
check_sys_pass;
export DR_LOG=p.log
export LOG=dr.log

[ -f $DR_LOG ] && rm $DR_LOG
[ -f $LOG ] && rm $LOG

echo "Printing Standby Current SCN and Primary Current SCN"
#echo "set echo off ver off feed off head off pages 0;
#select current_scn from v\$database;" |
#   sqlplus -s "sys/${SYSPASSWD}@${STANDBY_HOST}:${STANDBY_PORT}/${STANDBY_DB} as sysdba" |
monitor_sql_s dg_current_scn.sql | tee $DR_LOG

#echo "set echo off ver off feed off head off pages 0;
#select current_scn from v\$database;" |
#    sqlplus -s "sys/${SYSPASSWD}@${PRIMARY_HOST}:${PRIMARY_PORT}/${PRIMARY_DB} as sysdba" |
monitor_sql_p dg_current_scn.sql | tee $LOG

echo ""
export DR_SCN=$(tail -1 $DR_LOG |sed -e 's/ //g')
export SCN=$(tail -1 $LOG |sed -e 's/ //g')
echo "DR_SCN:  $DR_SCN"
echo "SCN:  $SCN"

# Convert SCN to timestamp on the Primary DB
echo "Printing Standby Current SCN To Timestamp and Primary Current SCN To Timestamp"
#echo "set echo off ver off feed off head off pages 0;
#select scn_to_timestamp(current_scn) from v\$database;" |
#    sqlplus -s "sys/${SYSPASSWD}@${PRIMARY_HOST}:${PRIMARY_PORT}/${PRIMARY_DB} as sysdba" 
monitor_sql_p dg_scn_to_timestamp.sql

echo "set echo off ver off feed off head off pages 0;
select scn_to_timestamp(${DR_SCN}) from dual;" |
sqlplus  -s sys/$syspass@${ORACLE_SID}_P as sysdba

echo "set echo off ver off feed off 
      set lines 122
      col Primary for a32
      col DR for a32
      col wks for 999
      col days for 9999
select scn_to_timestamp(${SCN}) Primary
      ,scn_to_timestamp(${DR_SCN}) DR
      ,trunc(to_number(substr((scn_to_timestamp(${SCN})-scn_to_timestamp(${DR_SCN})),1,instr(scn_to_timestamp(${SCN})-scn_to_timestamp(${DR_SCN}),' ')))/7) Wks
      ,trunc(to_number(substr((scn_to_timestamp(${SCN})-scn_to_timestamp(${DR_SCN})),1,instr(scn_to_timestamp(${SCN})-scn_to_timestamp(${DR_SCN}),' '))))   Days
      ,substr((scn_to_timestamp(${SCN})-scn_to_timestamp(${DR_SCN})),instr((scn_to_timestamp(${SCN})-scn_to_timestamp(${DR_SCN})),' ')+1,2)                 Hrs
      ,substr((scn_to_timestamp(${SCN})-scn_to_timestamp(${DR_SCN})),instr((scn_to_timestamp(${SCN})-scn_to_timestamp(${DR_SCN})),' ')+4,2)                 Mins
      ,substr((scn_to_timestamp(${SCN})-scn_to_timestamp(${DR_SCN})),instr((scn_to_timestamp(${SCN})-scn_to_timestamp(${DR_SCN})),' ')+7,2)                 Secs
from dual;" |
sqlplus  -s sys/$syspass@${ORACLE_SID}_P as sysdba