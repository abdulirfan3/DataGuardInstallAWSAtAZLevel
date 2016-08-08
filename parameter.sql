create pfile='$ORACLE_HOME/dbs/before_dg_parameter_set.ora' from spfile;
alter system set db_unique_name=ORACLE_SID_P scope=spfile;
alter system set log_archive_config='dg_config=(ORACLE_SID_P, ORACLE_SID_S)' scope=both;	
alter system set log_archive_dest_2='service=ORACLE_SID_S async valid_for=(online_logfile,primary_role) db_unique_name=ORACLE_SID_S' scope=both;
alter system set log_archive_dest_1='LOCATION=/oracle/ORACLE_SID/oraarch/ORACLE_SIDarch valid_for=(ALL_LOGFILES,ALL_ROLES)' scope=both;
alter system set standby_file_management=AUTO scope=both;	
alter system set fal_server='ORACLE_SID_S' scope=both;	
alter system set log_file_name_convert='/oracle/ORACLE_SID/origlogA/','/oracle/ORACLE_SID/origlogA/','/oracle/ORACLE_SID/origlogB/','/oracle/ORACLE_SID/origlogB/','/oracle/ORACLE_SID/standbylog','/oracle/ORACLE_SID/standbylog' scope=spfile;
alter system set log_archive_dest_state_1='enable' scope=both;
alter system set log_archive_dest_state_2='enable' scope=both;
alter system set parallel_execution_message_size=16384 scope=spfile;
alter system set log_archive_max_processes=5 scope=spfile;
alter system set dg_broker_start=TRUE scope=both;
create pfile='$ORACLE_HOME/dbs/after_dg_parameter_set.ora' from spfile;
set heading off	
select 'restarting database now...' from dual;
set heading on
shutdown immediate;
startup;	
create pfile='$ORACLE_HOME/dbs/pfile_for_standby_edits.ora' from spfile;

