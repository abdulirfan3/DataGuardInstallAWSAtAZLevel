#!/bin/bash
#
# Script to monitor data guard transport/apply lag.  Below we choose to have archive log
# latency of 5.  If its > than 5 we get an email alert
#
# USAGE:        dataguard_lag.sh SID
#
# PARAMETER(S): SID - Database Name
#

#################################################
# Output Directory Variable and other variables #
#################################################

LOGDIR=/oracle/sqlutils/logs; export LOGDIR
DBA_GROUP=email@domain.com; export DBA_GROUP
SITE=`hostname`; export SITE

#############################################################
# Find the oratab file. If none, assume no Oracle and quit. #
#############################################################
if [ -f /var/opt/oracle/oratab ]; then
  ORATAB=/var/opt/oracle/oratab
elif [ -f /etc/oratab ]; then
  ORATAB=/etc/oratab
else
  echo "ERROR: Could not find oratab file" | mailx -s "DataGuard Standby check failed on $SITE" $DBA_GROUP
  exit 1
fi

###########################################
# Check if First parameter(SID) is passed #
###########################################
if [ $1 ];then
  ORACLE_SID=$1;export ORACLE_SID
else
  echo "NO ORACLE SID PROVIDED CHECK SCRIPT USAGE ON $SITE" | mailx -s "DataGuard Standby check failed on $SITE" $DBA_GROUP
  exit 1
fi

#########################################################################
#  Look through oratab file(for Oracle Home) SID                        #
#########################################################################

export ORACLE_HOME=`grep -i $ORACLE_SID: ${ORATAB}|grep -v "^#" | cut -f2 -d:`
export PATH=$ORACLE_HOME/bin:$PATH

export LOG_FILE=$LOGDIR/check_arch_gap_${ORACLE_SID}.log

echo > $LOG_FILE

# Make sure DB is in primary role
DB_ROLE='select database_role from v$database;'
LOCAL_DB_ROLE=`echo $DB_ROLE | sqlplus -S / as sysdba | tail -2|head -1`

if [ "$LOCAL_DB_ROLE" = "PRIMARY" ]
then

  #Problem statement is constructed in message variable
  MESSAGE=""

  #SQL statements to extract Data Guard info from DB
  SWITCH='alter system switch logfile;'
  LOCAL_ARC_SQL='select archived_seq# from V$ARCHIVE_DEST_STATUS where dest_id=1;'
  STBY_ARC_SQL='select archived_seq# from V$ARCHIVE_DEST_STATUS where dest_id=2;'
  STBY_APPLY_SQL='select applied_seq# from V$ARCHIVE_DEST_STATUS where dest_id=2;'

  #Get Data guard information to Unix shell variables...
  echo $SWITCH | sqlplus -S / as sysdba
  LOCAL_ARC=`echo $LOCAL_ARC_SQL | sqlplus -S / as sysdba | tail -2|head -1`
  STBY_ARC=`echo $STBY_ARC_SQL | sqlplus -S / as sysdba | tail -2|head -1`
  STBY_APPLY=`echo $STBY_APPLY_SQL | sqlplus -S / as sysdba | tail -2|head -1`

  #Allow 5 archive logs for transport and Apply latencies...
  let "STBY_ARC_MARK=${STBY_ARC}+5"
  let "STBY_APPLY_MARK= ${STBY_APPLY}+5"

  if [ "$LOCAL_ARC" -gt "$STBY_ARC_MARK" ] ; then
    MESSAGE=${MESSAGE}"DataGuard for $ORACLE_SID on $SITE - TRANSPORT error.. local_Arc_No=$LOCAL_ARC but stby_Arc_No=$STBY_ARC"
  fi

  if [ "$STBY_ARC" -gt "$STBY_APPLY_MARK" ] ; then
    MESSAGE=${MESSAGE}"DataGuard for $ORACLE_SID on $SITE - APPLY error... stby_Arc_No=$STBY_ARC but stby_Apply_no=$STBY_APPLY"
  fi

  if [ -n "$MESSAGE" ] ; then
    echo "Date: `date` " >> $LOG_FILE
    echo "Database: $ORACLE_SID" >> $LOG_FILE
    echo $MESSAGE >> $LOG_FILE
    echo $MESSAGE | mailx -s "DataGuard error on $SITE" $DBA_GROUP
  else
    echo "Date: `date` " >> $LOG_FILE
    echo "Database: $ORACLE_SID" >> $LOG_FILE
    echo "No issues found during last check">> $LOG_FILE
  fi
else
    echo "Date: `date` " >> $LOG_FILE
    echo "Database: $ORACLE_SID" >> $LOG_FILE
    echo "Database does not seem to be in proper state..." >> $LOG_FILE
    echo "This should always run on primary database..." >> $LOG_FILE
    echo "But can stay in place if there is a switch/fail over and this DB becomes primary" >> $LOG_FILE
fi
