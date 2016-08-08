#!/bin/bash -x
export ORACLE_SID=CHANGE_ME
export ORACLE_HOME=CHANGE_ME
PATH=/usr/sbin:/sbin:/bin:/sbin:/usr/bin
USER_ID=`whoami`; export USER_ID
export PATH=$ORACLE_HOME/bin:$PATH

which sqlplus >/dev/null 2>&1
if [ "$?" -eq 0 ];
then
	export SQLPLUS_FOUND=TRUE
else
	echo
	echo "Standby database creation failed..."
	echo "Cannot find SQLPLUS, exiting script"
	exit 1
fi

run_sql(){

export FILE=$1
sqlplus -s /nolog <<EOF
conn / as sysdba
@$FILE
EOF

}

# Function to create entries in either ~/.bash_profile or ~/.login(bash or csh) for oracle/ora<sid> user
setup_profile_entries(){

echo ""
echo "Checking to see if we need to put any entries in login profile"
PROFILE_VAL=`echo $SHELL`
if [ "${PROFILE_VAL}" = "/bin/bash" ]
then
  if grep -i "data guard" ~/.bash_profile
  then
      echo "No need to put entries in bash_profile, one already exist"
  else
      echo "adding entries to ~/.bash_profile"
### V2 Update start
      cp -p ~/.bash_profile ~/.bash_profile_before_dg_entries
      chmod 644 ~/.bash_profile
## V2 Update End
      echo echo ------------------------------------>> ~/.bash_profile
      echo echo SPECIAL INSTRUCTIONS >> ~/.bash_profile
      echo echo ------------------------------------>> ~/.bash_profile
      echo echo >> ~/.bash_profile
      echo echo ---------------------------------------------------------- >> ~/.bash_profile
      echo echo - This system should be under normal circumstances standby database for PRIME_HOST >> ~/.bash_profile
      echo echo - Please use script called /oracle/sqlutils/dg_scripts/dg.sh >> ~/.bash_profile
      echo echo - for basic monitoring and troubleshooting >> ~/.bash_profile
      echo echo - USE CAUTION DUE TO DATA GUARD SETUP>> ~/.bash_profile
      echo echo ---------------------------------------------------------- >> ~/.bash_profile
      echo echo >> ~/.bash_profile
  fi
elif [ "${PROFILE_VAL}" = "/bin/csh" ]
then
    if grep -i "data guard" ~/.login
    then
        echo "No need to put entries in login file, one already exist"
    else
        echo "adding entries to ~/.login"
### V2 Update start
      cp -p ~/.login ~/.login_before_dg_entries
      chmod 644 ~/.login
## V2 Update End
        echo echo ------------------------------------>> ~/.login
        echo echo SPECIAL INSTRUCTIONS >> ~/.login
        echo echo ------------------------------------>> ~/.login
        echo echo >> ~/.login
        echo echo ---------------------------------------------------------- >> ~/.login
        echo echo - This system should be under normal circumstances standby database for PRIME_HOST >> ~/.login
        echo echo - Please use script called /oracle/sqlutils/dg_scripts/dg.sh >> ~/.login
        echo echo - for basic monitoring and troubleshooting >> ~/.login
        echo echo - USE CAUTION DUE TO DATA GUARD SETUP>> ~/.login
        echo echo ---------------------------------------------------------- >> ~/.login
        echo echo >> ~/.login
    fi
fi

}


# Copy over standby control file to correct location
cp /tmp/standby_ctrl.ctl /oracle/${ORACLE_SID}/control1/cntrl${ORACLE_SID}.ctl
cp /tmp/standby_ctrl.ctl /oracle/${ORACLE_SID}/control2/cntrl${ORACLE_SID}.ctl
cp /tmp/standby_ctrl.ctl /oracle/${ORACLE_SID}/control3/cntrl${ORACLE_SID}.ctl

cd $ORACLE_HOME/dbs
mv spfile${ORACLE_SID}.ora spfile${ORACLE_SID}.ora_bkp_org_primary

