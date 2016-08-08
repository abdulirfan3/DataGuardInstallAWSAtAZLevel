#!/bin/bash
#
# Script to build out Physical Standby database using Oracle Data Guard(DG) in an AWS Environment using EC2 Instance
# This script will create an secondary server(EC2), where the standby database will be in recovery state
# Script assume that secondary host is not yet been created and will be created as part of this script
#
# Author @ Abdul Mohammed
#
# Parameters: No Parameters required.  This script is Interactive in nature.
#
# Requirements: This script depends on whole bunch of sql and shell script present in the zip file
#               Also this script will ask for secondary hostname, IP address, environment type for data guard setup
#               So Have those handy if data guard setup is the function you are calling.
#
# Special Notes: This script creates multiple trash files using process ID ($$) and will be deleted when
#                 execution finishes using a trap
#
# Updates:
#      V2:  Added checks to make sure /etc/udev/rules.d/70-persistent-net.rules is moved before creating Image
#        :  Changing permission of .bash_profile or .login file(oracle user) to write into those file for Banner
#        :  Added logic to make sure if primary system is using AWS PIOPS volume type then standby is using GP2
#        :  Explicit restart of standby database after data guard broker is installed
#
# Things to do in the future:
#       - Automatically change instance type from r3.xlarge to r3.large, so If Primary is using r3.xlarge, then
#         Standby should using r3.large, so save cost on standby DB host.
#       - Above require changes to HugePage settings(if being used)
#
###########################################################################################################################

# unsetting any prior environment variables, so we can have good control of things
ORACLE_SID=""
ORACLE_HOME=""
PATH=/usr/sbin:/sbin:/bin:/sbin:/usr/bin
USER_ID=`whoami`; export USER_ID
PID_NUM=$$

# Function to ask for confirmation before proceeding to next steps.
# Used at multiple places, so user can be break out of script if something is not looking right.
yes_or_no(){

echo ""
echo "Enter Y to Proceed or N to Cancel and exit(upper or lower case)"
#Input cannot be blank, we run in a loop until we get an answer(Which is either Y or N).
while :
do
 read -p "Enter Y for YES, N for NO: " YORN;
 if [[ $YORN == [YyNn] ]];then
  break;
 fi;
done

#####################################################################
# Only condition that will satisfy is "Y or y or N or n"
# Else exit script, as we want some confirmation
#####################################################################
if test "$YORN" = "Y" || test "$YORN" = "y" ; then
 echo
 echo "$YORN was enter, moving on to next step..."
 echo
elif
 test "$YORN" = "N" || test "$YORN" = "n"; then
 echo
 echo "$YORN was enter, exiting script"
 exit 1
else
 echo
 echo "You Entered: $YORN. This is not the confirmation requested, exiting script"
 exit 1
fi

}

# Function to ask basic information about secondary host and the IP address assigned to it and database type
ask_basic_info(){

	echo ""
	echo "Please Make sure you have below info ready before proceeding.."
	echo "Also note, database restart is required.  If you CANNOT restart the database exit now.."
	echo "     - Secondary HOSTNAME"
	echo "     - Secondary HOSTNAME IP Address"
	echo "     - DB Type (PROD OR DEV/QA)"
	echo "     - SYS password, if you do not know that please exit and reset password for sys"
	echo "     - If possible make sure no archive log backup in progress thru RMAN"
	echo "Make sure HOSTNAME entries are in DNS"
	echo ""
	echo "If you are rebuilding the standby database then ignore the RESTART require warning above.."
	echo ""
	yes_or_no

	echo "Please enter HOSTNAME for secondary server, starting with COMPANY standard of es1aws*"
	read STANDBY_HOST
	while [[ $STANDBY_HOST = "" ]]; do
	echo "This Cannot be Blank, Please Enter a HOSTNAME"
	read STANDBY_HOST
	done

	echo ""
	echo "Please enter IP address of secondary hostname entered above"
	read PIP
	while [[ $PIP = "" ]]; do
	echo "This Cannot be Blank, Please Enter a IP address"
	read PIP
	done

	echo ""
	echo "Please enter DB Type(PROD OR DEV/QA, Enter DEV even for QA)"
	echo "This is used for picking the correct DR subnet"
	echo ""
	while :
	do
	    read -p "Enter D for DEV, P for PROD: " INPUT_ENV;
	    if [[ $INPUT_ENV == [DdPp] ]];then
	        break;
	    fi;
	done

	echo ""
	if test "$INPUT_ENV" = "D" || test "$INPUT_ENV" = "d" ; then
		echo
		echo "You select this Database type to be Development"
		export ENV=DEV
	elif
		test "$INPUT_ENV" = "P" || test "$INPUT_ENV" = "p"; then
		echo
		echo "You select this Database type to be Production"
		export ENV=PROD
	else
		echo
		echo "You Entered: $INPUT_ENV. This is not the confirmation requested, exiting script"
		exit 1
	fi

	echo ""
	# Check to make sure secondary host name entered starts with es1aws*, otherwise exit
	if [[ $STANDBY_HOST == es1aws* ]]
	then
		# Ping exit status - Success: code 0, No reply: code 1, Other errors: code 2
		# We want to be in status code 1, server should NOT be ping-able
		echo "pinging $STANDBY_HOST... Please wait..."
		echo ""
		ping $STANDBY_HOST -c 2 > pinging$$
		PING_STATUS=$?
		# Based on ping exit status we do other check
		if [ "$PING_STATUS" -eq 1 ]
		then
			echo "Server is not ping-able, this is the expected behavior"
			echo "This is also expected if server is in DNS"
			# Very Crude way of checking to see if DNS Enter matches hostname
			echo ""
			echo "Checking to make sure the IP address entered above matches that from DNS"
			# Regex to make sure an IP address entered is in the right format of X.X.X.X
			IP_STATUS=`grep -oP "([0-9]{1,3}[\.]){3}[0-9]{1,3}" pinging$$`
				if [ ${IP_STATUS} = ${PIP} ]
				then
					echo "IP Address matches from the ping command"
					echo ""
				else
					echo "IP Address does NOT match from ping/DNS"
					echo "Please make sure $STANDBY_HOST and $PIP entered matches in DNS"
					exit 1
				fi
		elif [ "$PING_STATUS" -eq 2 ]
		then
			echo "error occurred during ping..."
			echo "Make sure $STANDBY_HOST is in DNS, exiting..."
			exit 1
		# If secondary host sends a ping response, then exit out.  As this script builds out the secondary server.
		elif [ "$PING_STATUS" -eq 0 ]
		then
			echo "Server should NOT be pinging...Exiting Script.."
			echo "This script is designed to build the secondary server and expects server to be not ping-able"
			echo "Make sure you have the right host name"
			exit 1
		else
		# If ping exit status is anything other than 2 or 0, we will exit
			echo "Ping status did not return expected behavior, exiting..."
			exit 1
		fi
	else
		echo "HOSTNAME does not comply with COMPANY naming standards and server name does not start with es1aws*"
		echo "exiting..."
		exit 1
	fi

}

# Function to check if SQLPLUS is found when setting the path.
# Also as part of this function we check to make sure database is up and running and same with listener
# If sqlplus location is NOT found, we go into interactive mode and ask user to set ORACLE_SID and ORACLE_HOME manually
# This function is called in other function as well
Check_Sqlplus(){

which sqlplus >/dev/null 2>&1
if [ "$?" -eq 0 ];
then
	export SQLPLUS_FOUND=TRUE
	# If sqlplus path is found then check status of database and listener.  Make sure it is up and running.
	run_sql status.sql > dbstatus$$
	export DB_STATUS=$(tail -1 dbstatus$$)
	run_sql db_unique_name.sql > db_unique_name$$
	export DB_UNIQUE=$(tail -1 db_unique_name$$)
	LISTENER_STATUS=`ps -ef | grep tnslsnr | grep -v grep | grep LISTENER_${ORACLE_SID} | awk '{print $(NF-1)}' | uniq | wc -l`
	# Added an OR syntax below with "[ "$DB_STATUS" = "MOUNTED" ]" if we want to use the same function for standby database as well
	if [[ "$DB_STATUS" = "OPEN" || "$DB_STATUS" = "MOUNTED" ]] && [ "$LISTENER_STATUS" -eq 1 ]
	then
		echo "Database: ${DB_UNIQUE}, status is $DB_STATUS mode..."
		echo "LISTENER: LISTENER_${ORACLE_SID}, status is up..."
	# If database and listener is not up and running then exit and ask user to manually start DB and listener
	else
		echo "Database or listener does not seem to be up, Please start the database and listener before proceeding..."
		echo "exiting script..."
		exit 1
	fi
else
	# When sqlplus path is not found then ask user to enter ORACLE_HOME path manually.
	echo
	echo "No Entry in ORATAB File, Please Make sure ORACLE_SID entry exist in ORATAB file"
	echo
	echo "#################################################################################"
	echo "Enter ORACLE_HOME manually"
	echo "EXAMPLE: /oracle/<SID>/112_64"
	echo "#################################################################################"
	read ORACLE_HOME
	while [[ $ORACLE_HOME = "" ]]; do
		echo "ORACLE_HOME cannot be blank, Enter ORACLE_HOME"
		echo "EXAMPLE: /oracle/<SID>/11204 or for SAP env /oracle/<SID>/112_64"
		read ORACLE_HOME
	done
	export PATH=$ORACLE_HOME/bin:$PATH
	# Once path is set then check for sqlplus again
	which sqlplus >/dev/null 2>&1
		if [ "$?" -eq 0 ]; then
			export SQLPLUS_FOUND=TRUE
			# Run same check as above to make sure DB/Listener is up and running.
			run_sql status.sql > dbstatus$$
			export DB_STATUS=$(tail -1 dbstatus$$)
			run_sql db_unique_name.sql > db_unique_name$$
			export DB_UNIQUE=$(tail -1 db_unique_name$$)
			LISTENER_STATUS=`ps -ef | grep tnslsnr | grep -v grep | grep LISTENER_${ORACLE_SID} | awk '{print $(NF-1)}' | uniq | wc -l`
			# Added an OR syntax below with "[ "$DB_STATUS" = "MOUNTED" ]" if we want to use the same function for standby database as well
			if [[ "$DB_STATUS" = "OPEN" || "$DB_STATUS" = "MOUNTED" ]] && [ "$LISTENER_STATUS" -eq 1 ]
			then
				echo "Database: ${DB_UNIQUE}, status is $DB_STATUS mode..."
				echo "LISTENER: LISTENER_${ORACLE_SID}, status is up..."
			else
				echo "Database or listener does not seem to be up, Please start the database and listener before proceeding..."
				echo "exiting script..."
				exit 1
			fi
		else
			echo "WRONG ORACLE_HOME entered, Please run script again..."
			exit 1;
		fi
fi

}

# Function to set appropriate path for ORACLE_HOME and ORACLE_SID.
# This part expect oratab file to be in place.  If not we exit
set_path_sid(){

if [ -f /var/opt/oracle/oratab ]; then
	ORATAB=/var/opt/oracle/oratab
elif [ -f /etc/oratab ]; then
	ORATAB=/etc/oratab
else
	echo "ERROR: Could not find oratab file"
	exit 1
fi


echo
echo "Check to see if there is more than one database up"
echo
DB_LIST=`ps -ef | grep pmon | grep -v grep | awk -F_ '{print $3}' | wc -l`
echo

# If we have more than one database running on the instance ask user for input as to what database to set the path for
if [ "$DB_LIST" -gt "1" ]
then
	#echo "Found more than one"
	echo "Found More than one database that is up and running, Select SID from List below"
  ps -ef | grep pmon | grep -v grep | awk -F_ '{print $3}' | sort|tee db_list$$
	echo "Select database name from the above list"
	echo
	read ORACLE_SID
	while [[ $ORACLE_SID = "" ]]; do
		echo Database name cannot be BLANK, enter database name
		read ORACLE_SID
	done
	echo
	if grep -w -q $ORACLE_SID db_list$$
	then
	  echo Database selected is: $ORACLE_SID
	  echo "Database name was found from list provided"
	  echo
	  export ORACLE_HOME=`grep -i $ORACLE_SID: ${ORATAB}|grep -v "^#" | cut -f2 -d:`
	  export PATH=$ORACLE_HOME/bin:$PATH
	  Check_Sqlplus
	  # Exit script out if ORACLE SID entered dose not match from list that was provided
  else
		echo "Database name was NOT selected from the List Provided exiting script"
	  exit 1
  fi
# If only one SID is found, then set the path by looking at oratab file.
else
	export ORACLE_SID=`ps -ef | grep pmon | grep -v grep | awk -F_ '{print $3}'`
	export ORACLE_HOME=`grep -i $ORACLE_SID: ${ORATAB}|grep -v "^#" | cut -f2 -d:`
	export PATH=$ORACLE_HOME/bin:$PATH
  echo "Found only one database running on this host"
	Check_Sqlplus
fi

}

# Function to run sql script.  This function expect one parameter
# That is the file name which has your SQL statement.  This function is used many times in this script
run_sql(){

export FILE=$1
sqlplus -s /nolog <<EOF
whenever sqlerror exit 1
conn / as sysdba
@$FILE
EOF

}

# Function to check for oracle password file.  Required for DG setup.
# We are not running any orapwd command to create file, as password needs to be set
check_ps_file(){

echo ""
echo "Checking password file on $ORACLE_SID"
ls -l ${ORACLE_HOME}/dbs/orapw${ORACLE_SID}
pf=$?
if [ "$pf" -ne 0 ]; then
	{
		echo "Password file for:  $ORACLE_SID does not exist!";
		echo "Please create a password file using the orapwd utility"
		echo "Syntax: orapwd file=orapwSID password=XXXXXXXX entries=5"
	}
	exit 1
else
	echo "Password file exists."
fi

echo "Checking password file entries on $ORACLE_SID"
echo ""
run_sql check_pw_file.sql
echo ""

}

