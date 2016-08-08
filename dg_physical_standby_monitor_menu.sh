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
echo "#                Monitor Physical Standby Submenu:                          #"
echo "#  This section assume Primary and Standby host have not switched over      #"
echo "#        You will get WRONG results if there was a switch over              #"
echo "# ------------------------------------------------------------------------- #"
echo "#                                                                           #"
echo "#  10.  Check current SCN on primary and standby databases                  #"
echo "#  20.  Check Data Guard Status View for errors and fatal messages          #"
echo "#  30.  Check Managed Recovery Process Status                               #"
echo "#  40.  Check for missing archive logs                                      #"
echo "#  50.  Check archive log gaps on the standby database                      #"
echo "#  60.  Check average apply rate / active apply rate                        #"
echo "#  70.  Check transport / apply lag                                         #"
echo "#  80.  How far behind is my Data Guard in terms of time?                   #"
echo "#  90.  Basic Checks on PRIAMRY                                             #"
echo "#  100.  Basic Checks on STANDBY                                            #"
echo "# ------------------------------------------------------------------------- #"
echo "#   x.  Exit                                                                #"
echo "# ------------------------------------------------------------------------- #"

   echo "#   Enter Task Number: "
   read x
   ans=`echo $x | tr '[a-z]' '[A-Z]'`
#
   case "$ans"
   in
       10 )
       monitor_sql_p dg_check_current_scn.sql;
       monitor_sql_s dg_check_current_scn.sql;
       next_menu;
       ;;

       20 )
       echo ""
       echo "Status for ${ORACLE_SID}_P"
       echo ""
       monitor_sql_p systeimestamp.sql;
       monitor_sql_p dg_check_dg_status.sql;
       echo ""
       echo "Status for ${ORACLE_SID}_S"
       echo ""
       monitor_sql_s systeimestamp.sql
       monitor_sql_s dg_check_dg_status.sql;
       next_menu;
       ;;

       30 )
       monitor_sql_s dg_check_mrp.sql;
       echo ""
       monitor_sql_s mrp_detail.sql;
       next_menu;
       ;;

       40 )
       monitor_sql_p dg_check_missing_arc.sql;
       monitor_sql_s dg_check_missing_arc.sql;
       next_menu;
       ;;

       50 )
       echo ""
       echo "Running dg_check_gap.sql file on standby, If this takes long time"
       echo "exit out with CRTL + C ..."
       echo ""
       monitor_sql_s dg_check_gap.sql;
       next_menu;
       ;;

       60 )
       monitor_sql_s dg_apply_rate.sql;
       next_menu;
       ;;

       70 )
       monitor_sql_s dg_lag.sql;
       next_menu;
       ;;

       80 )
       ./dg_time_lag.sh
       next_menu;
       ;;

       90 )
       monitor_sql_p monitor_p.sql;
       next_menu;
       ;;

       100 )
       monitor_sql_s monitor_s.sql;
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