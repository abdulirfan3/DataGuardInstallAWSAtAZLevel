#!/bin/ksh
#
##########################################################################
#
# USAGE:        stop_db.ksh  ORACLE_SID
#
# PARAMETER(S): 1
#
# AUTHOR:       Satya Sridhar @ Kelloggs
#
# DESCRIPTION:  Shutdown the specified Oracle Instance.
#
# REQUIREMENTS: This script has to be run as the "oracle"/"dba" user.
#               This script requires 1 argument/parameter.
#               Requires the standard Oracle "/etc/oratab" file.
#               Assumes the existence of the /oracle/sqlutils directory (can be changed) and
#               Must have read/write access to that directory.
#
# COMMENTS:     SS - 02/11/2004 - Created.
#
#
##########################################################################

#
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


#
##########################################################################
# Save script parameter(s) into variables.
##########################################################################
#
SID=$1


#
##########################################################################
# Set environment/other variables.
##########################################################################
#
LOGDIR=./logs
LOG=${LOGDIR}/shutdown_db_"$SID"_`date "+%m%d%y_%H%M%S"`.log
SPOOL_FILE=${LOGDIR}/spool_dbshut.log
ORATAB=/etc/oratab

export ORACLE_SID=$SID
export ORACLE_HOME=`grep -i $ORACLE_SID: $ORATAB | grep -v "^#" | cut -f2 -d:`
export PATH=$PATH:$ORACLE_HOME/bin
export SHLIB_PATH=$ORACLE_HOME/lib


#
##########################################################################
# Change directory to the desired location of the logs.
##########################################################################
#
cd /oracle/sqlutils

rm ${LOGDIR}/shutdown_db_"$ORACLE_SID"*.log

#
##########################################################################
# Check if the temporary spool file exists. Perform cleanup before starting.
##########################################################################
#
if [ -f $SPOOL_FILE ]; then
        rm $SPOOL_FILE
fi


#
##########################################################################
# Shutdown the database and record shutdown time.
##########################################################################
#
echo | tee -a $LOG

sqlplus -s /nolog << EOF | tee -a $LOG

        connect / as SYSDBA

        set echo off
        set head off
        set feedback off
        set verify off
        set linesize 80
        set pagesize 1

        spool $SPOOL_FILE

        select 'DataBase :  ' || instance_name || ' - Shutdown at -> ' || to_char(sysdate,'MM-DD-YYYY HH24:MI:SS') from v\$instance, dual;

        spool off

        shutdown immediate

        exit

EOF


#
##########################################################################
# Save database shutdown time info in a cumulative file.
##########################################################################
#
cat $SPOOL_FILE >> ${LOGDIR}/`hostname`_db_shut.log

rm $SPOOL_FILE

exit

