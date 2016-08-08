#!/bin/bash
#
######################################################################################
#
#************************************************************************************
#***THIS SCRIPT SHOULD ONLY BE USED FOR SYSTEM THAT HAVE DATA GUARD IN PLACE AND IS A STANDBY HOST
#************************************************************************************
#
# USAGE:        RMAN_archivelog_deletion_standby_dg.sh SID
#
# PARAMETER(S): SID - Database Name
#
# AUTHOR:       Abdul Mohammed 
#
# DESCRIPTION:  This script will use RMAN to delete archivelog
#               which are NOT needed anymore since they have been applied on STANDBY
# 
#               As we are using NBU to send back to S3, we set the below policy on the PRIMARY 
#               inside RMAN (and hence the SBT devie in below policy)
#               configure archivelog deletion policy to shipped to all standby backed up 1 times to device type sbt;
#
#               On STANDBY we set below policy insdie RMAN
#               configure archivelog deletion policy to applied on all standby;
#
#               So when we run the below script RMAN will delete all archive logs on STANDBY
#               only if it has been applied(recover database)
#
# REQUIREMENTS: Database must be in ARCHIVELOG mode and this should be a PHYSCIAL STANDBY
#
#
########################################################################################

#################################################
# Output Directory Variable and other variables #
#################################################

TODAY=`date '+%C%y_%m_%d_%H_%M'`; export TODAY
LOGDIR=/oracle/sqlutils/logs; export LOGDIR
DBA=email@domain.com; export DBA
NLS_DATE_FORMAT='dd-mon-yyyy hh24:mi:ss'; export NLS_DATE_FORMAT
SITE=`hostname`; export SITE
USER_ID=`whoami`; export USER_ID
OS=`uname`; export OS
THRESHOLD=55

###################################################################
# This is done to run script on HP as well as Linux               #
# As hp uses "bdf" cmd and linux uses "df -h" cmd for disk space  #
###################################################################
  if test "$OS" = "HP-UX"
  then
    DISKCHK='bdf'
  elif
    test "$OS" = "Linux"
  then
    DISKCHK='df -h'
  fi

#############################################################
# Find the oratab file. If none, assume no Oracle and quit. #
#############################################################
  if [ -f /var/opt/oracle/oratab ]; then
    ORATAB=/var/opt/oracle/oratab
  elif [ -f /etc/oratab ]; then
    ORATAB=/etc/oratab
  else
    echo "ERROR: Could not find oratab file" | mailx -s "RMAN Archivelog deletion Failed on $SITE" $DBA
    exit 1
  fi

###########################################
# Check if First parameter(SID) is passed #
###########################################
  if [ $1 ];then
    ORACLE_SID=$1;export ORACLE_SID
  else
    echo "NO ORACLE SID PROVIDED CHECK SCRIPT USAGE ON $SITE" | mailx -s "RMAN Archivelog deletion Failed on $SITE" $DBA
    exit 1
  fi


#########################################################################
#  Look through oratab file(for Oracle Home) SID                        #
#########################################################################

export ORACLE_HOME=`grep -i $ORACLE_SID: ${ORATAB}|grep -v "^#" | cut -f2 -d:`
export PATH=$ORACLE_HOME/bin:$PATH
export ORACLE_USER=`ls -al ${ORACLE_HOME}/bin/rman|awk '{print $3}'`

#########################################################################
# check who owns ORACLE RMAN exe, If the script                         #
# is being ran by the same user as oracle_user then proceed with backup #
# else exit the backup and send email(look near end of the script)      #
#########################################################################

if test $ORACLE_USER = $USER_ID; then

############################################################################
# Initialize a Temp Log file to capture DB status, Arch Dest and to see if #
# Redo job needs to run or not(Below threshold limit)                      #
############################################################################

TMP_LOG=$LOGDIR/arch_delete_status_standby_$ORACLE_SID
echo > $TMP_LOG
echo "THIS IS FOR STANDBY DATABASE (USING DATA GUARD)" >> $TMP_LOG
echo >> $TMP_LOG

