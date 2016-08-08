#!/bin/ksh
#
#
##########################################################################
#
# USAGE:        stop_listener.ksh  ORACLE_SID
#
# PARAMETER(S): 1
#
# AUTHOR:       Satya Sridhar @ Kelloggs
#
# DESCRIPTION:  Stop the specified Oracle listener.
#
# REQUIREMENTS: This script has to be run as the "oracle"/"dba" user.
#               This script requires 1 argument/parameter.
#               Requires the standard Oracle "/etc/oratab" file.
#               Assumes the existence of the /oracle/sqlutils directory (can be changed) and
#               Must have read/write access to that directory.
#
# COMMENTS:     SS - 02/10/2004 - Created.
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
LOG=${LOGDIR}/start_listener_"$SID"_`date "+%m%d%y_%H%M%S"`.log
SPOOL_FILE=${LOGDIR}/spool_stop_listener.log
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

#
##########################################################################
# Stop the Oracle listener.
##########################################################################
#
lsnrctl stop LISTENER_${SID} > $SPOOL_FILE

#
##########################################################################
# Save listener stop time info in a cumulative file.
##########################################################################
#
cat $SPOOL_FILE >> ${LOGDIR}/`hostname`_listener_stop.log

rm $SPOOL_FILE

exit
