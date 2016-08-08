#!/bin/ksh
#
######################################################################################
#
#************************************************************************************
#***THIS SCRIPT SHOULD ONLY BE USED FOR HP-UX 11.11 SYSTEM OR WHEN USING NETBACKUP***
#************************************************************************************
#
# USAGE:        RMAN_archivelog_backup_NBU.ksh SID NBU_POLICY
#
# PARAMETER(S): SID - Database Name
#               NBU_POLICY - Netbackup Policy Name created by Unix Team For Redo
#
# AUTHOR:       Abdul Mohammed 
#
# DESCRIPTION:  This script will take RMAN archivelog backup
#               and delete archivelogs
#
# REQUIREMENTS: Database must be in ARCHIVELOG mode
#
# MODIFICATION: AM(APR-2014) - Doing a Explicit resync catalog, instead of being
#                              connected to catalog during entire backup time
#                
#               AM(Dec-2015) - Removed the part to do the multiple dest check.  
#                              All we are doing is a desk check on "LOG_ARCHIVE_DEST_1"
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
THRESHOLD=40

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
    echo "ERROR: Could not find oratab file" | mailx -s "RMAN Archivelog Backup Failed on $SITE" $DBA
    exit 1
  fi

###########################################
# Check if First parameter(SID) is passed #
###########################################
  if [ $1 ];then
    ORACLE_SID=$1;export ORACLE_SID
  else
    echo "NO ORACLE SID PROVIDED CHECK SCRIPT USAGE ON $SITE" | mailx -s "RMAN Archivelog Backup Failed on $SITE" $DBA
    exit 1
  fi

############################################
# Check if first Parameter is passed
############################################
  if [ $2 ];then
   export NB_ORA_POLICY=$2
   echo "Policy is $NB_ORA_POLICY"
  else
   echo "RMAN archive log Backup Failed on $SITE, check policy name" |  mailx -s "RMAN Archivelog Backup Failed on $SITE" $DBA
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

TMP_LOG=$LOGDIR/arch_percent_status_$ORACLE_SID
echo > $TMP_LOG

##############################################################################
# Get the DB status, archive log Destination, count of archive log dest and  #
# also check if there is a a session with client_info set to 	             #	
# "flag_arch_backup_in_progress", This acts like a flag file to see if we    #
# need to start another backup or not                                        #
##############################################################################
sqlplus -s /nolog <<EOF >> $TMP_LOG
set heading off pagesize 0 feedback off linesize 200
whenever sqlerror exit 1
conn / as sysdba
select 'Database Name: '||instance_name||  ', Database status: '|| status
from v\$instance;
select 'Archive_dest_count: '|| count(*)
from v\$archive_dest
where destination is not null;
col dest_name format a25;
col status format a10
col destination format a80;
select dest_name,status,destination
from v\$archive_dest
where destination is not null;
select substr(client_info,4,28) from v\$session
where client_info='id=flag_arch_backup_in_progress';
EOF

############################################################################
# Check if a arch backup is already in progress.  If it is then exit       #
# so we do not start archive backup job every 5 mins, this is done by      #
# setting RMAN "set command id to flag_arch_backup_in_progress" for the    #
# RMAN session already in progess                                          #
############################################################################

  if grep "flag_arch_backup_in_progress" $TMP_LOG
  then
    echo >> $TMP_LOG
    echo "Date: `date` " >> $TMP_LOG
    echo "Archive backup is still running for $ORACLE_SID ...."  >> $TMP_LOG
    echo "Not starting a new archive backup session ...." >> $TMP_LOG
    exit 0
  fi

#################################################################
# Initialize the RMAN log file and start of this script         #
# Check to see if DB is up/down, if DB is down then exit script #
# No need to send any alerts/email, as we have other script that#
# dose this work(usoak002 monitoring script)                    #
#################################################################

  export RMAN_LOG_FILE=$LOGDIR/RMAN_bkp_arch_${ORACLE_SID}_${TODAY}.log

  echo > $RMAN_LOG_FILE

  echo Script $0 >> $RMAN_LOG_FILE
  echo ==== started on `date` ==== >> $RMAN_LOG_FILE
  echo >> $RMAN_LOG_FILE
  echo "Backing up Archivelog for Database: $ORACLE_SID using RMAN ..." >> $RMAN_LOG_FILE

  if grep "OPEN" $TMP_LOG
  then
    echo "Database: $ORACLE_SID is up" >> $RMAN_LOG_FILE
  else
    echo "Database: $ORACLE_SID is down on $SITE -- aborting script" >> $TMP_LOG
    #Remove logfile, otherwise we will have empty logfile every 5 mins
    rm $RMAN_LOG_FILE
    #cat $TMP_LOG|mailx -s "RMAN error $ORACLE_SID, DB DOWN..." $DBA
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
            echo "Archive log backup started for $ORACLE_SID" >> $TMP_LOG
          else
            echo >> $TMP_LOG
            echo "Date: `date` " >> $TMP_LOG
            echo "Threshold is set to $THRESHOLD% and archive log dest is at $DEST_PRCT" >> $TMP_LOG
            echo "No need to run arch backup for database:$ORACLE_SID as file system is less then threshold" >> $TMP_LOG
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
RUN {
    # Set RMAN command id to identify an rman archive log backup session in progress
    set command id to 'flag_arch_backup_in_progress';
    # backup all archive logs
    ALLOCATE CHANNEL ch01 TYPE 'SBT_TAPE' PARMS 'ENV=(NB_ORA_POLICY=$NB_ORA_POLICY)';
    ALLOCATE CHANNEL ch02 TYPE 'SBT_TAPE' PARMS 'ENV=(NB_ORA_POLICY=$NB_ORA_POLICY)';
    ALLOCATE CHANNEL ch03 TYPE 'SBT_TAPE' PARMS 'ENV=(NB_ORA_POLICY=$NB_ORA_POLICY)';
    ALLOCATE CHANNEL ch04 TYPE 'SBT_TAPE' PARMS 'ENV=(NB_ORA_POLICY=$NB_ORA_POLICY)';
    BACKUP
    filesperset 20
    FORMAT 'AL_%d_${TODAY}_%s_%p_%t_%U'
    ARCHIVELOG ALL delete input;
    }
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
    #cat $RMAN_LOG_FILE|mailx -s "Backup of archivelog success for $ORACLE_SID..." $DBA
    echo >> $RMAN_LOG_FILE
      if [ "$RCSTATUS" = "0" ]
      then
        echo "Resync of catalog successful for: $ORACLE_SID" >> $RMAN_LOG_FILE
      else
        echo "ONLY the Resync of catalog failed for: $ORACLE_SID, archive backup successful.." >> $RMAN_LOG_FILE
        echo "ONLY the Resync of catalog failed for: $ORACLE_SID, archive backup successful.."| mailx -s "Resync of Catalog failed for $ORACLE_SID on $SITE" $DBA
      fi
  else
    cat $RMAN_LOG_FILE|mailx -s "Backup of archivelog failed for $ORACLE_SID on $SITE..." $DBA
    /opt/OV/bin/opcmsg s=critical a=Oracle o=RMAN_ARCH_BKP msg_text="Rman Archive log Backup Failed - $ORACLE_SID"  msg_grp=oracle_all
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
 echo "Database: $ORACLE_SID is owned by a different user, Run script($0) using $ORACLE_USER user -- Aborting script" | mailx -s "RMAN Archivelog Backup error database: $ORACLE_SID on $SITE" $DBA
 exit 1
fi