# Function to check if force logging is enabled or not.  Required for DG Setup.
#
check_force_loggin(){

echo ""
echo "Checking for forced logging at the database level"
run_sql force_logging.sql > logging$$
export LOGGING=$(tail -1 logging$$)
if [ "$LOGGING" = "NO" ]
then
	{
	echo "# ----------------------------------------------------------#"
	echo "Forced Logging is not enabled.  Will run below ";
	echo "Syntax:  alter database force logging;"
	echo "# ----------------------------------------------------------#"
	echo "";
	}
	# If force logging is not enabled, ask user for conformation and then enabled force logging
	yes_or_no
	run_sql enable_logging.sql
else
	echo "force_logging is enabled.."
fi
echo ""
}

# Function to check if database is in archive log mode, Required for DG setup.
check_arch_mode(){

echo ""
echo "Checking to see if Database is in Archive log mode"
run_sql archive_log_check.sql > archive_chk$$
export ARCHIVE=$(tail -1 archive_chk$$)
if [ "$ARCHIVE" = "NOARCHIVELOG" ]
then
	{
	echo "You are not in archive log mode. Will run below to enabled archive log mode.";
	echo "Syntax:
	shutdown immediate;
	startup mount;
	alter database archivelog;
	alter database open;
	"
	}
	# If archive log is not enabled we go ahead and enable it with user confirmation
	yes_or_no
	run_sql enable_archive_log.sql
else
	echo "Database is in archive log mode.."
fi
echo ""

}

# Function to add standby logs to database, Not required for DG, but this is best practice.
# Also note, this is NOT part of the main data guard build function.  This function is
# called by check_for_standby_log function.  Which checks for standby logs first and if
# not present then run this function.
add_standby_log(){

# First check how many redo log groups we have, so we can match the same for standbylogs + 1
# We also check the to see the size of redo log group, so we can set the same for standby logs
echo ""
echo "Checking to see if how many redo log groups are present"
run_sql redo_log_group.sql > redo_log_group$$
run_sql redo_log_size.sql > redo_log_size$$
export REDOGROUP=$(tail -1 redo_log_group$$)
export REDOSIZE=$(tail -1 redo_log_size$$)
echo "Number of Groups = $REDOGROUP "
echo "Size of each group = $REDOSIZE"
# Add one extra log for standby log as this is the best practice for DG setup
SRLLOG=$(($REDOGROUP+1))
# Adding 200M as buffer size, We use this variable to check for mount point size.  To make sure we have enough room
SRLSIZE=$(($REDOSIZE*$SRLLOG+200))
# Generate the SQL Statement to add standby logs, note that we make sure to stop <= to number of standby logs
for (( c=1; c<=$SRLLOG; c++ ))
do
	# Start standby logs from 20, so we have enough room on the regular redo log to grow
	i=$((20+c))
	echo "ALTER DATABASE ADD STANDBY LOGFILE group $i ('/oracle/${ORACLE_SID}/standbylog/srl_${i}.redo') size ${REDOSIZE}m;" >> standbylog$$.sql
done
echo "Will add standby redo log using below SQL"
echo "Syntax:"
cat standbylog$$.sql
echo ""
yes_or_no

# Additional checks to make sure we have enough room and "standbylog" and "flashrecovery"
# is an actual mount point and not a directory
echo "Checking to make sure below 2 paths are mountpoint"
echo "   - /oracle/${ORACLE_SID}/standbylog"
echo "   - /oracle/${ORACLE_SID}/flashrecovery"
echo ""
if [ "`mountpoint -q /oracle/${ORACLE_SID}/standbylog; echo $?`" = "0" ] && [ "`mountpoint -q /oracle/${ORACLE_SID}/flashrecovery; echo $?`" = "0" ];
then
	echo "standbylog and flashrecovery are mount points, proceeding to next steps..."
	echo ""
	echo "Checking to see if there is enough space on /oracle/${ORACLE_SID}/standbylog mount point"
	# calculate the size of standby logs mount point and if destination size > the required standby logs size
	# Then we add the log files, Otherwise we exit out
	# Print last field/row in second to last column
	DESTCHECK=`df -P /oracle/${ORACLE_SID}/standbylog | awk '{ field = $(NF-2) }; END{ print field }'`
	# Size in MB
	DESTSIZE=$(($DESTCHECK/1024))
	if [ "$DESTSIZE" -ge "$SRLSIZE" ]
	then
		echo "enough space on standard standbylog mount point..."
		echo "adding standbylog logs to the database using above SQL Syntax.."
		run_sql standbylog$$.sql
	else
		echo "Not enough space on standard standbylog mount point"
		echo "Please have UNIX Team add $SRLSIZE MB to /oracle/${ORACLE_SID}/standbylog"
		exit 1
	fi
else
	# Exit out if standbylog or flashrecovery is NOT a mount point
	echo "/oracle/${ORACLE_SID}/standbylog or /oracle/${ORACLE_SID}/flashrecovery is NOT a mount point"
	echo "Please have UNIX team create that mount point and rerun this script"
	echo "Exiting..."
	exit 1
fi
echo ""

}

# Function to check if there are any existing standby log.
# If no existing standby log are present(expected for new system) then run add_standby_log function
# This function is part of the main DG setup function
check_for_standby_log(){

echo ""
echo "Checking to see if there are ANY standby logs"
run_sql redo_log_group.sql > redo_log_group$$
run_sql standby_log.sql > standby_log$$
run_sql redo_log_size.sql > redo_log_sizes$$
# Above we query to see if there any standby logs.  If there any then we display the info
# to the user and let user decide what to do with it.  Move along(use existing one) or exit out and fix manually
export REDOGROUP=$(tail -1 redo_log_group$$)
export STANDBYLOG=$(tail -1 standby_log$$)
export REDOSIZE=$(tail -1 redo_log_sizes$$)
if [ "$STANDBYLOG" -gt "0" ]
then
	{
	echo "Looks like we already have standby logs setup....";
	echo "Number of Standby group = $STANDBYLOG"
	echo "Number for regular group = $REDOGROUP"
	echo "Standby log should = number of Redo Log Groups + 1"
	}
	run_sql logfile.sql
	echo ""
	echo "If this is not expected please fix this manually..."
	echo "Use existing standby logs?"
	echo ""
	# Let user decide what to do, if existing logs are found
	yes_or_no
else
	echo "No existing standby logs found...."
	add_standby_log
fi
echo ""

}