##############################################################################
# Get the DB status, archive log Destination, count of archive log dest and  #
# also check if there is a a session with client_info set to                 #
# "flag_arch_delete_in_progress_standby", This acts like a flag file to see if we    #
# need to start another backup or not                                        #
##############################################################################
sqlplus -s /nolog <<EOF >> $TMP_LOG
set heading off pagesize 0 feedback off linesize 200
whenever sqlerror exit 1
conn / as sysdba
select 'Database Name: '||instance_name||  ', Database status: '|| status
from v\$instance;
select 'DB-ROLE:' || database_role from v\$database;
col dest_name format a25
col status format a10
col destination format a80;
select dest_name,status,destination
from v\$archive_dest
where destination is not null;
select substr(client_info,4,28) from v\$session
where client_info='id=flag_arch_delete_in_progress_standby';
EOF

############################################################################
# Check if a arch backup is already in progress.  If it is then exit       #
# so we do not start archive backup job every 5 mins, this is done by      #
# setting RMAN "set command id to flag_arch_delete_in_progress_standby" for the    #
# RMAN session already in progess                                          #
############################################################################

  if grep "flag_arch_delete_in_progress_standby" $TMP_LOG
  then
    echo >> $TMP_LOG
    echo "Date: `date` " >> $TMP_LOG
    echo "Archive deletion is still running for $ORACLE_SID ...."  >> $TMP_LOG
    echo "Not starting a new archive deletion session ...." >> $TMP_LOG
    exit 0
  fi

#################################################################
# Initialize the RMAN log file and start of this script         #
# Check to see if DB is up/down, if DB is down then exit script #
# No need to send any alerts/email, as we have other script that#
# dose this work(usoak002 monitoring script)                    #
#################################################################

  export RMAN_LOG_FILE=$LOGDIR/RMAN_dlt_arch_standby_${ORACLE_SID}_${TODAY}.log

  echo > $RMAN_LOG_FILE

  echo Script $0 >> $RMAN_LOG_FILE
  echo ==== started on `date` ==== >> $RMAN_LOG_FILE
  echo >> $RMAN_LOG_FILE
  echo "Deleting Archivelog for Database: $ORACLE_SID using RMAN ..." >> $RMAN_LOG_FILE

if grep "PHYSICAL STANDBY" $TMP_LOG
then 
  if grep "MOUNTED" $TMP_LOG
  then
    echo "Database: $ORACLE_SID is mounted" >> $RMAN_LOG_FILE
  else
    echo "Database: $ORACLE_SID is down on $SITE -- aborting script" >> $TMP_LOG
    #Remove logfile, otherwise we will have empty logfile every 5 mins
    rm $RMAN_LOG_FILE
    #cat $TMP_LOG|mailx -s "RMAN error $ORACLE_SID, DB DOWN..." $DBA
    exit 1
  fi
else
  echo "Database: $ORACLE_SID does not seem to be a PHYSICAL STANDBY" >> $TMP_LOG
  echo "Database: $ORACLE_SID does not seem to be a PHYSICAL STANDBY" 
  echo "This script SHOULD ONLY be ran on STANDBY database -- aborting script" >> $TMP_LOG
  echo "This script SHOULD ONLY be ran on STANDBY database -- aborting script"
  exit 1
fi 

#################################################################
# Status check is done for combination of VALID OR ERROR,       #
# when found disk % check is done on disabled file system only  #
#################################################################

      ARCHIVE_DEST=`cat $TMP_LOG|grep -E "LOG_ARCHIVE_DEST_1"|awk '{print $3}'`

      $DISKCHK $ARCHIVE_DEST 2>/dev/null
      DEST_STAT=$?

        if [ "$DEST_STAT" = "0" ]
        then
          # Print last field/row in second to last column
          DEST_PRCT=`$DISKCHK $ARCHIVE_DEST|awk '{ field = $(NF-1) }; END{ print field }'`
        else
          ARCHIVE_DEST=`cat $TMP_LOG|grep -E "LOG_ARCHIVE_DEST_1"|awk '{print $3}'|awk -F/ '{gsub($NF,"");sub(".$", "");print}'`
          DEST_PRCT=`$DISKCHK $ARCHIVE_DEST|awk '{ field = $(NF-1) }; END{ print field }'`
        fi

          if [ ${DEST_PRCT%\%} -ge $THRESHOLD ]; then
            echo >> $TMP_LOG
            echo "Date: `date` " >> $TMP_LOG
            echo "Archive deletion started for $ORACLE_SID" >> $TMP_LOG
          else
            echo >> $TMP_LOG
            echo "Date: `date` " >> $TMP_LOG
            echo "Threshold is set to $THRESHOLD% and archive log dest is at $DEST_PRCT" >> $TMP_LOG
            echo "No need to run arch deletion for database:$ORACLE_SID as file system is less then threshold" >> $TMP_LOG
            # No need to keep the initialized RMAN_LOG_FILE as no backup is going to run
            rm $RMAN_LOG_FILE
            exit 0
          fi

