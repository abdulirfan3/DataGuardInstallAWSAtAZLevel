#!/bin/bash
. $PWD/dg_connect.sh

function next_menu
{
#echo "# ----------------------------------------------------------------------- #"
echo "[ ...  Press any key to continue ... ]"
read next
}

function main_menu
{
echo "# ------------------------------------------------------------------------- #"
echo "#                  Data Guard Broker Submenu:                               #"
echo "#  This section assume Primary and Standby host have not switched over      #"
echo "#        You will get WRONG results if there was a switch over              #"
echo "# ------------------------------------------------------------------------- #"
echo "# ------------------------------------------------------------------------- #"
echo "#  Broker Reporting Menu                                                    #"
echo "# ------------------------------------------------------------------------- #"
echo "#  01.  Show Data Guard Configuration "
echo "#  02.  Show Database Configuration of ${ORACLE_SID}_P "     
echo "#  03.  Show Database Configuration of ${ORACLE_SID}_S "
echo "#  04.  Show Status Report of ${ORACLE_SID}_P          "
echo "#  05.  Show Status Report of ${ORACLE_SID}_S          "
echo "#  06.  View Primary Send Queue on ${ORACLE_SID}_P     "
echo "#  07.  View Standby Receive Queue on ${ORACLE_SID}_S  "
echo "#  08.  View Top Wait Events on Primary and Standby    "
echo "#  09.  View Database Inconsistent Properties for Primary and Standby "
echo "#  10.  Turn OF Redo Transport for ${ORACLE_SID}_P     "
echo "#  11.  Turn ON Redo Transport for ${ORACLE_SID}_P     "
echo "#  12.  Turn OF Redo Apply for ${ORACLE_SID}_S         "
echo "#  13.  Turn ON Redo Apply for ${ORACLE_SID}_S         "
echo "# ------------------------------------------------------------------------- #"
echo "#   x.  Exit                                                                #"
echo "# ------------------------------------------------------------------------- #"

   echo "#   Enter Task Number: "
   read x
   ans=`echo $x | tr '[a-z]' '[A-Z]'`
#
   case "$ans"
   in
       01 )
       echo "Executing:  show configuration verbose"
       dgmgrl sys/$syspass "show configuration verbose"
       next_menu;
       ;;

       02 )
       echo "Executing:  show database verbose ${ORACLE_SID}_P;"
       dgmgrl sys/$syspass "show database verbose ${ORACLE_SID}_P;"
       next_menu;
       ;;

       03 )
       echo "Executing:  show database verbose ${ORACLE_SID}_S;"
       dgmgrl sys/$syspass "show database verbose ${ORACLE_SID}_S;"
       next_menu;
       ;;

       04 )
       echo "Executing:  show database ${ORACLE_SID}_P StatusReport;"
       dgmgrl sys/$syspass "show database ${ORACLE_SID}_P StatusReport;"
       next_menu;
       ;;

       05 )
       echo "Executing:  show database ${ORACLE_SID}_S StatusReport;"
       dgmgrl sys/$syspass "show database ${ORACLE_SID}_S StatusReport;"
       next_menu;
       ;;
       
       06 )
       echo "Executing:  show database ${ORACLE_SID}_P sendqentries;"
       dgmgrl sys/$syspass "show database ${ORACLE_SID}_P sendqentries;"
       next_menu;
       ;;

       07 )
       echo "Executing:  show database ${ORACLE_SID}_S recvqentries;"
       dgmgrl sys/$syspass "show database ${ORACLE_SID}_S recvqentries;"
       next_menu;
       ;;

       08 )
       echo "Executing:  show database ${ORACLE_SID}_P topwaitevents;"
       dgmgrl sys/$syspass "show database ${ORACLE_SID}_P topwaitevents;"
       echo ""
       echo ""
       echo "Executing:  show database ${ORACLE_SID}_S topwaitevents;"
       dgmgrl sys/$syspass "show database ${ORACLE_SID}_S topwaitevents;"
       next_menu;
       ;;

       09 )
       echo "Executing:  show database ${ORACLE_SID}_P InconsistentProperties;"
       dgmgrl sys/$syspass "show database ${ORACLE_SID}_P InconsistentProperties;"
       echo ""
       echo ""
       echo "Executing:  show database ${ORACLE_SID}_S InconsistentProperties;"
       dgmgrl sys/$syspass "show database ${ORACLE_SID}_S InconsistentProperties;"
       next_menu;
       ;;


       10 )
       echo "Executing:  EDIT DATABASE ${ORACLE_SID}_P SET STATE='TRANSPORT-OFF';"
       echo "This will TURN OFF redo shipping from ${ORACLE_SID}_P to ${ORACLE_SID}_S"
       echo ""
       yes_or_no
       dgmgrl sys/$syspass "EDIT DATABASE ${ORACLE_SID}_P SET STATE='TRANSPORT-OFF';"
       next_menu;
       ;;

       11 )
       dgmgrl sys/$syspass "EDIT DATABASE ${ORACLE_SID}_P SET STATE='TRANSPORT-ON';"
       next_menu;
       ;;            

       12 )
       echo "Executing:  EDIT DATABASE ${ORACLE_SID}_S SET STATE='APPLY-OFF';"
       echo "This will TURN OFF redo apply on ${ORACLE_SID}_S"
       echo ""
       yes_or_no
       dgmgrl sys/$syspass "EDIT DATABASE ${ORACLE_SID}_S SET STATE='APPLY-OFF';"
       next_menu;
       ;;
  
       13 )
       echo "Executing:  EDIT DATABASE ${ORACLE_SID}_S SET STATE='APPLY-ON';"
       dgmgrl sys/$syspass "EDIT DATABASE ${ORACLE_SID}_S SET STATE='APPLY-ON';"
       next_menu;
       ;;

       q|X|x )
        exit;
       ;;
       * )
        main_menu;
       ;;
   esac
}

while true
do
      set_path_sid
      check_sys_pass
      main_menu
done