# Function to set parameters for the database.
# Look at parameter.sql for a default file(note that some values will be replaced based on this script)
# This function is not part of the main dg setup function.  This function will be called as part of spfile_check_dg_param_setup function
setup_parameter_file(){

echo ""
cp parameter.sql parameter$$.sql
# Replace ORACLE_SID
sed -i "s/ORACLE_SID/${ORACLE_SID}/g" parameter$$.sql
echo ""
echo "Below are the parameters that will be set for data guard"
echo "Syntax being used:"
echo ""
cat parameter$$.sql
echo ""
echo "setting database parameter and restarting database"
echo "ready to restart the database?"
echo "we will also replace 2 scripts -"
#echo "RMAN Archive log backup script(RMAN_archivelog_backup_NBU.ksh) so that it does not break archive log backup"
echo "start_db.ksh script, which has logic to support data guard"
echo "Will run above Syntax:"
echo ""
echo ""
yes_or_no
# Replace old RMAN archive log backup file with new one
# As the old backup file have backup entries that will break existing archive log backup
# This also assume that as we are in AWS, We will be backing up to S3 via NBU
#if [ -f /oracle/sqlutils/RMAN_archivelog_backup_NBU.ksh ]
#then
#	mv /oracle/sqlutils/RMAN_archivelog_backup_NBU.ksh /oracle/sqlutils/RMAN_archivelog_backup_NBU_before_dg_setup.ksh
#	cp RMAN_archivelog_backup_NBU.ksh /oracle/sqlutils/RMAN_archivelog_backup_NBU.ksh
#	chmod 775 /oracle/sqlutils/RMAN_archivelog_backup_NBU.ksh
#fi
# Replace old startup script with new one, this new script has logic to support Data guard.  If DB role is PRIMARY then open database
# If DB role is Physical standby, start media recovery..
if [ -f /oracle/sqlutils/start_db.ksh ]
then
	mv /oracle/sqlutils/start_db.ksh /oracle/sqlutils/start_db_before_dg_setup.ksh
	cp start_db.ksh /oracle/sqlutils/start_db.ksh
	chmod 775 /oracle/sqlutils/start_db.ksh
else
	cp start_db.ksh /oracle/sqlutils/start_db.ksh
	cp start_listener.ksh /oracle/sqlutils/start_listener.ksh
	cp stop_db.ksh /oracle/sqlutils/stop_db.ksh
	cp stop_listener.ksh /oracle/sqlutils/stop_listener.ksh
	chmod 775 /oracle/sqlutils/*start*
	chmod 775 /oracle/sqlutils/*stop*
fi

run_sql parameter$$.sql
# Make changes for standby file and copy it back to $ORACLE_HOME/dbs location
# This is done so we can use this file to bring up the secondary instance
cp $ORACLE_HOME/dbs/pfile_for_standby_edits.ora .
sed -i '/*.db_unique_name=/ d' pfile_for_standby_edits.ora
sed -i '/*.log_archive_config=/ d' pfile_for_standby_edits.ora
sed -i '/*.log_archive_dest_2=/ d' pfile_for_standby_edits.ora
sed -i '/*.fal_server=/ d' pfile_for_standby_edits.ora
echo "*.db_unique_name='${ORACLE_SID}_S'" >> pfile_for_standby_edits.ora
echo "*.log_archive_config='dg_config=(${ORACLE_SID}_S, ${ORACLE_SID}_P)'" >> pfile_for_standby_edits.ora
echo "*.log_archive_dest_2='service=${ORACLE_SID}_P async valid_for=(online_logfile,primary_role) db_unique_name=${ORACLE_SID}_P'" >> pfile_for_standby_edits.ora
echo "*.fal_server='${ORACLE_SID}_P'" >> pfile_for_standby_edits.ora
cp pfile_for_standby_edits.ora $ORACLE_HOME/dbs/init_dg_standby.ora
echo ""

}

# Function to check if SPFILE is in use, as this help us during data guard broker setup
# Also we use setup_parameter_file function to setup parameters
spfile_check_dg_param_setup(){

echo ""
echo "checking to see if spfile is in use"

run_sql spfile_from_pfile.sql > spfile_from_pfile$$
# If spfile already exist then we get a error saying file already exist

if [ "`grep already spfile_from_pfile$$ >/dev/null; echo $?`" = "0" ]  && [ "`ls -l ${ORACLE_HOME}/dbs/spfile${ORACLE_SID}.ora >/dev/null; echo $?`" = "0" ]
then
	echo "spfile file exists..."
	# As spfile existing run setup_parameter_file function
	setup_parameter_file
else
	{
	echo "spfile for:  $ORACLE_SID does not exist!";
	echo "creating spfile using below Syntax"
	echo "Syntax: create spfile from pfile;"
	echo "For spfile to take affect we need to restart the database"
	yes_or_no
	run_sql spfile_from_pfile_with_bounce.sql
	# Now that spfile exist, run setup_parameter_file function
	setup_parameter_file
	}
fi
echo ""

}

# Function to setup tnsnames.ora file to have entries related to DG setup.
setup_tns(){

echo ""
# Using RegEx to grep for port, we use head -1 as on NON-SAP system we get multiple lines
PORT=`lsnrctl status LISTENER_${ORACLE_SID} | grep "PORT=" | head -1 | grep -oP '=\d+'`
echo "Checking to see if TNS entry already exist"
echo "running tnsping on ${ORACLE_SID}_P and grepping for entry in tnsnames.ora file..."
echo ""
if [ "`tnsping ${ORACLE_SID}_P > /dev/null ; echo $?`" = "0" ] && [ "`grep ${ORACLE_SID}_P $ORACLE_HOME/network/admin/tnsnames.ora > /dev/null ; echo $?`" = "0" ]
then
	echo "TNS Entry exist for ${ORACLE_SID}_P, Nothing to do"
else
	echo "no appropriate tnsping or tns entry found for ${ORACLE_SID}_P"
	# Use a file(tns_entry_p) to set appropriate oracle_sid, hostname, port and inject those entries into tnsnames.ora file after user confirmation
	cp tns_entry_p tns_entry_p$$
	sed -i "s/ORACLE_SID/${ORACLE_SID}/g" tns_entry_p$$
	sed -i "s/###_PRIMARY_HOST_###/${HOSTNAME}/g" tns_entry_p$$
	sed -i "s/###_PORT_###/${PORT}/g" tns_entry_p$$
	# Take a backup
	cp $ORACLE_HOME/network/admin/tnsnames.ora $ORACLE_HOME/network/admin/tnsnames_before_${ORACLE_SID}_P_append.ora
	echo "Will append below entry to $ORACLE_HOME/network/admin/tnsnames.ora file"
	echo ""
	cat tns_entry_p$$
	yes_or_no
	cat tns_entry_p$$ >> $ORACLE_HOME/network/admin/tnsnames.ora
fi

echo "running tnsping on ${ORACLE_SID}_S and grepping for entry in tnsnames.ora file..."
echo ""
if [ "`tnsping ${ORACLE_SID}_S > /dev/null ; echo $?`" = "0" ] && [ "`grep ${ORACLE_SID}_S $ORACLE_HOME/network/admin/tnsnames.ora > /dev/null ; echo $?`" = "0" ]
then
	echo "TNS Entry exist for ${ORACLE_SID}_S, Nothing to do"
else
	echo "no appropriate tnsping or tns entry found for ${ORACLE_SID}_S"
	# Use a file(tns_entry_p) to set appropriate oracle_sid, hostname, port and inject those entries into tnsnames.ora file after user confirmation
	cp tns_entry_s tns_entry_s$$
	sed -i "s/ORACLE_SID/${ORACLE_SID}/g" tns_entry_s$$
	sed -i "s/###_PORT_###/${PORT}/g" tns_entry_s$$
	sed -i "s/###_STANDBY_HOST_###/${STANDBY_HOST}/g" tns_entry_s$$
	# Take a backup
	cp $ORACLE_HOME/network/admin/tnsnames.ora $ORACLE_HOME/network/admin/tnsnames_before_${ORACLE_SID}_S_append.ora
	echo "Will append below entry to $ORACLE_HOME/network/admin/tnsnames.ora file"
	echo ""
	cat tns_entry_s$$
	yes_or_no
	cat tns_entry_s$$ >> $ORACLE_HOME/network/admin/tnsnames.ora
fi
echo ""

}

# Function to setup listener.ora file to have entries related to DG setup.
# You will see most of the commands are being ran twice here.  Reason being
# We are setting is up for primary and standby server
setup_listener(){

echo ""
echo "Checking for listener entry"
cp tns_listener tns_listener$$
# Run the same commands, so listener for standby file can also be created
cp tns_listener_standby tns_listener_standby$$
sed -i "s/ORACLE_SID/${ORACLE_SID}/g" tns_listener$$
sed -i "s/ORACLE_SID/${ORACLE_SID}/g" tns_listener_standby$$
# To escape forward slash in ORACLE_HOME, we are using "#" instead of "/" in sed
sed -i "s#O_H#${ORACLE_HOME}#g" tns_listener$$
sed -i "s#O_H#${ORACLE_HOME}#g" tns_listener_standby$$
#Create a backup before update
cp $ORACLE_HOME/network/admin/listener.ora $ORACLE_HOME/network/admin/listener_before_SID_LIST_append.ora
echo ""
echo "#############################################################################################"
echo "Here is how listener.ora file looks like before any changes"
echo "#############################################################################################"
echo ""
cat $ORACLE_HOME/network/admin/listener.ora
echo ""
echo "#############################################################################################"
echo "Here is how the listener.ora file will looks like AFTER changes"
echo "#############################################################################################"
echo ""
echo ""
# Below we are taking entries that start with "SID_LIST_LISTENER_" and remove that entry and inject the entries we want for DG
# setup using "tns_listener" file.  Note that we are making changes to a tmp file first before appending to the actual file
awk -F"\n" -v RS= '/SID_LIST_LISTENER_'${ORACLE_SID}'/{sub("SID_LIST_LISTENER_'${ORACLE_SID}'.*","")}1' $ORACLE_HOME/network/admin/listener.ora > $ORACLE_HOME/network/admin/tmp
awk -F"\n" -v RS= '/SID_LIST_LISTENER_'${ORACLE_SID}'/{sub("SID_LIST_LISTENER_'${ORACLE_SID}'.*","")}1' $ORACLE_HOME/network/admin/listener.ora > $ORACLE_HOME/network/admin/tmp_standby
cat tns_listener$$ >> $ORACLE_HOME/network/admin/tmp
cat tns_listener_standby$$ >> $ORACLE_HOME/network/admin/tmp_standby
cat $ORACLE_HOME/network/admin/tmp
echo ""
echo "To make above changes permanent to $ORACLE_HOME/network/admin/listener.ora"
yes_or_no
# Remove lines that start with SID_LIST_LISTENER_SID by moving the tmp file over to listener.ora file and reload the listener
mv $ORACLE_HOME/network/admin/tmp $ORACLE_HOME/network/admin/listener.ora
sed -i "s/${HOSTNAME}/${STANDBY_HOST}/g" $ORACLE_HOME/network/admin/tmp_standby
mv $ORACLE_HOME/network/admin/tmp_standby $ORACLE_HOME/network/admin/DO_NOT_DELETE_standby_listener_FILE
cp $ORACLE_HOME/network/admin/listener.ora $ORACLE_HOME/network/admin/listener_after_SID_LIST_append.ora
echo ""
echo "Will run below syntax:"
echo "lsnrctl reload LISTENER_${ORACLE_SID}"
echo ""
echo "We need to reload the listener to make changes go into affect"
echo "Reloading the listener, okay to restart?"
echo ""
yes_or_no
lsnrctl reload LISTENER_${ORACLE_SID}
echo ""

}

# Function to setup sqlnet.ora to have entries related to DG setup.
setup_sqlnet(){

	echo ""
	echo "Setting up sqlnet related parameters"
	# Take a backup of original file
	cp $ORACLE_HOME/network/admin/sqlnet.ora $ORACLE_HOME/network/admin/sqlnet.ora_before_edits

	# Checking entries for TCP.NODELAY
	echo ""
	echo "Checking to see if TCP.NODELAY parameter is set in sqlnet.ora file"
	if grep -w -q TCP.NODELAY $ORACLE_HOME/network/admin/sqlnet.ora
	then
		echo "Found entries related to TCP.NODELAY, Checking to make sure its not commented out"
		# Check to make sure TCP.NODELAY is not commented out
		NODLY=`grep TCP.NODELAY $ORACLE_HOME/network/admin/sqlnet.ora`
		# Assign FIRSTWRD variable to only see first word, so we can figure out
		# if that has been comment out or not
		FIRSTWRD=$(echo ${NODLY} | head -c1)
		# If first word is commented out then we assume line is commented out and we inject that entry...
		if [ "$FIRSTWRD" = "#" ]
		then
			echo "TCP.NODELAY line is commented out..adding entries"
			echo "adding TCP.NODELAY=YES to $ORACLE_HOME/network/admin/sqlnet.ora.."
			echo "TCP.NODELAY=YES" >> $ORACLE_HOME/network/admin/sqlnet.ora
		else
			echo "Already found entries, will not make any changes"
			echo "As these might be required by the app.."
		fi
	else
		echo "found NO entries for TCP.NODELAY, adding that to sqlnet.ora file.."
		echo "adding TCP.NODELAY=YES to $ORACLE_HOME/network/admin/sqlnet.ora.."
		echo "TCP.NODELAY=YES" >> $ORACLE_HOME/network/admin/sqlnet.ora
	fi

	# Checking entries for DEFAULT_SDU_SIZE
	echo ""
	echo "Checking to see if DEFAULT_SDU_SIZE parameter is set in sqlnet.ora file"
	if grep -w -q DEFAULT_SDU_SIZE $ORACLE_HOME/network/admin/sqlnet.ora
	then
		echo "Found entries related to DEFAULT_SDU_SIZE, Checking to make sure its not commented out"
		# Check to make sure TCP.NODELAY is not commented out
		SDUSIZE=`grep DEFAULT_SDU_SIZE $ORACLE_HOME/network/admin/sqlnet.ora`
		FIRSTWRD=$(echo ${SDUSIZE} | head -c1)
		# If first word is commented out then we assume line is commented out and we inject that entry...
		if [ "$FIRSTWRD" = "#" ]
		then
			echo "DEFAULT_SDU_SIZE line is commented out..adding entries"
			echo "adding DEFAULT_SDU_SIZE=32767 to $ORACLE_HOME/network/admin/sqlnet.ora.."
			echo "DEFAULT_SDU_SIZE=32767" >> $ORACLE_HOME/network/admin/sqlnet.ora
		else
			echo "Already found entries, will not make any changes"
			echo "As these might be required by the app.."
		fi
	else
		echo "found NO entries for DEFAULT_SDU_SIZE, adding that to sqlnet.ora file.."
		echo "adding DEFAULT_SDU_SIZE=32767 to $ORACLE_HOME/network/admin/sqlnet.ora.."
		echo "DEFAULT_SDU_SIZE=32767" >> $ORACLE_HOME/network/admin/sqlnet.ora
	fi
	echo ""

}

# Function to start AMI(Amazon Machine Image) prep.  We need to put database in hot backup mode
# and create standby control file
setup_ami_prep(){

echo ""
echo "creating standby control file, so it can be used to bring up secondary database in standby mode"
echo "putting database in HOT Backup mode to prep for AMI creation"
echo "using below Syntax:"
echo "Alter database create standby controlfile as '/tmp/standby_ctrl.ctl';"
echo "Alter database begin backup;"
echo ""
echo ""
echo "As part of setting up Data Guard will will change RMAN archivelog deletion policy.."
echo "Running below syntax to set RMAN config..."
echo "configure archivelog deletion policy to shipped to all standby backed up 1 times to device type sbt;"
echo ""
# First we check the database is already in backup mode or not?
run_sql backup_status.sql > backup_status$$
export BACKUPSTAT=$(tail -1 backup_status$$)
	if [ "$BACKUPSTAT" = "ACTIVE" ]
	then
		# Remove standby control file if it already exist
		rm /tmp/standby_ctrl.ctl >/dev/null 2>&1
		echo "Database already in backup mode.."
		echo "Creating standby controlfile.."
		run_sql create_cont.sql
### COMMENTEDED BELOW FOR v2 UPDATE
### V2 Update start -- File changed from sbt to disk
		rman target / @rman_config_primary.rcv > rman_config
	else
		# Remove standby control file if it already exist
		rm /tmp/standby_ctrl.ctl >/dev/null 2>&1
		run_sql cont_n_begin_bkp.sql
### COMMENTEDED BELOW FOR v2 UPDATE
### V2 Update start -- File changed from sbt to disk
		rman target / @rman_config_primary.rcv > rman_config
	fi

}

# Function to create an AMI.  This function dynamically generates another script
# that needs a ROOT user to run.  This will create an AMI of instance where the script is being ran
create_ami(){

# Build script for UNIX Team to run
NOW=`date '+%C%y%m%d%H%M%S'`
script="create_ami$$.sh"
INST_ID=$(curl --silent http://169.254.169.254/latest/meta-data/instance-id) >/dev/null
# Copy tag_resources.sh script for reusability, this needs to happen before AMI creation starts
cp tag_resources.sh $PWD/tag_resources$$.sh

# Copy start_db_standby.sh script for reusability, this needs to happen before AMI creation starts
cp start_db_standby.sh $PWD/start_db_standby$$.sh
# Change oracle home/sid in the start_db_standby script
sed -i "s/ORACLE_SID=CHANGE_ME/ORACLE_SID=${ORACLE_SID}/g" start_db_standby$$.sh
# Change hostname in the start_db_standby script
sed -i "s/PRIME_HOST/${HOSTNAME}/g" start_db_standby$$.sh
# Use the hash sign instead of / in sed, as oracle_home has /
sed -i "s#ORACLE_HOME=CHANGE_ME#ORACLE_HOME=${ORACLE_HOME}#g" start_db_standby$$.sh
# Set the full path of .sql script, so it can run when use in user-data part of EC2 instance creation
sed -i "s#CHANGE_THIS#${PWD}#g" start_db_standby$$.sh
sed -i "s#PID_CHANGE#${PID_NUM}#g" start_db_standby$$.sh

# Actual start of generating another script, for ROOT user
echo "#!/bin/bash" > $script
echo "echo sleeping for 5 seconds for running prechecks" >> $script
echo "nc -z ec2.us-east-1.amazonaws.com 443 > conn_ec2_stat$$ &" >> $script
echo "sleep 5" >> $script
echo "grep succeeded conn_ec2_stat$$" >> $script
echo "CONN_EC2_STATUS=\$?" >> $script
echo "if [ "\$CONN_EC2_STATUS" -eq 0 ] && [ -f /usr/local/aws/bin/aws ]" >> $script
echo "then" >> $script
echo "" >> $script
### COMMENTEDED BELOW
### COMMENTEDED BELOW
### COMMENTEDED BELOW
### COMMENTEDED BELOW FOR v2 UPDATE
### V2 Update start
echo "if [ -e /etc/udev/rules.d/70-persistent-net.rules ]" >> $script
echo "then"  >> $script
echo "mv /etc/udev/rules.d/70-persistent-net.rules /tmp/70-persistent-net.rules_bkp" >> $script
echo "sleep 3" >> $script
echo "fi" >> $script
## V2 Update end
echo "INST_ID=\$(curl --silent http://169.254.169.254/latest/meta-data/instance-id)" >> $script
echo >> $script
# Get the existing TAGS, so it can be copied over to the new instance.
echo "BU=\$(/usr/local/aws/bin/aws ec2 describe-tags --filters Name=resource-id,Values=\${INST_ID} --output text | grep -v cloudformation | awk '{print \$2, \$5}' | grep BU | awk '{print \$2}')" >> $script
echo "ENV=\$(/usr/local/aws/bin/aws ec2 describe-tags --filters Name=resource-id,Values=\${INST_ID} --output text | grep -v cloudformation | awk '{print \$2, \$5}' | grep Env | awk '{print \$2}')" >> $script
echo "REGION=\$(/usr/local/aws/bin/aws ec2 describe-tags --filters Name=resource-id,Values=\${INST_ID} --output text | grep -v cloudformation | awk '{print \$2, \$5}' | grep Region | awk '{print \$2}')" >> $script
echo "ROLE="\""Standby-Server-for-host-\${HOSTNAME}"\""" >> $script

echo "sed -i "\""s/T_BU=/T_BU=\${BU}/g"\"" $PWD/tag_resources$$.sh" >> $script
echo "sed -i "\""s/T_ENV=/T_ENV=\${ENV}/g"\"" $PWD/tag_resources$$.sh" >> $script
echo "sed -i "\""s/T_REGION=/T_REGION=\${REGION}/g"\"" $PWD/tag_resources$$.sh" >> $script
echo "sed -i "\""s/T_ROLE=/T_ROLE=\${ROLE}/g"\"" $PWD/tag_resources$$.sh" >> $script
# Note below we do not have a / before for ${STANDBY_HOST}, as we want to set that to begin with, while the above we want to get that value by running cli commands by root user
echo "sed -i "\""s/T_HOSTNAME=/T_HOSTNAME=${STANDBY_HOST}/g"\"" $PWD/tag_resources$$.sh" >> $script
# At times, noticed that tag_resources$$.sh script was not being captured correctly during AMI creation.  So sleep for couple of seconds
echo "sleep 5" >> $script


# Start of actual AMI Creation..
# We put the create-image statement into a tmp script, so we can capture the AMI-ID
echo "echo > /tmp/create_ami_start" >> $script

### COMMENTEDED BELOW
### COMMENTEDED BELOW
### COMMENTEDED BELOW
### COMMENTEDED BELOW FOR v2 UPDATE
### V2 Update start

#echo "/usr/local/aws/bin/aws ec2 create-image --instance-id ${INST_ID} --name "\""AMI for ${ORACLE_SID} on host $HOSTNAME for data guard setup started on $NOW"\"" --no-reboot >> /tmp/create_ami_start" >> $script

## Below we are making device mapping, so that we can convert PIOPS volumes to GP2 as we want
## all of the standby servers to always use GP2 volumes even if primary is using PIOPS
echo "/usr/local/aws/bin/aws ec2 describe-volumes --filters Name=attachment.instance-id,Values=${INST_ID} --query 'Volumes[*].{DevID:Attachments[0].Device,SZ:Size}' --output text > DeviceIdOutput" >> $script

echo "> DeviceIdOutputGen" >> $script
echo "for i in \$(cat DeviceIdOutput | awk '{print \$1}')" >> $script
echo "do" >> $script
  echo "size=\`grep \$i DeviceIdOutput | awk -F '\t' '{print \$2}'\`" >> $script
  echo "echo \"{\\""\""DeviceName\\""\"": \\"\""\$i\\"\"",\\"\""Ebs\\"\"":{\\"\""VolumeSize\\"\"":\$size, \\"\""VolumeType\\"\"":\\"\""gp2\\"\""}},\" >> DeviceIdOutputGen" >> $script
echo "done" >> $script

echo "sed '$ s/.$//' DeviceIdOutputGen > DeviceIdOutputGenFinal" >> $script

echo "DEVID=\$(cat DeviceIdOutputGenFinal)" >> $script

echo "> createamiscript.sh" >> $script
echo "echo \"/usr/local/aws/bin/aws ec2 create-image --instance-id ${INST_ID} --name \"AMIFor${ORACLE_SID}OnHost${HOSTNAME}ForDataGuardStartedOn${NOW}\" --no-reboot --block-device-mappings '[ \${DEVID} ]' >> /tmp/create_ami_start\" >> ${PWD}/createamiscript.sh"  >> $script

echo "chmod 774 ${PWD}/createamiscript.sh" >> $script

echo "${PWD}/createamiscript.sh" >> $script
### V2 Update end
### V2 Update end


# If AMI creation syntax returns no error, we put script in sleep mode
echo "if [ "\""\$?"\"" -eq 0 ]; then" >> $script
echo "echo sleeping for 20 second for AMI Creation to begin" >> $script
echo "sleep 20" >> $script
# The below syntax is used here and in create_secondary_server function as well.
# This is here for better readability, as readability is lost when lots of escape characters...
# while [ "`/usr/local/aws/bin/aws ec2 describe-images --image-ids ami-23780949 | grep pending >/dev/null; echo $?`" = "0" ]
# do
# sleep 5
# echo "######################################################"
# echo "still in pending state..."
# done
# Capture the AMIID by using a regex
echo "AMIID=\`grep -oP 'ami-\w+' /tmp/create_ami_start\`" >> $script
# Put script in a loop until AMI creation finishes
echo "while [ "\""\`/usr/local/aws/bin/aws ec2 describe-images --image-ids \$AMIID | grep pending >/dev/null; echo \$?\`"\"" = "\""0"\"" ]" >> $script
echo "do" >> $script
echo "sleep 5" >> $script
echo "echo -----------------------------------------" >> $script
echo "date" >> $script
echo "echo AMI Creation still in pending state..." >> $script
echo "echo DO NOT EXIT..." >> $script
echo "done" >> $script
echo "echo" >> $script
echo "echo" >> $script
echo "echo AMI Creation finished..." >> $script
echo "echo sleeping for 5 second for post processing AMI creation" >> $script
echo "echo" >> $script
echo "sleep 5" >> $script
echo "echo Checking to make sure \$AMIID is in available state" >> $script
echo "/usr/local/aws/bin/aws ec2 describe-images --image-ids \$AMIID | grep available >/dev/null 2>&1" >> $script
echo "echo" >> $script
echo "if [ "\""\$?"\"" -eq 0 ]; then" >> $script
echo "echo AMI Creation was successful" >> $script
echo "echo" >> $script
echo "echo Please let database team know to Proceed to next step.." >> $script
echo "echo > /tmp/ami_creation_success" >> $script
# Change ownership of flag file so other user can remove flag file
echo "chmod 777 /tmp/ami_creation_success" >> $script
echo "chown $USER_ID /tmp/ami_creation_success" >> $script
echo "rm DeviceIdOutput*" >> $script
echo "chmod 400 ${PWD}/createamiscript.sh" >> $script
### V2 Update start
echo "if [ -e /tmp/70-persistent-net.rules_bkp ]" >> $script
echo "then"  >> $script
echo "mv /tmp/70-persistent-net.rules_bkp /etc/udev/rules.d/70-persistent-net.rules" >> $script
echo "fi" >> $script
## V2 Update end
echo "else" >> $script
# This is a wierd place to be at, as AWS report AMI creation finished but still in a wrong state.  So we ask to rerun this script
echo "echo Something went WRONG with AMI creation, Looks like AMI Creation finished but not in available state. Please rerun this script" >> $script
echo "fi" >> $script
echo "else" >> $script
# We ask user to rerun this script if create-image CLI command does not return a value of 0 (hoping for some temp glitch)
echo "echo Something went WRONG with AMI creation, Looks like error executing create-image aws command. Please rerun this script" >> $script
echo "fi" >> $script
echo "" >> $script
echo "else" >> $script
echo "echo" >> $script
# This is part of the man IF statement, as we run an NC command to make sure we have access to make API calls and also if AWS CLI is install at correct location
echo "echo Error running this script" >> $script
echo "echo One of the following things might be the possible error"  >> $script
echo "echo Make sure AWS CLI is installed at default location of /usr/local/aws/bin/aws on this server and has been configured using the aws configure cmd" >> $script
echo "echo Make sure this instance has outbound connection to make API calls to AWS @ ec2.us-east-1.amazonaws.com:443 " >> $script
echo "fi" >> $script
#echo "trap "\""rm /tmp/create_ami_start"\"" EXIT" >> $script
chmod 777 $script
echo ""
echo "Please have UNIX team run the below script as root user on this host"
echo ""
echo "$PWD/$script"
# Future work ...
# Check to see if ROOT user can run this script or not on other system?

}

# Function to end backup mode.  We automatically end backup mode, based on a flag file created by the script
# ran by root user(for AMI creation)
end_backup(){
echo ""
sleep 5
echo ""
echo "Putting script in sleep mode until AMI Creation completes"
echo "DO NOT EXIT OUT OF SCRIPT"
echo ""
while [ ! -f /tmp/ami_creation_success ]
do
	sleep 10
done
echo ""
echo "AMI Creation successful, as flag file exist"
ls -l /tmp/ami_creation_success
echo "removing flag file.."
rm /tmp/ami_creation_success
echo ""
echo "Taking database out of hot backup mode..."

# Check for end backup... if its already ended before AMI creation finishes
# our AMI might not be in correct state.  Hence we retry and run "something_wrong_end_backup" function
run_sql backup_status.sql > backup_status_after$$
export BACKUPSTATAFTER=$(tail -1 backup_status_after$$)
if [ "$BACKUPSTATAFTER" = "ACTIVE" ]
then
	run_sql end_backup.sql
else
	something_wrong_end_backup
fi

echo "################################################################################"
echo "################################################################################"
echo "################################################################################"

}

# Function to rerun AMI creation if needed, This function is NOT part of the DG setup function
# and will only be used if DB is out of backup mode before AMI creation finishes
something_wrong_end_backup(){

echo ""
echo "Database was already out of HOT backup mode..."
echo "This means, we might NOT have a consistent AMI"
echo "we need to recreate the AMI again, will regenerate AMI creation script"
echo ""
yes_or_no
setup_ami_prep
create_ami
end_backup_try_2

}

# Function to try ending backup the second time.  Run this function only if there is something wrong with end backup the first time
# This function looks exactly the same as "end_backup" function with minor changes
end_backup_try_2(){

sleep 5
echo ""
echo "Putting script in sleep mode until AMI Creation completes"
echo "DO NOT EXIT OUT OF SCRIPT"
echo ""
while [ ! -f /tmp/ami_creation_success ]
do
	sleep 10
done
echo ""
echo "AMI Creation successful, as flag file exist"
ls -l /tmp/ami_creation_success
echo "removing flag file.."
rm /tmp/ami_creation_success
echo ""
echo "Taking database out of hot backup mode..."

# Check for end backup... if its already ended then something is wrong..
run_sql backup_status.sql > backup_status_after_try$$
export BACKUPSTATAFTERTRY=$(tail -1 backup_status_after_try$$)
if [ "$BACKUPSTATAFTERTRY" = "ACTIVE" ]
then
	run_sql end_backup.sql
	echo "################################################################################"
	echo "################################################################################"
	echo "################################################################################"
else
	echo ""
	echo "This is the second attempt on creating AMI and this failed as well"
	echo "Please do some further investigation as to why DB is coming out of hot backup mode"
	echo "exiting.."
	exit 1
fi

}

# Function to create entries in either .bash_profile or .login(bash or csh) for oracle/ora<sid> user
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
  		echo "adding entries to .bash_profile"
### COMMENTEDED BELOW FOR v2 UPDATE
### V2 Update start
      cp -p ~/.bash_profile ~/.bash_profile_before_dg_entries
  	  chmod 644 ~/.bash_profile
## V2 Update End
	    echo echo >> ~/.login
      echo echo ------------------------------------>> ~/.bash_profile
      echo echo SPECIAL INSTRUCTIONS >> ~/.bash_profile
      echo echo ------------------------------------>> ~/.bash_profile
      echo echo >> ~/.bash_profile
      echo echo ---------------------------------------------------------- >> ~/.bash_profile
      echo echo - This system has a standby database in place ON ${STANDBY_HOST} >> ~/.bash_profile
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
	    echo "No need to put entries in .login file, one already exist"
	else
  		echo "adding entries to .login"
### COMMENTEDED BELOW FOR v2 UPDATE
### V2 Update start
	    cp -p ~/.login ~/.login_before_dg_entries
		  chmod 644 ~/.login
## V2 Update end
	    echo echo >> ~/.login
	    echo echo ------------------------------------>> ~/.login
	    echo echo SPECIAL INSTRUCTIONS >> ~/.login
	    echo echo ------------------------------------>> ~/.login
	    echo echo >> ~/.login
	    echo echo ---------------------------------------------------------- >> ~/.login
	    echo echo - This system has a standby database in place ON ${STANDBY_HOST} >> ~/.login
	    echo echo - Please use script called /oracle/sqlutils/dg_scripts/dg.sh >> ~/.login
	    echo echo - for basic monitoring and troubleshooting >> ~/.login
	    echo echo - USE CAUTION DUE TO DATA GUARD SETUP>> ~/.login
	    echo echo ---------------------------------------------------------- >> ~/.login
	    echo echo >> ~/.login
	fi
fi

}

# Function to build out secondary server.  This function dynamically generates another script
# to run as ROOT user.  Once the script run it should bring up the secondary EC2 instance
# and hopefully the secondary database as well in recovery mode
build_secondary_server(){

echo ""
echo "setting up secondary server"
echo ""

# Gather all the EC2 instance metadata, so it can be used later on
INST_TYPE=$(curl --silent http://169.254.169.254/latest/meta-data/instance-type)
AMIID=$(grep -oP 'ami-\w+' /tmp/create_ami_start)
AZ=$(curl --silent http://169.254.169.254/latest/meta-data/placement/availability-zone)
INST_ID=$(curl --silent http://169.254.169.254/latest/meta-data/instance-id)

# Based on which AZ we are in and what database environment(Dev/Prod)
# We Hard code subnet-ID, as they should never change.

if [ "$AZ" = "us-east-1d" ] && [ "$ENV" = "DEV" ]
then
	export SUBNETID=subnet-XXXXXXXX
	echo "This server subnet is in $SUBNETID"
	export DRSUBNETID=subnet-XXXXXXXX
	echo "The DR server subnet is in $DRSUBNETID"
elif [ "$AZ" = "us-east-1a" ] && [ "$ENV" = "DEV" ]
then
	export SUBNETID=subnet-XXXXXXXX
	echo "This server subnet is in $SUBNETID"
	export DRSUBNETID=subnet-XXXXXXXX
	echo "The DR server subnet is in $DRSUBNETID"
elif [ "$AZ" = "us-east-1d" ] && [ "$ENV" = "PROD" ]
then
	export SUBNETID=subnet-XXXXXXXX
	echo "This server subnet is in $SUBNETID"
	export DRSUBNETID=subnet-XXXXXXXX
	echo "The DR server subnet is in $DRSUBNETID"
elif [ "$AZ" = "us-east-1a" ] && [ "$ENV" = "PROD" ]
then
	export SUBNETID=subnet-XXXXXXXX
	echo "This server subnet is in $SUBNETID"
	export DRSUBNETID=subnet-XXXXXXXX
	echo "The DR server subnet is in $DRSUBNETID"
else
	echo "Something is wrong when trying to find the subnet, please check and rerun script"
	exit 1
fi

# EBS Instance type optimization
# As of this writing the only listed instance type that support EBS Optimization is below(which are NOT turned on by default)
# Also note, some Instance type like c4.xlarge, c4.large have EBS optimization on by DEFAULT, and that is why it is not listed below
# Instance type like *.8xlarge have a 10-gig network interface network traffic and Amazon EBS traffic is shared on the same 10-gigabit network interface

if [ $INST_TYPE = "c1.xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "c3.xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "c3.2xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "c3.4xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "g2.2xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "i2.xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "i2.2xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "i2.4xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "m1.large" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "m1.xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "m2.2xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "m2.4xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "m3.xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "m3.2xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "r3.xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "r3.2xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
elif [ $INST_TYPE = "r3.4xlarge" ]
then
	export EBS_OPTIMIZED=TRUE
else
	export EBS_OPTIMIZED=FALSE
fi
# Based on above value, we set a flag when creating the secondary EC2 Instance


# add user data specific stuff so it can be used with secondary server, most of work will be done by the script that root will run
cp user-data.sh /tmp/user-data_scratch.sh
sed -i "s/HOSTNAME_TAG=es1aws/HOSTNAME_TAG=${STANDBY_HOST}/g" /tmp/user-data_scratch.sh
sed -i "s/HOSTNAME_PRIM=es1aws/HOSTNAME_PRIM=${HOSTNAME}/g" /tmp/user-data_scratch.sh
sed -i "s/CHANGE_USER/${USER_ID}/g" /tmp/user-data_scratch.sh
sed -i "s/CHANGE_ORACLE_SID/${ORACLE_SID}/g" /tmp/user-data_scratch.sh


# Put in EBS Optimization flag for instances that are eligible, trun on --ebs-optimized flag
if [ $EBS_OPTIMIZED = "TRUE" ]
then
EC2INST_SYNTAX="/usr/local/aws/bin/aws ec2 run-instances --image-id $AMIID --instance-type $INST_TYPE --key-name keyname --security-group-ids sg-5df04032 --subnet-id $DRSUBNETID --monitoring Enabled=true --disable-api-termination --private-ip-address $PIP --iam-instance-profile Name=COMPANY-servers --user-data file:///tmp/user-data_scratch.sh --ebs-optimized >> /tmp/create_ec2_start"
else
EC2INST_SYNTAX="/usr/local/aws/bin/aws ec2 run-instances --image-id $AMIID --instance-type $INST_TYPE --key-name keyname --security-group-ids sg-5df04032 --subnet-id $DRSUBNETID --monitoring Enabled=true --disable-api-termination --private-ip-address $PIP --iam-instance-profile Name=COMPANY-servers --user-data file:///tmp/user-data_scratch.sh >> /tmp/create_ec2_start"
fi

# Build EC2 Instance creation script, so it can be ran by root user.
# No need to check if aws cli is present and if instance can make API call as it was done during AMI creation
instscript="create_inst$$.sh"
echo "#!/bin/bash" > $instscript
echo "INST_ID=\$(curl --silent http://169.254.169.254/latest/meta-data/instance-id)" >> $instscript
echo >> $instscript

# Append start of standby creation into user data
echo "su $USER_ID -c "\""$PWD/start_db_standby$$.sh"\""" >> /tmp/user-data_scratch.sh

echo >> $instscript
echo "echo > /tmp/create_ec2_start" >> $instscript
# Run the syntax that was generated earlier..
echo "$EC2INST_SYNTAX" >> $instscript
echo "if [ "\""\$?"\"" -eq 0 ]; then" >> $instscript
echo "echo Instance creation successfully started" >> $instscript
echo "echo sleeping for 100 second for Instance Creation to initialize" >> $instscript
echo "echo DO NOT EXIT..." >> $instscript
echo "sleep 100" >> $instscript
echo "S_INSTID=\`grep "InstanceId" /tmp/create_ec2_start |grep -oP 'i-\w+'\`" >> $instscript
# Saving secondary INSTNACE-ID to a file, incase we have to rebuild DG.  We will use this to compare input to this file
echo "echo secondary-aws-id: \${S_INSTID} > ${PWD}/SECONDARY_INSTANCE_INFO_DO_NOT_DELETE" >> $instscript
echo "echo hostname: ${STANDBY_HOST} >> ${PWD}/SECONDARY_INSTANCE_INFO_DO_NOT_DELETE" >> $instscript
echo "echo secondary-ip: ${PIP} >> ${PWD}/SECONDARY_INSTANCE_INFO_DO_NOT_DELETE" >> $instscript
#Inject the instance ID into the tag_resources script, so it can be ran after the instance creation finishes
echo "sed -i "\""s/INST_ID=CHANGE_ME/INST_ID=\${S_INSTID}/g"\"" $PWD/tag_resources$$.sh" >> $instscript
# Creating file to enter into while loop to check for instance status.  We need to pass 2 out 2 check
# to proceed, otherwise we are stuck in this loop..
echo "echo > /tmp/create_ec2_state" >> $instscript
echo "while [ "\""\`grep INSTANCESTATUS /tmp/create_ec2_state; echo \$?\`"\"" = "\""1"\"" ]" >> $instscript
echo "do" >> $instscript
echo "sleep 5" >> $instscript
echo "echo -----------------------------------------------" >> $instscript
echo "date" >> $instscript
echo "echo Instance Status check still in pending state..." >> $instscript
echo "echo DO NOT EXIT..." >> $instscript
# Note on how we overwrite file each time, so the while loop can continue on
echo "/usr/local/aws/bin/aws ec2  describe-instance-status --instance-ids \$S_INSTID --filters Name=instance-status.status,Values=ok --output text > /tmp/create_ec2_state" >> $instscript
echo "done" >> $instscript
echo "echo" >> $instscript
echo "echo" >> $instscript
echo "echo Instance Creation finished..." >> $instscript
# Make custom bash profile this server for root user
echo "cd " >> $instscript
echo "if grep -i "\""data guard"\"" .bash_profile" >> $instscript
echo "then" >> $instscript
echo "echo No need to put entries in bash_profile for root, one already exist..." >> $instscript
echo "else" >> $instscript
echo "echo > .puppet_custom_profile" >> $instscript
echo "cp .bash_profile .bash_profile_bkp" >> $instscript
echo "echo echo >> .bash_profile" >> $instscript
echo "echo echo ------------------------------------>> .bash_profile" >> $instscript
echo "echo echo SPECIAL INSTRUCTIONS FOR DATA GUARD >> .bash_profile" >> $instscript
echo "echo echo ------------------------------------>> .bash_profile" >> $instscript
echo "echo echo  >> .bash_profile" >> $instscript
echo "echo echo ---------------------------------------------------------- >> .bash_profile" >> $instscript
echo "echo echo - WHEN A NEW MOUNT POINT IS CREATED ON THIS SERVER        >> .bash_profile" >> $instscript
echo "echo echo - PLEASE CREATE THE SAME MOUNT POINT ON ${STANDBY_HOST}  >> .bash_profile" >> $instscript
echo "echo echo - AS THERE IS STANDBY SERVER IN PLACE FOR THIS DB         >> .bash_profile" >> $instscript
echo "echo echo ---------------------------------------------------------- >> .bash_profile" >> $instscript
echo "echo echo  >> .bash_profile" >> $instscript
echo "fi" >> $instscript
echo "echo sleeping for 5 second for post processing" >> $instscript
echo "echo" >> $instscript
echo "sleep 5" >> $instscript
echo "echo Please configure post stuff like signing puppet cert from puppet master, mount any NFS mount if needed, setup OS backup etc etc.. " >> $instscript
echo "echo" >> $instscript
echo "echo Please let database team know instance creation finished" >> $instscript

# Append start of tagging resources
echo "echo" >> $instscript
echo "echo" >> $instscript
echo "echo Running script to tag the newly created instance" >> $instscript
echo "echo" >> $instscript
echo "echo" >> $instscript
echo "$PWD/tag_resources$$.sh" >> $instscript

echo "echo > /tmp/ec2_creation_success" >> $instscript
# Change ownership of flag file so other user can remove flag file
echo "chmod 777 /tmp/ec2_creation_success" >> $instscript
echo "chown $USER_ID /tmp/ec2_creation_success" >> $instscript
echo "echo" >> $instscript
echo "echo Please let database team know instance creation finished" >> $instscript
echo "echo" >> $instscript
echo "else" >> $instscript
echo "echo Something went WRONG with Instance creation, rerun this script....." >> $instscript
echo "echo If you get this error second time around, please investigate further on AWS end before rerunning this script 3rd time" >> $instscript
echo "echo we might be hitting soft resource limits or something else..." >> $instscript
echo "fi" >> $instscript
chmod 777 $instscript
echo ""
echo "Please have UNIX team run the below script as root user on this host"
echo ""
echo "$PWD/$instscript"

}

# Function to end creation of secondary server by looking at flag file
end_secondary_setup(){

echo ""
sleep 5
echo ""
echo "Putting script in sleep mode until secondary instance creation completes"
echo "DO NOT EXIT OUT OF SCRIPT"
echo ""
while [ ! -f /tmp/ec2_creation_success ]
do
	sleep 10
done
echo ""
echo "Instance Creation successful, as flag file exist.."
ls -l /tmp/ec2_creation_success
echo "removing flag file.."
rm /tmp/ec2_creation_success
echo ""
echo "Login to the secondary server ONCE UNIX team confirms secondary server is up and running"
echo "Check information written to /var/log/boot.log file for information about secondary DB setup and look for errors if any..."
echo ""
echo ""
echo "###########################################################################################################################"
echo "      Please Make sure to check out the standby database before starting next steps like data guard broker setup..."
echo "***************************************************************************************************************************"
echo "         DO NO PROCEED TO NEXT STEPS UNTIL TO SEE = DATA GUARD CREATION SUCCESSFULL MESSAGE IN /var/log/boot.log           "
echo "***************************************************************************************************************************"
echo "###########################################################################################################################"
echo ""
echo ""
echo "ONLY If Data Guard Creation was NOT successful, please go ahead and manually run below command in RMAN"
echo "so that RMAN archivelog back up dont fail on primary..."
echo "configure archivelog deletion policy to none;"
echo ""
echo ""

}

# Function to turn on flashback database
turn_on_flash(){

	# We use FLASH_SID variable at different part of the script, reason being
	# Depending on which database we connect to (primary or standby - ORACLE_SID_P or ORACLE_SID_S)
	# We call diff sql function(monitor_sql_s or monitor_sql_p) to connect to correct TNS entry
	echo ""
	echo ""
	if [ "$FLASH_SID" = "SID_S" ]
	then
		echo "Turning on flashback for database: ${ORACLE_SID}_S..."
		echo "Will connect to ${ORACLE_SID}_S as sys user.."
		SQL_TO_CONNECT=monitor_sql_s
	elif [ "$FLASH_SID" = "SID_P" ]
	then
		echo "Turning on flashback for database: ${ORACLE_SID}_P..."
		echo "Will connect to ${ORACLE_SID}_P as sys user.."
		SQL_TO_CONNECT=monitor_sql_p
	else
		echo ""
		echo "Could not connect to appropriate database, exiting now.."
		echo ""
	fi
	# Check to see how much FlashRecovery area space is allocated. So that this size can be passed on the parameter file
	FRCHECK=`df -P /oracle/${ORACLE_SID}/flashrecovery | awk '{ field = $(NF-2) }; END{ print field }'`
	# Size in MB
	FRSIZE=$(($FRCHECK/1024))
	cp flash_on.sql flash_on$$.sql
	# Replace ORACLE_SID and FLASHRECOVER area size
	sed -i "s/ORACLE_SID/${ORACLE_SID}/g" flash_on$$.sql
	sed -i "s/FRSIZE/${FRSIZE}/g" flash_on$$.sql
	$SQL_TO_CONNECT is_flash_on.sql > is_flash_on$$
	export FLASHON=$(tail -1 is_flash_on$$)
	# First Check to make sure FLASH is of, if OFF then turn it on
	if [ "$FLASHON" = "NO" ]
	then
		$SQL_TO_CONNECT flash_on$$.sql
		$SQL_TO_CONNECT is_flash_on.sql > is_flash_on$$
		export FLASHON=$(tail -1 is_flash_on$$)
		if [ "$FLASHON" = "YES" ]
		then
			echo "Flashback has been successfully turned on.."
			echo ""
			echo ""
		else
			echo ""
			echo "Error turning on flashback, please fix manually"
			echo ""
			echo ""
		fi
	elif [ "$FLASHON" = "YES" ]
	then
			echo ""
			echo "Looks like flashback is already turned on, no need to turn it on again"
			echo ""
			echo ""
	else
		echo ""
		echo "Did not find flashback in either YES or NO state, This is NOT expected..please investigate further.."
		echo ""
	fi

}

# Function to create data guard.  This is the main function setup data guard
setup_dg(){

ask_basic_info
set_path_sid
check_ps_file
check_force_loggin
check_arch_mode
check_for_standby_log
setup_tns
setup_listener
setup_sqlnet
spfile_check_dg_param_setup
setup_ami_prep
create_ami
end_backup
setup_profile_entries
build_secondary_server
end_secondary_setup

}

# Function to check for sys password on PRIMARY.  So we can be confident that correct password is used
# Without this we would get stuck if password was wrong
# Future work: store password in a hidden file, so we dont ask for it over and over again
check_sys_pass(){

export PWFILE=.syspasspw
if [ ! -f $PWFILE ]; then
  echo ""
  echo "Please enter sys password for ${ORACLE_SID} ..."
  echo "Note that if you do not know the sys password, please change it using alter user on current PRIMARY"
  echo "and if standby is in place, copy over password file to standby manually so password is in sync.."
  stty -echo
  read syspass
  stty echo
  echo
  # Note: we do NOT use run_sql function here, reason being we want
# make sure DGMGRL connection work, run_sql uses OS authentication
sqlplus -s /nolog <<EOF >> syspass_check$$
set heading off pagesize 0 linesize 200
whenever sqlerror exit 1
conn sys/$syspass@${ORACLE_SID}_P as sysdba;
col status for a10
set pages 0 feed off ver off trims on echo off
select status from v\$instance;
EOF

# Make sure correct password is entered, otherwise we exit
  if grep -w -q "ORA-01017" syspass_check$$
  then
    echo "You Entered a Invalid UserName/Password, Please run script again with Correct Password to sys user"
    rm .syspasspw syspass_check$$ >/dev/null 2>&1
  else
    export OPEN_STATS=$(tail -1 syspass_check$$)
    rm syspass_check$$ >/dev/null 2>&1
    # In case the primary database (is now the standby), we wanna make sure status is mounted
    if [ "$OPEN_STATS" = "OPEN" ] || [ "$OPEN_STATS" = "MOUNTED" ]
    then
      echo "Successfully logged into to database using dataguard TNS Service name ${ORACLE_SID}..."
      echo $syspass > .syspasspw
      echo ""
    else
      echo "Unable to login to database using data guard TNS Service name ${ORACLE_SID}.."
      echo "Please make sure data guard TNS Service name has been set to our standards, exiting..."
      exit 1
    fi
  fi
else
syspass=$(cat $PWFILE |head -1)
# Note: we do NOT use run_sql function here, reason being we want
# make sure DGMGRL connection work, run_sql uses OS authentication
sqlplus -s /nolog <<EOF >> syspass_check$$
set heading off pagesize 0 linesize 200
whenever sqlerror exit 1
conn sys/$syspass@${ORACLE_SID}_P as sysdba;
col status for a10
set pages 0 feed off ver off trims on echo off
select status from v\$instance;
EOF

# Make sure correct password is entered, otherwise we exit
  if grep -w -q "ORA-01017" syspass_check$$
  then
    echo "Invalid UserName/Password used, Please run script again with Correct Password to sys user"
    rm .syspasspw syspass_check$$ >/dev/null 2>&1
  else
    export OPEN_STATS=$(tail -1 syspass_check$$)
    rm syspass_check$$ >/dev/null 2>&1
    # In case the primary database (is now the standby), we wanna make sure status is mounted
    if [ "$OPEN_STATS" = "OPEN" ] || [ "$OPEN_STATS" = "MOUNTED" ]
    then
      echo "Successfully logged into to database using dataguard TNS Service name ${ORACLE_SID}..."
      echo $syspass > .syspasspw
      echo ""
    else
      echo "Unable to login to database using data guard TNS Service name ${ORACLE_SID}.."
      echo "Please make sure data guard TNS Service name has been set to our standards, exiting..."
      exit 1
    fi
  fi
fi

}

## Function used to login to Standby_DB
monitor_sql_s(){

export FILE=$1
sqlplus -s /nolog <<EOF
conn sys/$syspass@${ORACLE_SID}_S as sysdba;
@$FILE
EOF

}

# Function to setup data guard broker.  This is the main function that does the setup, while
# dg_broker_setup function the driver function
dg_broker_work(){

	echo ""
	echo "####################################################################"
	echo "            START OF DATA GUARD BROKER SETUP                        "
	echo "####################################################################"

	# Check for prior DG broker config, if there is one then exit out...
	echo "Making sure there are no prior data guard broker configuration..."
	echo ""
	dgmgrl -silent sys/$syspass@${ORACLE_SID}_P "show configuration;" > showconfig$$
	# This is a good error to have, as its stating no config exist
	# ORA-16532: Data Guard broker configuration does not exist
	if grep -w -q "ORA-16532" showconfig$$
	then
		echo ""
		echo "No prior configuration found, Enter yes to Proceed with data guard broker configuration.."
		echo ""
		yes_or_no
		echo "Creating configuration..."
		dgmgrl -silent sys/$syspass@${ORACLE_SID}_P "create configuration ${ORACLE_SID}_CONFIG as primary database is ${ORACLE_SID}_P connect identifier is ${ORACLE_SID}_P;" > dg_conig_output
		sleep 2
		echo "Adding secondary database to the newly created config..."
		dgmgrl -silent sys/$syspass@${ORACLE_SID}_P "add database ${ORACLE_SID}_S as connect identifier is ${ORACLE_SID}_S;" >> dg_conig_output
		sleep 2
		echo "Enabling configuration.."
		dgmgrl -silent sys/$syspass@${ORACLE_SID}_P "enable configuration;" >> dg_conig_output
		sleep 5
### V2 Update start
	  echo
		echo "Restarting Standby database...."
		echo
		monitor_sql_s shut_start_mount_start_recovery.sql
		sleep 15
    echo "Enabling DG broker config for ${ORACLE_SID}_S"
		dgmgrl -silent sys/$syspass@${ORACLE_SID}_P "ENABLE DATABASE ${ORACLE_SID}_S;" >> dg_conig_output
		sleep 15
### V2 Update End
		echo ""
		echo "#####################################################################"
		echo "Showing configuration status.."
		echo ""
		dgmgrl -silent sys/$syspass@${ORACLE_SID}_P "show configuration verbose;" >> dg_conig_output
		dgmgrl -silent sys/$syspass@${ORACLE_SID}_P "show configuration verbose;"
		echo ""
		echo ""
		echo "Make sure under Databases: both ${ORACLE_SID}_P and ${ORACLE_SID}_S shows up"
		echo "Make sure the Configuration Status: for ${ORACLE_SID}_CONFIG is in SUCCESS state"
		echo "Exit now if state is NOT in SUCCESS state.."
		echo "If config state is SUCCESS and both databases shows up, Proceed to next step"
		echo ""
		yes_or_no
		echo ""
		echo "Running data guard broker post steps..."
		# StaticConnectIdentifier parameter is set to wrong value -- port 1521 is set, need to change this to service name
		dgmgrl -silent sys/$syspass@${ORACLE_SID}_P "show database ${ORACLE_SID}_P 'StaticConnectIdentifier';" >> dg_conig_output
		dgmgrl -silent sys/$syspass@${ORACLE_SID}_P "show database ${ORACLE_SID}_S 'StaticConnectIdentifier';" >> dg_conig_output
		dgmgrl -silent sys/$syspass@${ORACLE_SID}_P "edit database ${ORACLE_SID}_P set property StaticConnectIdentifier='${ORACLE_SID}_P';" >> dg_conig_output
		dgmgrl -silent sys/$syspass@${ORACLE_SID}_P "edit database ${ORACLE_SID}_S set property StaticConnectIdentifier='${ORACLE_SID}_S';" >> dg_conig_output
		echo "data guard broker post steps finished..."
		echo ""
		echo "#####################################################################"
		echo "Running status report to detect any inconsistent values"
		echo ""
		echo "*********************************************************************"
		echo "Status check on ${ORACLE_SID}_P"
		echo ""
		echo "Status check on ${ORACLE_SID}_P" > dg_conig_inconsistent$$
		dgmgrl sys/$syspass@${ORACLE_SID}_P "show database ${ORACLE_SID}_P 'StatusReport';"
		dgmgrl sys/$syspass@${ORACLE_SID}_P "show database ${ORACLE_SID}_P 'StatusReport';" >> dg_conig_inconsistent$$
		echo ""
		echo "*********************************************************************"
		echo "Status check on ${ORACLE_SID}_S"
		echo ""
		echo "Status check on ${ORACLE_SID}_S" >> dg_conig_inconsistent$$
		dgmgrl sys/$syspass@${ORACLE_SID}_P "show database ${ORACLE_SID}_S 'StatusReport';"
		dgmgrl sys/$syspass@${ORACLE_SID}_P "show database ${ORACLE_SID}_S 'StatusReport';" >> dg_conig_inconsistent$$
		# If we see any inconsistent setting then we make sure put this out, so it can be fix manually
		if grep -w -q "ORA-16714" dg_conig_inconsistent$$
		then
			echo ""
			echo "There are some inconsistent settings in data guard broker config"
			echo "PLEASE FIX THESE MANUALLY...."
		else
			echo ""
			echo "No inconsistent values found..."
			echo "Data Guard Broker setup successful.."
			echo "#####################################################################"
			echo ""
			echo ""
		fi
	else
		echo "Looks like there are some prior data guard broker config that were found"
		echo "Please either fix that or delete that config and rerun this script"
		exit 1
	fi

}

# Function to setup data guard broker, this calls dg_broker_work function
dg_broker_setup(){

	set_path_sid
	echo ""
	echo "Checking to make sure prerequisites have meet, i.e, Data guard has been deployed or not?"
	echo "This setup for data guard broker assume you have a data guard TNS service name as ORACLE_SID_P AND ORACLE_SID_S"
	echo ""
	# Crude way to check if data guard broker process is up and running.  We use this to check and see
	# If data guard was already setup or not ?
	echo "Checking to make sure DMON process is running, as this is part of data guard deployment.."
	DMON_LIST=`ps -ef | grep -v grep | grep ${ORACLE_SID} | grep dmon | awk '{print $NF}' | wc -l`
	# This is a very crude way of checking if data guard is in place by checking standby_file_management
	# parameter, as we cannot query database_role(will always be set to primary for any normal DB)
	echo "Checking to make sure data guard is in place"
	run_sql standby_file_management.sql > standby_file_management$$
	export STANDBY_FILE=$(tail -1 standby_file_management$$)

	if [ "$DMON_LIST" -gt "0" ] && [ "$STANDBY_FILE" = "AUTO" ]
	then
		echo ""
		echo "Looks like DMON process which is associated with Data Guard Broker is up and running and DG config are in place"
		echo "proceeding with setting up data guard broker..."
		#Check to make sure password entered is working or not?
		check_sys_pass
		dg_broker_work
		echo ""
		export FLASH_SID=SID_P
		turn_on_flash
		crontab -l > cron$$
		if grep -wq "dataguard_lag.sh" cron$$
		then
			echo "No need to create a cronjob for dataguard lap script..."
		else
			echo ""
			echo "Adding crontab entry to monitor dataguard lag detection..."
			echo ""
			crontab -l > existing_cron
			cp dataguard_lag.sh /oracle/sqlutils/dataguard_lag.sh
			chmod 754 /oracle/sqlutils/dataguard_lag.sh
			echo "# DataGuard lag detection" >> ${PWD}/existing_cron
			echo "00,30 * * * * /oracle/sqlutils/dataguard_lag.sh ${ORACLE_SID} > /tmp/${ORACLE_SID}_check_lag.log 2>&1" >> ${PWD}/existing_cron
			crontab ${PWD}/existing_cron
		fi
	else
		echo "No existing data guard configuration found.."
		echo "Looking for DMON process to be up and also standby_file_management to be set to AUTO"
		echo "Please configure data according to this build standard, exiting.."
		exit 1
	fi

}

# Function to run SQL file passed to this.  This is used for primary database and uses TNS Service name
# Note we dont use run_sql function, as we use explicit sys password to login and query V$ instance data
monitor_sql_p(){

export FILE=$1
sqlplus -s /nolog <<EOF
conn sys/$syspass@${ORACLE_SID}_P as sysdba;
@$FILE
EOF

}

# Function to run SQL file passed to this.  This is used for standby database and uses TNS Service name
# Note we dont use run_sql function, as we use explicit sys password to login and query V$ instance data
monitor_sql_s(){

export FILE=$1
sqlplus -s /nolog <<EOF
conn sys/$syspass@${ORACLE_SID}_S as sysdba;
@$FILE
EOF

}

# Function to run some basic checks for data guard specific
monitor_dg(){

	echo ""
	set_path_sid
	# Check to see which database you want info for..
	echo "Do you want to get info for primary or standby ??"
	echo ""
	while :
	do
	    read -p "Enter P for PRIMARY(ORACLE_SID_P), S for STANDBY(ORACLE_SID_S): " INPUT_SYSTEM_TYPE;
	    if [[ $INPUT_SYSTEM_TYPE == [PpSs] ]];then
	        break;
	    fi;
	done

	# Based on system type given by user, we call the monitor_sql_* function and run SQL files
	if test "$INPUT_SYSTEM_TYPE" = "P" || test "$INPUT_SYSTEM_TYPE" = "p" ; then
		#Check to make sure password entered is working or not?
		check_sys_pass
		monitor_sql_p monitor_p.sql
	elif test "$INPUT_SYSTEM_TYPE" = "S" || test "$INPUT_SYSTEM_TYPE" = "s" ; then
		#Check to make sure password entered is working or not?
		check_sys_pass
		monitor_sql_s monitor_s.sql
	else
		echo "You entered $INPUT_SYSTEM_TYPE, This was not expected.  Exiting script.."
		exit 1
	fi

}

# Function to check for any data guard broker errors, used before switchover functions
check_for_config_error(){

	echo ""
	set_path_sid
	echo ""
	check_sys_pass
	echo ""
	echo "#####################################################################"
	echo "Showing configuration status.."
	echo ""
	dgmgrl -silent sys/$syspass@${ORACLE_SID}_P "show configuration verbose;" | tee dg_conig_output_error$$
	echo ""
	echo ""
	echo "#####################################################################"
	# First check for any error or warning, if so exit out
	if egrep -wqi 'ERROR|WARNING' dg_conig_output_error$$
	then
		echo "Found some ERROR OR WARNING in configuration, please fix those before proceeding..exiting script"
		exit 1
	else
		echo "Did not find any errors or warning in configuration.."
		echo ""
	fi
	# Next we check for any inconsistent values, to make sure we are in sync
	echo "Running status report to detect any inconsistent values"
	echo ""
	echo "*********************************************************************"
	echo "Status check on ${ORACLE_SID}_P"
	echo ""
	echo "Status check on ${ORACLE_SID}_P" > dg_conig_inconsistent_error$$
	dgmgrl sys/$syspass@${ORACLE_SID}_P "show database ${ORACLE_SID}_P 'StatusReport';" | tee dg_conig_inconsistent_error$$
	echo ""
	echo "*********************************************************************"
	echo "Status check on ${ORACLE_SID}_S"
	echo ""
	echo "Status check on ${ORACLE_SID}_S" >> dg_conig_inconsistent_error$$
	dgmgrl sys/$syspass@${ORACLE_SID}_P "show database ${ORACLE_SID}_S 'StatusReport';" | tee dg_conig_inconsistent_error$$
	echo ""
	# If we see any inconsistent setting then we make sure put this out, so it can be fix manually
	if grep -w -q "ORA-16714" dg_conig_inconsistent_error$$
	then
		echo ""
		echo "There are some inconsistent settings in data guard broker config"
		echo "PLEASE FIX THESE MANUALLY....exiting script"
		exit 1
	else
		echo ""
		echo "No inconsistent values found..."
		echo "Data Guard Broker inconsistent value check successful.."
		echo "#####################################################################"
		echo ""
		echo ""
	fi
	echo "Make sure under Databases: both ${ORACLE_SID}_P and ${ORACLE_SID}_S shows up"
	echo "Make sure the Configuration Status: for ${ORACLE_SID}_CONFIG is in SUCCESS state"
	echo "If config state is SUCCESS and both databases shows up, Proceed to next step"
	echo ""
	# Checking one more time to make sure we are good before going further.
	yes_or_no
	echo ""

}

# Function to check for any errors are switchover.  Reason why we are not using check_for_config_error function is
# after switch over, sometimes broker process might get stuck and hence we run this in background/timeout mode(so this is just a precaution)
check_for_config_error_after_switchover(){

	echo "#####################################################################"
	echo "Showing configuration status.."
	echo ""
	echo "Sleeping 30 seconds to check for any errors...."
	sleep 30
	echo ""
	# We run a timeout command to make sure show config is not stuck, if it is then we TIMEOUT
	echo "Running show config in timeout mode, set to 120 seconds"
	echo ""
	timeout 120 dgmgrl -silent sys/$syspass@${ORACLE_SID}_P "show configuration verbose;" | tee dg_conig_output_after_switch
	echo ""
	echo ""
	echo ""
	echo "#####################################################################"
	if egrep -iq 'ERROR|WARNING|ORA-' dg_conig_output_after_switch
	then
		echo "Found some ERROR OR WARNING OR ORA-msg in configuration, please fix those before proceeding..exiting script"
		echo ""
		echo "If there are any IN-PROGRESS message..."
		echo "Wait for few minutes and check it manually, if command get stuck again, open sqlplus"
		echo "and start/stop DMON process by running below sql..."
		echo "ALTER SYSTEM SET DG_BROKER_START=FALSE"
		echo "ALTER SYSTEM SET DG_BROKER_START=TRUE"
		echo ""
		exit 1
	else
		echo ""
		echo "Did not find any ERROR OR WARNING OR ORA-msg in configuration after switchover.."
		echo ""
		echo ""
		echo "If output seems to be in a stuck state after 120 seconds, chances are DMON background process is stuck"
		echo "Wait for few minutes and check it manually, if command get stuck again, open sqlplus"
		echo "and start/stop DMON process by running below sql..."
		echo "ALTER SYSTEM SET DG_BROKER_START=FALSE"
		echo "ALTER SYSTEM SET DG_BROKER_START=TRUE"
		echo ""
	fi

}

# Function used to switch over the original primary database to secondary
# Meaning ORACLE_SID_S to become primary
switch_from_primary_to_standby(){

	echo ""
	echo "################################### WARNING ####################################"
	echo "################################################################################"
	echo "This function is used make ORACLE_SID_S as primary and ORACLE_SID_P as secondary"
	echo "################################################################################"
	echo "################################### WARNING ####################################"
	echo ""
	echo "                      DOWNTIME REQUIRED FOR SWITCHOVER                          "
	echo ""
	yes_or_no
	check_for_config_error
	echo ""
	echo "Ready to switch over to ${ORACLE_SID}_S as primary??"
	yes_or_no
	dgmgrl -silent sys/$syspass@${ORACLE_SID}_P "switchover to ${ORACLE_SID}_S;" | tee switchover_to_${ORACLE_SID}_S
	sleep 2
	if egrep -wqi 'ERROR|WARNING' switchover_to_${ORACLE_SID}_S
	then
		echo "Found some ERROR OR WARNING during switchover, please fix those manually..exiting script"
		exit 1
	elif grep -iq "Switchover succeeded" switchover_to_${ORACLE_SID}_S
	then
		echo ""
		echo "Looks like switchover succeeded..."
		echo ""
		export FLASH_SID=SID_S
		turn_on_flash
		check_for_config_error_after_switchover
	else
		echo ""
		echo "Looks like something went wrong during switchover, please investigate further...exiting script.."
		exit 1
	fi

}

# Function used to switch over the original primary database to primary
# Meaning ORACLE_SID_P to become primary
switch_from_standby_to_primary(){

	echo ""
	echo "################################### WARNING ####################################"
	echo "################################################################################"
	echo "This function is used make ORACLE_SID_P as primary and ORACLE_SID_S as secondary"
	echo "################################################################################"
	echo "################################### WARNING ####################################"
	echo ""
	echo "                      DOWNTIME REQUIRED FOR SWITCHOVER                          "
	echo ""
	yes_or_no
	check_for_config_error
	echo ""
	echo "Ready to switch over to ${ORACLE_SID}_P as primary??"
	yes_or_no
	dgmgrl -silent sys/$syspass@${ORACLE_SID}_P "switchover to ${ORACLE_SID}_P;" | tee switchover_to_${ORACLE_SID}_P
	sleep 2
	if egrep -wqi 'ERROR|WARNING' switchover_to_${ORACLE_SID}_P
	then
		echo "Found some ERROR OR WARNING during switchover, please fix those manually..exiting script"
		exit 1
	elif grep -iq "Switchover succeeded" switchover_to_${ORACLE_SID}_P
	then
		echo ""
		echo "Looks like switchover succeeded..."
		echo ""
		export FLASH_SID=SID_P
		turn_on_flash
		check_for_config_error_after_switchover
	else
		echo ""
		echo "Looks like something went wrong during switchover, please investigate further...exiting script.."
		exit 1
	fi

}

# Function to ask for basic information about secondary instance.  We use this and compare this the info
# sitting one of the files created during initial built time.  If they dont match we exit.
rebuild_ask_secondary_instance_info(){

	echo ""
	echo "This is used to rebuild the secondary/standby server..."
	echo "This requires us to TERMINIATE the secondary instance and rebuild it again"
	echo ""
	echo "Also note, if you did NOT use this script to create original data guard setup then exit out"
	echo "This script is designed to work ONLY if this script was used originally to create data guard.."
	echo ""
	yes_or_no
	echo ""
	echo "We need to following information to proceed..."
	echo "   - Secondary Server AWS Instance-ID"
	echo "   - IP Address of secondary Server"
	echo "   - Hostname of Secondary Server"
	echo ""
	echo "Please login to SECONDARY server and run the below to get AWS EC2 Instance-ID"
	echo "AZ=\$(curl --silent http://169.254.169.254/latest/meta-data/instance-id); echo \$AZ"
	echo ""
	echo "Get IP Address for Secondary host by running cat /etc/hosts or nslookup secondary_hostname"
	echo ""
	echo "When you have the information ready, Enter Y to proceed to enter information"
	yes_or_no

	echo ""
	echo "Please enter HOSTNAME for secondary server, starting with COMPANY standard of es1aws*"
	read SHOST
	while [[ $SHOST = "" ]]; do
	echo "This Cannot be Blank, Please Enter a HOSTNAME"
	read SHOST
	done

	echo ""
	echo "Please enter IP address of secondary hostname entered above"
	read SIP
	while [[ $SIP = "" ]]; do
	echo "This Cannot be Blank, Please Enter a IP address"
	read SIP
	done

	echo ""
	echo "Please enter Secondary Server AWS Instance-ID entered above"
	read SAWDID
	while [[ $SAWDID = "" ]]; do
	echo "This Cannot be Blank, Please Enter Secondary Server AWS Instance-ID"
	read SAWDID
	done

	echo ""
	echo "Trying to match this info you provided with the info we have when building orginal DG setup"
	echo ""
	if [ ! -f ${PWD}/SECONDARY_INSTANCE_INFO_DO_NOT_DELETE ]
	then
		echo "${PWD}/SECONDARY_INSTANCE_INFO_DO_NOT_DELETE does not exist, exiting script"
		echo "The above file was created during original Data Guard setup using this script.."
		echo "Please make sure the above file exist and run script again..."
		exit 1
	else
		REBUILD_SID=`grep "secondary-aws-id" ${PWD}/SECONDARY_INSTANCE_INFO_DO_NOT_DELETE | grep -oP 'i-\w+'`
		REBUILD_SIP=`grep "secondary-ip:" ${PWD}/SECONDARY_INSTANCE_INFO_DO_NOT_DELETE | grep -oP "([0-9]{1,3}[\.]){3}[0-9]{1,3}"`
		REBUILD_SHOST=`grep "hostname:" ${PWD}/SECONDARY_INSTANCE_INFO_DO_NOT_DELETE | grep -oP 'es1aws\w+'`
		if [ "$REBUILD_SID" = "$SAWDID" ] && [ "$REBUILD_SIP" = "$SIP" ] && [ "$REBUILD_SHOST" = "$SHOST" ]
		then
			echo ""
			echo "Information Entered above matches the information we have when we built the original DG Server"
			echo ""
		else
			echo ""
			echo "Information entered above does not match the information we have when building the original DG Server.."
			echo "Please get the information correct and rerun this script, exiting script...."
			exit 1
		fi
	fi
	# Rung tnsping on both PRIMARY AND SECONDARY to make sure listener are up and
	# listener naming convention was followed originally
	rebuild_tnsping_check

}

# Function to Generate script, so root can run it.  This will terminate the secondary instance
# So it could be rebuilt again.
rebuild_terminiate_secondary_instance(){

echo ""
echo "Generating script to terminate secondary instance, so it can be rebuilt"
echo ""
delscript="terminiate_instance$$.sh"
# Actual start of generating another script, for ROOT user
echo "#!/bin/bash" > $delscript
echo "echo sleeping for 5 seconds for running prechecks" >> $delscript
echo "nc -z ec2.us-east-1.amazonaws.com 443 > conn_ec2_stat$$ &" >> $delscript
echo "sleep 5" >> $delscript
echo "grep succeeded conn_ec2_stat$$" >> $delscript
echo "CONN_EC2_STATUS=\$?" >> $delscript
echo "if [ "\$CONN_EC2_STATUS" -eq 0 ] && [ -f /usr/local/aws/bin/aws ]" >> $delscript
echo "then" >> $delscript
echo "" >> $delscript
echo "/usr/local/aws/bin/aws ec2 modify-instance-attribute --instance-id $SAWDID --no-disable-api-termination" >> $delscript
# If Modify Instance attribute syntax returns no error, we put in sleep mode and start instance termination
echo "if [ "\""\$?"\"" -eq 0 ]; then" >> $delscript
# Get list of volumes for secondary instance
echo "/usr/local/aws/bin/aws ec2 describe-instances --instance-id $SAWDID | grep -oP 'vol-\w+' > /tmp/list_volumes_del" >> $delscript
echo "echo sleeping for 20 second to make sure API termination Protection is disabled successfully" >> $delscript
echo "sleep 20" >> $delscript
echo "echo" >> $delscript
echo "echo Termination Protection for Instance disabled" >> $delscript
echo "echo" >> $delscript
echo "/usr/local/aws/bin/aws ec2 terminate-instances --instance-ids $SAWDID" >> $delscript
echo "if [ "\""\$?"\"" -eq 0 ]; then" >> $delscript
echo "echo" >> $delscript
echo "echo Instance Termination Successfully started..." >> $delscript
echo "echo" >> $delscript
echo "else" >> $delscript
echo "echo Error Terminating standby instance..." >> $delscript
echo "echo Please try running script again..." >> $delscript
echo "fi" >> $delscript
echo "else" >> $delscript
echo "echo Error Disabling API Termination" >> $delscript
echo "echo Please manually disable Instance Termination Protection in AWS Console for this instance" >> $delscript
echo "fi" >> $delscript
echo "echo > /tmp/del_ec2_state" >> $delscript
echo "while [ "\""\`grep terminated /tmp/del_ec2_state; echo \$?\`"\"" = "\""1"\"" ]" >> $delscript
echo "do" >> $delscript
echo "sleep 5" >> $delscript
echo "echo -----------------------------------------------------" >> $delscript
echo "date" >> $delscript
echo "echo Instance Status check still in shutting down state..." >> $delscript
echo "echo DO NOT EXIT..." >> $delscript
# Note on how we overwrite file each time, so the while loop can continue on
echo "/usr/local/aws/bin/aws ec2 describe-instances --instance-ids $SAWDID --filters Name=instance-state-name,Values=terminated --output text > /tmp/del_ec2_state" >> $delscript
echo "done" >> $delscript
echo "echo" >> $delscript
echo "echo" >> $delscript
echo "echo Instance deletion successful..." >> $delscript
echo "echo" >> $delscript
echo "echo Sleeping 60 seconds to start deletion of EBS volumes..." >> $delscript
echo "sleep 60" >> $delscript
echo "echo Deleting EBS volumes attached to old instance..." >> $delscript
echo "echo" >> $delscript
echo "for i in \$(cat /tmp/list_volumes_del);do" >> $delscript
echo "echo " >> $delscript
echo "echo Deleting volume that were attached to secondary Instance, Volume-id: \$i" >> $delscript
echo "/usr/local/aws/bin/aws ec2 delete-volume --volume-id \$i" >> $delscript
echo "done" >> $delscript
echo "" >> $delscript
echo "echo" >> $delscript
echo "echo If you get CLIENT ERROR OPERATION: volume does not exist, it is safe to ignore" >> $delscript
echo "echo as volume might have delete on termination set to true" >> $delscript
echo "echo" >> $delscript
echo "echo Successfully deleted secondary server..." >> $delscript
echo "echo Please let DBA team know to proceed to next steps..." >> $delscript
echo "echo > /tmp/del_secondary_success" >> $delscript
# Change ownership of flag file so other user can remove flag file
echo "chmod 777 /tmp/del_secondary_success" >> $delscript
echo "chown $USER_ID /tmp/del_secondary_success" >> $delscript
echo "echo" >> $delscript
echo "else" >> $delscript
echo "echo" >> $delscript
# This is part of the man IF statement, as we run an NC command to make sure we have access to make API calls and also if AWS CLI is install at correct location
echo "echo Error running this script" >> $delscript
echo "echo One of the following things might be the possible error"  >> $delscript
echo "echo Make sure AWS CLI is installed at default location of /usr/local/aws/bin/aws on this server and has been configured using the aws configure cmd" >> $delscript
echo "echo Make sure this instance has outbound connection to make API calls to AWS @ ec2.us-east-1.amazonaws.com:443 " >> $delscript
echo "fi" >> $delscript
chmod 777 $delscript
echo ""
echo "Please have UNIX team run the below script as root user on this host"
echo ""
echo "$PWD/$delscript"
echo ""

}

# Function to wait, while root run the above script
rebuild_terminiate_secondary_instance_wait(){

echo ""
sleep 5
echo ""
echo "Putting script in sleep mode until secondary instance deletion completes"
echo "DO NOT EXIT OUT OF SCRIPT"
echo ""
while [ ! -f /tmp/del_secondary_success ]
do
	sleep 10
done
echo ""
echo "################################################################################"
echo "################################################################################"
echo "Instance deletion successful, as flag file exist.."
ls -l /tmp/del_secondary_success
echo "removing flag file.."
rm /tmp/del_secondary_success
echo ""

}

# Function to run a tnsping on ORACLE_SID_S AND ORACLE_SID_P, this is a crude to make sure
# all the listener, tnsnames, sqlnet.ora files are in place, so we dont run other function again
rebuild_tnsping_check (){

echo ""
echo "Running ping on DG TNS Services: ${ORACLE_SID}_P and ${ORACLE_SID}_S..."
echo ""
if [ "`tnsping ${ORACLE_SID}_P > /dev/null ; echo $?`" = "0" ] && [ "`tnsping ${ORACLE_SID}_S > /dev/null ; echo $?`" = "0" ]
then
	echo "TNSPING for ${ORACLE_SID}_P and ${ORACLE_SID}_S was successful.."
	echo "It is assumed at this point that listener.ora, tnsnames.ora, sqlnet.ora files have correct entries.."
	echo ""
	if [ ! -f ${ORACLE_HOME}/network/admin/DO_NOT_DELETE_standby_listener_FILE ]
	then
		echo "Unable to find ${ORACLE_HOME}/network/admin/DO_NOT_DELETE_standby_listener_FILE"
		echo "exiting script...Please create the above file manually and make sure to have appropriate"
		echo "secondary host entries, otherwise rebuild will fail...."
		echo "look at one of the existing servers for what entries should look like..."
		exit 1
	else
		echo ""
		echo "${ORACLE_HOME}/network/admin/DO_NOT_DELETE_standby_listener_FILE file exist from original run..."
		echo ""
	fi
else
	echo "Unable to do a ping for DG TNS services: ${ORACLE_SID}_P or ${ORACLE_SID}_S, exiting..."
	exit 1
fi

}

# Function to set parameters for the database.  Same as setup_parameter_file function but with small tweaks
# Look at parameter_rebuild.sql for a default file(note that some values will be replaced based on this script)
rebuild_setup_parameter_file(){

echo ""
cp parameter_rebuild.sql parameter_rebuild$$.sql
# Replace ORACLE_SID
sed -i "s/ORACLE_SID/${ORACLE_SID}/g" parameter_rebuild$$.sql
echo ""
echo "Below are the parameters that will be set for data guard"
echo "Syntax being used:"
echo ""
cat parameter_rebuild$$.sql
echo ""
echo "setting database parameter"
echo "NO need to restart the database"
echo "Will run above Syntax:"
echo ""
echo ""
yes_or_no
run_sql parameter_rebuild$$.sql
# Make changes for standby file and copy it back to $ORACLE_HOME/dbs location
# This is done so we can use this file to bring up the secondary instance
cp $ORACLE_HOME/dbs/pfile_for_standby_edits.ora .
sed -i '/*.db_unique_name=/ d' pfile_for_standby_edits.ora
sed -i '/*.log_archive_config=/ d' pfile_for_standby_edits.ora
sed -i '/*.log_archive_dest_2=/ d' pfile_for_standby_edits.ora
sed -i '/*.fal_server=/ d' pfile_for_standby_edits.ora
echo "*.db_unique_name='${ORACLE_SID}_S'" >> pfile_for_standby_edits.ora
echo "*.log_archive_config='dg_config=(${ORACLE_SID}_S, ${ORACLE_SID}_P)'" >> pfile_for_standby_edits.ora
echo "*.log_archive_dest_2='service=${ORACLE_SID}_P async valid_for=(online_logfile,primary_role) db_unique_name=${ORACLE_SID}_P'" >> pfile_for_standby_edits.ora
echo "*.fal_server='${ORACLE_SID}_P'" >> pfile_for_standby_edits.ora
cp pfile_for_standby_edits.ora $ORACLE_HOME/dbs/init_dg_standby.ora
echo ""

}

# Function to check if SPFILE is in use, as this help us during data guard broker setup
# Also we use rebuild_setup_parameter_file function to setup parameters
rebuild_spfile_check_dg_param_setup(){

echo ""
echo "Checking to make sure DB_UNIQUE_NAME is set to _P from original build.."
run_sql db_unique_name.sql > db_unique_name$$
export DB_UNIQUE=$(tail -1 db_unique_name$$)
if [ "$DB_UNIQUE" = "${ORACLE_SID}_P" ]
then
	echo "Looks like DB_UNIQUE name is already set to ${ORACLE_SID}_P"
else
	echo "Looks like DB_UNIQUE is not set to ${ORACLE_SID}_P from original build.."
	echo "Please run below SQL command manually and restart database..."
	echo "alter system set db_unique_name=${ORACLE_SID}_P scope=spfile;"
	echo "exiting script..."
	exit 1
fi

echo "Checking to make sure LOG_FILE_NAME_CONVERT is in place from original build.."
run_sql log_file_name_conver_loc.sql > log_file_name_conver_loc$$
export LOG_CONVERT=$(head -1 log_file_name_conver_loc$$)
if [ "$LOG_CONVERT" = "" ]
then
	echo "log_file_name_convert parameter should have already been set"
	echo "But looks like this has no value, please set this manually and restart script, exiting.."
	exit 1
else
	echo ""
	echo "log_file_name_convert parameter is already in place..."
	echo ""
fi

echo ""
echo "checking to see if spfile is in use"

run_sql spfile_from_pfile.sql > spfile_from_pfile$$
# If spfile already exist then we get a error saying file already exist

if [ "`grep already spfile_from_pfile$$ >/dev/null; echo $?`" = "0" ]  && [ "`ls -l ${ORACLE_HOME}/dbs/spfile${ORACLE_SID}.ora >/dev/null; echo $?`" = "0" ]
then
	echo "spfile file exists..."
	# As spfile existing run rebuild_setup_parameter_file function
	rebuild_setup_parameter_file
else
	{
	echo "spfile for:  $ORACLE_SID does not exist!";
	echo "creating spfile using below Syntax"
	echo "Syntax: create spfile from pfile;"
	echo "For spfile to take affect we need to restart the database"
	yes_or_no
	run_sql spfile_from_pfile_with_bounce.sql
	# Now that spfile exist, run rebuild_setup_parameter_file function
	rebuild_setup_parameter_file
	}
fi
echo ""

}

# Function that calls all other function to rebuild secondary instance.
rebuild_secondary_instance(){

echo ""
echo "We will be reusing some of the functions that were already created for original standby setup"
echo "Hence we will ask for information about secondary server AGAIN..."
echo ""
echo "Most of the prechecks should already be in place as we are rebuilding and should not require database bounce..."
echo "If for whatever reason database bounce is require(prompted), exit out and run script during approved window.."
echo ""
echo "Ready to rebuild secondary server again ?"
echo ""
yes_or_no
echo ""
set_path_sid
rebuild_ask_secondary_instance_info
rebuild_terminiate_secondary_instance
rebuild_terminiate_secondary_instance_wait
ask_basic_info
check_ps_file
check_force_loggin
check_arch_mode
check_for_standby_log
rebuild_spfile_check_dg_param_setup
# Not running below functions, as they should already be in place and we assume that
# and run a small function(rebuild_tnsping_check) to check it in a crude way.
#setup_tns
#setup_listener
#setup_sqlnet
setup_ami_prep
create_ami
end_backup
build_secondary_server
end_secondary_setup

}

# Function is just a place holder for future work..
not_setup_yet(){
echo "###############################"
echo "# THIS HAS NOT YET BEEN SETUP #"
echo "###############################"
}

###########################################################################
###########################################################################
#
#              Oo      oO    Oo    ooOoOOo o.     O
#              O O    o o   o  O      O    Oo     o
#              o  o  O  O  O    o     o    O O    O
#              O   Oo   O oOooOoOo    O    O  o   o
#              O        o o      O    o    O   o  O
#              o        O O      o    O    o    O O
#              o        O o      O    O    o     Oo
#              O        o O.     O ooOOoOo O     `o
#
###########################################################################
###########################################################################
# BELOW IS MAIN FUNCTION THAT IS RUN IN A WHILE LOOP, WHICH CALL OTHER    #
###########################################################################
###########################################################################
main_menu(){
echo "#----------------------------------------------#"
echo "#   Data Guard Menu System -- AWS Specific     #"
echo "#----------------------------------------------#"
echo "#  10.  Build Physical Standby Database        #"
echo "#----------------------------------------------#"
echo "#  20.  Build Data Guard Broker                #"
echo "#----------------------------------------------#"
echo "#  30.  Monitor Physical Standby Submenu       #"
echo "#----------------------------------------------#"
echo "#  40.  Run Switchover From Primary to Standby #"
echo "#----------------------------------------------#"
echo "#  50.  Run Switchover From Standby to Primary #"
echo "#----------------------------------------------#"
echo "#  60.  Day to Day Data Guard Broker Submenu   #"
echo "#----------------------------------------------#"
echo "#  70.  Rebuild Standby Database               #"
echo "#----------------------------------------------#"
echo "#   x.  Exit                                   #"
echo "#----------------------------------------------#"

   echo "#   Enter Task Number: "
   read x
   ans=`echo $x | tr '[a-z]' '[A-Z]'`
#
   case "$ans"
   in
       10) setup_dg ;;

       20) dg_broker_setup ;;

       30) ./dg_physical_standby_monitor_menu.sh ;;

       40) switch_from_primary_to_standby ;;

       50) switch_from_standby_to_primary ;;

			 60) ./dg_broker_day_to_day.sh ;;

			 70) rebuild_secondary_instance ;;

       q|X|x ) exit; ;;

       * ) main_menu; ;;
   esac
}

# Function to clean process ID files when script exit out
clean(){

	echo ""
	echo "Cleaning up temp file that were created during execution of this script"
	echo ""

rm db_list$$ >/dev/null 2>&1
rm logging$$ >/dev/null 2>&1
rm archive_chk$$ >/dev/null 2>&1
rm redo_log_size$$ >/dev/null 2>&1
rm redo_log_group$$ >/dev/null 2>&1
rm redo_log_sizes$$ >/dev/null 2>&1
rm redo_log_group$$ >/dev/null 2>&1
rm standby_log$$ >/dev/null 2>&1
rm spfile_from_pfile$$ >/dev/null 2>&1
rm parameter$$.sql >/dev/null 2>&1
rm parameter_rebuild$$.sql >/dev/null 2>&1
rm standbylog$$.sql >/dev/null 2>&1
rm tns_entry_p$$ >/dev/null 2>&1
rm tns_entry_s$$ >/dev/null 2>&1
rm tns_listener$$ >/dev/null 2>&1
rm backup_status$$ >/dev/null 2>&1
rm $ORACLE_HOME/network/admin/tmp >/dev/null 2>&1
rm backup_status_after$$ >/dev/null 2>&1
rm backup_status_after_try$$ >/dev/null 2>&1
rm user-data$$.sh >/dev/null 2>&1
rm start_db_standby$$.sh >/dev/null 2>&1
#rm /tmp/user-data_scratch.sh >/dev/null 2>&1
rm /tmp/ami_creation_success >/dev/null 2>&1
rm /tmp/ec2_creation_success >/dev/null 2>&1
#rm $PWD/tag_resources$$.sh >/dev/null 2>&1
rm pinging$$ >/dev/null 2>&1
rm tns_listener_standby$$ >/dev/null 2>&1
rm syspass_check$$ >/dev/null 2>&1
rm standby_file_management$$ >/dev/null 2>&1
rm showconfig$$ >/dev/null 2>&1
rm dg_conig_inconsistent$$ >/dev/null 2>&1
rm dbstatus$$ >/dev/null 2>&1
rm flash_on$$.sql >/dev/null 2>&1
rm is_flash_on$$ >/dev/null 2>&1
rm flash_on$$.sql >/dev/null 2>&1
rm dg_conig_inconsistent_error$$ >/dev/null 2>&1
rm dg_conig_output_error$$ >/dev/null 2>&1
rm db_unique_name$$ >/dev/null 2>&1
rm log_file_name_conver_loc$$ >/dev/null 2>&1
rm cron$$ >/dev/null 2>&1

}

# Trap to run clean function on EXIT of script
trap clean EXIT

# Run the main_menu function
while true
do
  main_menu
done