##################################################################
# Set the Oracle Recovery Manager name and target connect string #
##################################################################
  TARGET_CONNECT_STR=/
  RMAN=$ORACLE_HOME/bin/rman

############################################################
# Print out the value of the variables set by this script. #
############################################################

  echo >> $RMAN_LOG_FILE
  echo   "RMAN: $RMAN" >> $RMAN_LOG_FILE
  echo   "ORACLE_SID: $ORACLE_SID" >> $RMAN_LOG_FILE
  echo   "ORACLE_USER: $ORACLE_USER" >> $RMAN_LOG_FILE
  echo   "ORACLE_HOME: $ORACLE_HOME" >> $RMAN_LOG_FILE
  echo   "TARGET_CONNECT_STR: $TARGET_CONNECT_STR" >> $RMAN_LOG_FILE
# Uncomment BELOW line for debug purpose only
# echo   "PATH: $PATH" >> $RMAN_LOG_FILE
  echo   "NLS_DATE_FORMAT: $NLS_DATE_FORMAT" >> $RMAN_LOG_FILE


##################################################################
#  Backs up the archive log.                                     #
#  Archive logs are deleted by RMAN once "backup piece" finishes #
##################################################################

$RMAN target ${TARGET_CONNECT_STR} << EOF >> $RMAN_LOG_FILE
set echo on;
list archivelog all;
RUN {
# Set RMAN command id to identify an rman archive log backup session in progress
set command id to 'flag_arch_delete_in_progress_standby';
#List all archive log and then delete it
delete noprompt archivelog all;
show all;
}
list archivelog all;
EOF

  RSTAT=$?

echo >> $RMAN_LOG_FILE
echo "+-----------------------------------+" >> $RMAN_LOG_FILE
echo "|Starting explicit Resync of catalog|" >> $RMAN_LOG_FILE
echo "+-----------------------------------+" >> $RMAN_LOG_FILE

$RMAN target ${TARGET_CONNECT_STR} << EOF >> $RMAN_LOG_FILE
connect catalog rman/Rm0nc0t1@RCAT;
SET ECHO ON;
resync catalog;
EOF

  RCSTATUS=$?

###########################################################
# Send Email if backup fails and also send alarmpoint Msg #
# If backup is good and only the resync part fails only   #
# send email(no alarmpoint msg)                           #
###########################################################
  if [ "$RSTAT" = "0" ]
  then
    #cat $RMAN_LOG_FILE|mailx -s "deletion of archivelog success for $ORACLE_SID..." $DBA
    echo >> $RMAN_LOG_FILE
      if [ "$RCSTATUS" = "0" ]
      then
        echo "Resync of catalog successful for: $ORACLE_SID" >> $RMAN_LOG_FILE
      else
        echo "ONLY the Resync of catalog failed for: $ORACLE_SID, archive backup successful.." >> $RMAN_LOG_FILE
        echo "ONLY the Resync of catalog failed for: $ORACLE_SID, archive backup successful.."| mailx -s "Resync of Catalog failed for $ORACLE_SID on $SITE" $DBA
      fi
  else
    cat $RMAN_LOG_FILE|mailx -s "deletion of archivelog failed for $ORACLE_SID on $SITE..." $DBA
    /opt/OV/bin/opcmsg s=critical a=Oracle o=RMAN_ARCH_BKP msg_text="Rman Archive log deletion Failed - $ORACLE_SID"  msg_grp=oracle_all
    echo "failed"
  fi

#####################################
# Log the completion of this script #
#####################################

  echo >> $RMAN_LOG_FILE
  echo Script $0 >> $RMAN_LOG_FILE
  echo ==== Ended on `date` ==== >> $RMAN_LOG_FILE
  echo >> $RMAN_LOG_FILE

exit $RSTAT

##################################################
# Exit if ORACLE_USER is owned by different user #
# and script is being ran by another user        #
##################################################
else
 echo "Database: $ORACLE_SID is owned by a different user, Run script($0) using $ORACLE_USER user -- Aborting script" | mailx -s "RMAN Archivelog deletion error database: $ORACLE_SID on $SITE" $DBA
 exit 1
fi
