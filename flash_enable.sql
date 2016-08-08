alter database recover managed standby database cancel;
alter database flashback on;
alter database recover managed standby database using current logfile disconnect;
select FLASHBACK_ON from v$database;
