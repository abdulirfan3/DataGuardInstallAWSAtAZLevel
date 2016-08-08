#!/bin/bash
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
  rm db_unique_name$$ dbstatus$$ >/dev/null 2>&1
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
      rm db_unique_name$$ dbstatus$$ >/dev/null 2>&1
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