mv init_dg_standby.ora init${ORACLE_SID}.ora
cp init${ORACLE_SID}.ora init${ORACLE_SID}.ora_before_ctl_loc_edit

# CHECK TO MAKE SURE CONTROL FILE HAS .CTL EXTENTION AND LOCATION FOR IT
# Below is to ensure we have the correct control file name.
# Some system have CF name as control.ctl, control.dbf, while others have cntrl<SID>.ctl
sed -i '/*.control_files=/d' init${ORACLE_SID}.ora
echo "*.control_files='/oracle/${ORACLE_SID}/control1/cntrl${ORACLE_SID}.ctl','/oracle/${ORACLE_SID}/control2/cntrl${ORACLE_SID}.ctl','/oracle/${ORACLE_SID}/control3/cntrl${ORACLE_SID}.ctl'" >> init${ORACLE_SID}.ora

cd $ORACLE_HOME/network/admin
mv listener.ora listener.ora_bkp_org_primary
mv DO_NOT_DELETE_standby_listener_FILE listener.ora

echo "Starting LISTENER Services..."
lsnrctl start LISTENER_${ORACLE_SID}

#sleep 10 seconds for LISTENER to become available
sleep 10

echo "Running ping on DG TNS Services: ${ORACLE_SID}_P and ${ORACLE_SID}_S..."
if [ "`tnsping ${ORACLE_SID}_P > /dev/null ; echo $?`" = "0" ] && [ "`tnsping ${ORACLE_SID}_S > /dev/null ; echo $?`" = "0" ]
then
	echo "TNSPING for ${ORACLE_SID}_P and ${ORACLE_SID}_S was successful.."
else
	echo "Unable to do a ping for DG TNS services: ${ORACLE_SID}_P or ${ORACLE_SID}_S, exiting..."
	exit 1
fi

echo "Starting standby database in mount mode..."
run_sql CHANGE_THIS/start_standby_db.sql

echo ""
echo "Checking to make sure database role is set to STANDBY before starting recovery process.."
run_sql CHANGE_THIS/standby_role.sql > standby_role$$
export DB_ROLE=$(tail -1 standby_role$$)
if [ "$DB_ROLE" = "PHYSICAL STANDBY" ]
then
	run_sql CHANGE_THIS/start_standby_recovery.sql
	run_sql CHANGE_THIS/mrp_process.sql > mrp_process$$
	export MRP=$(tail -1 mrp_process$$)
	if [ "$MRP" = "MRP0" ]
	then
		echo "##############################################################################################"
		echo "##############################################################################################"
		echo "#                                                                                            #"
		echo "#                      DATA GUARD CREATION SUCCESSFULL                                       #"
		echo "#                                                                                            #"
		echo "##############################################################################################"
		echo "##############################################################################################"
		echo ""
		echo ""
		setup_profile_entries
		# Change RMAN Settings...
		echo "Changing RMAN archivelog deletion policy..."
		echo "This takes a while......"
		echo ""
		rman target / @CHANGE_THIS/rman_config_standby.rcv
		echo "Removing Crontab entries..."
		# Removing crontab entries, so they dont run on standby.  First take a backup
		crontab -l > /oracle/sqlutils/crontab_backup_at_standby_creation
		crontab -r
		echo "" > /oracle/sqlutils/newcron
		echo "# CRONTAB ENTRIES FROM PRIARMY SYSTEM HAS BEEN SAVED AT BELOW LOCATION DURING STANDBY CREATION" >> /oracle/sqlutils/newcron
		echo "# /oracle/sqlutils/crontab_backup_at_standby_creation" >> /oracle/sqlutils/newcron
		echo "" >> /oracle/sqlutils/newcron
		echo "# RMAN Deletion of archive logs for STANDBY SERVER" >> /oracle/sqlutils/newcron
		cp CHANGE_THIS/RMAN_archivelog_deletion_standby_dg.sh /oracle/sqlutils/RMAN_archivelog_deletion_standby_dg.sh
		cp CHANGE_THIS/dataguard_lag.sh /oracle/sqlutils/dataguard_lag.sh
		chmod 754 /oracle/sqlutils/RMAN_archivelog_deletion_standby_dg.sh
		chmod 754 /oracle/sqlutils/dataguard_lag.sh
		echo "0,5,10,15,20,25,30,35,40,45,50,55 * * * * /oracle/sqlutils/RMAN_archivelog_deletion_standby_dg.sh ${ORACLE_SID} > /tmp/${ORACLE_SID}_archive_log_deletion_standby_dg.log 2>&1" >> /oracle/sqlutils/newcron
		echo "# DataGuard lag detection" >> /oracle/sqlutils/newcron
		echo "00,30 * * * * /oracle/sqlutils/dataguard_lag.sh ${ORACLE_SID} > /tmp/${ORACLE_SID}_check_lag.log 2>&1" >> /oracle/sqlutils/newcron
		echo "#  Monthly Purge of trace file older than 60 days" >> /oracle/sqlutils/newcron
		echo "00 16 11 * * /oracle/sqlutils/kellogg_purge_tracefile.ksh ${ORACLE_SID} > /tmp/${ORACLE_SID}_purge_trace.log" >> /oracle/sqlutils/newcron
		echo "#  M Monthly Purge of listner log file" >> /oracle/sqlutils/newcron
		echo "00 16 15 * * /oracle/sqlutils/kellogg_purge_listener_log.ksh ${ORACLE_SID} > /tmp/${ORACLE_SID}_purge_listener.log" >> /oracle/sqlutils/newcron
		crontab /oracle/sqlutils/newcron
		rm /oracle/sqlutils/newcron
	else
		echo ""
		echo "Database seems to be in proper role of STANDBY but turning on"
		echo "recovery process failed...Please fix Manually"
		echo ""
	fi
