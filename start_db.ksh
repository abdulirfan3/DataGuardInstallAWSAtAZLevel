#!/bin/ksh
#
#
##########################################################################
#
# USAGE:        start_db.ksh  ORACLE_SID
#
# PARAMETER(S): 1
#
# AUTHOR:       Satya Sridhar @ Kelloggs
#
# DESCRIPTION:  Start up the specified Oracle Instance.
#
# REQUIREMENTS: This script has to be run as the "oracle"/"dba" user.
#               This script requires 1 argument/parameter.
#               Requires the standard Oracle "/etc/oratab" file.
#               Assumes the existence of the /oracle/sqlutils directory (can be changed) and
#               Must have read/write access to that directory.
#
# COMMENTS:     SS - 02/11/2004 - Created.
#
# UPDATE #1:    Abdul Mohammed - Feb/2016
#
#               Added logic to support Data guard.  If DB role is PRIMARY then open database
#               If DB role is Physical standby, start media recovery..
#
##########################################################################

##########################################################################
# Check usage.
##########################################################################
#
if [ ! $# -eq 1 ]; then
        echo
        echo "Error: Usage = `basename ${0}` SID"
        echo
        return -1
fi

##########################################################################
# Save script parameter(s) into variables.
##########################################################################
SID=$1

##########################################################################
# Set environment/other variables.
##########################################################################
LOGDIR=/oracle/sqlutils/logs
LOG=${LOGDIR}/start_db_"$SID"_`date "+%m%d%y_%H%M%S"`.log
SPOOL_FILE=${LOGDIR}/spool_dbstart.log
ORATAB=/etc/oratab

export ORACLE_SID=$SID
export ORACLE_HOME=`grep -i $ORACLE_SID: $ORATAB | grep -v "^#" | cut -f2 -d:`
export PATH=$ORACLE_HOME/bin:$PATH
export SHLIB_PATH=$ORACLE_HOME/lib
export LD_LIBRARY_PATH=$ORACLE_HOME/lib

##########################################################################
# Change directory to the desired location of the logs.
##########################################################################

cd /oracle/sqlutils

rm ${LOGDIR}/start_db_"$ORACLE_SID"*.log

##########################################################################
# Check if the temporary spool file exists. Perform cleanup before starting.
##########################################################################
if [ -f $SPOOL_FILE ]; then
        rm $SPOOL_FILE >/dev/null 2>&1
fi

##########################################################################
# Startup the database in mount mode and record startup time.
##########################################################################
echo | tee -a $LOG
sqlplus -s /nolog << EOF | tee -a $LOG

        connect / as SYSDBA

        startup mount;
        set echo off
        set head off
        set feedback off
        set verify off
        set linesize 80
        set pagesize 1
        spool $SPOOL_FILE
        select 'Started database in MOUNT mode...' from dual;
        select 'DataBase :  ' || instance_name || ' - Started at -> ' || to_char(startup_time,'MM-DD-YYYY HH24:MI:SS') from v\$instance;
        spool off
        exit
EOF

# Start of new update, added logic to support data guard
DB_ROLE='select database_role from v$database;'
LOCAL_DB_ROLE=`echo $DB_ROLE | sqlplus -S / as sysdba | tail -2|head -1`

if [ "$LOCAL_DB_ROLE" = "PRIMARY" ]
then
echo "Database Role is PRIMARY"
sqlplus -s /nolog << EOF | tee -a $LOG

        connect / as SYSDBA
        set echo off
        set head off
        set feedback off
        set verify off
        set linesize 80
        set pagesize 1
        select 'Starting database in OPEN mode...' from dual;
        alter database open;
        spool $SPOOL_FILE append;
        select 'Started database in OPEN mode...' from dual;
        spool off
        exit
EOF
elif [ "$LOCAL_DB_ROLE" = "PHYSICAL STANDBY" ]
then
echo "Database Role is PHYSICAL STANDBY"
sqlplus -s /nolog << EOF | tee -a $LOG

        connect / as SYSDBA
        set echo off
        set head off
        set feedback off
        set verify off
        set linesize 80
        set pagesize 1
        select 'Starting database recovery as its a Physical Staandby....' from dual;
        alter database recover managed standby database using current logfile disconnect;
        spool $SPOOL_FILE append;
        select 'Started database recovery....' from dual;
        spool off
        exit
EOF
fi

#
##########################################################################
# Save database startup time info in a cumulative file.
##########################################################################
#
cat $SPOOL_FILE >> ${LOGDIR}/`hostname`_db_start.log

rm $SPOOL_FILE

exit
