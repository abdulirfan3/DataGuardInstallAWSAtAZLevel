alter system set db_recovery_file_dest_size=FRSIZEM scope=both;
alter system set db_recovery_file_dest='/oracle/ORACLE_SID/flashrecovery' scope=both;
alter system set db_flashback_retention_target=720 scope=both;
alter database flashback on;