else
	echo "Database does not seem to be in the proper role"
	echo "database needs to be in standby role"
	echo "exiting script"
	exit 1
fi


function clean(){

	echo ""
	echo "Cleaning up temp file that were created during execution of this script"
	echo ""

rm CHANGE_THIS/db_listPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/loggingPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/archive_chkPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/redo_log_sizePID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/redo_log_groupPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/redo_log_sizesPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/redo_log_groupPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/standby_logPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/spfile_from_pfilePID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/parameterPID_CHANGE.sql >/dev/null 2>&1
rm CHANGE_THIS/standbylogPID_CHANGE.sql >/dev/null 2>&1
rm CHANGE_THIS/tns_entry_pPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/tns_entry_sPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/tns_listenerPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/backup_statusPID_CHANGE >/dev/null 2>&1
rm $ORACLE_HOME/network/admin/tmp >/dev/null 2>&1
rm CHANGE_THIS/backup_status_afterPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/backup_status_after_tryPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/user-dataPID_CHANGE.sh >/dev/null 2>&1
rm CHANGE_THIS/start_db_standbyPID_CHANGE.sh >/dev/null 2>&1
#rm /tmp/user-data_scratch.sh >/dev/null 2>&1
rm /tmp/ami_creation_success >/dev/null 2>&1
rm /tmp/ec2_creation_success >/dev/null 2>&1
#rm $PWD/tag_resources$$.sh >/dev/null 2>&1
rm CHANGE_THIS/pingingPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/tns_listener_standbyPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/syspass_checkPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/standby_file_managementPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/showconfigPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/dg_conig_inconsistentPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/dbstatusPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/flash_onPID_CHANGE.sql >/dev/null 2>&1
rm CHANGE_THIS/is_flash_onPID_CHANGE >/dev/null 2>&1
rm standby_role$$ >/dev/null 2>&1
rm mrp_process$$ >/dev/null 2>&1
rm CHANGE_THIS/flash_onPID_CHANGE.sql >/dev/null 2>&1
rm CHANGE_THIS/dg_conig_inconsistent_errorPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/dg_conig_output_errorPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/db_unique_namePID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/log_file_name_conver_locPID_CHANGE >/dev/null 2>&1
rm CHANGE_THIS/cronPID_CHANGE >/dev/null 2>&1

}

# Trap to run clean function on EXIT of script
trap clean EXIT
