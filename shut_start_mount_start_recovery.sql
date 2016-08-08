shutdown immediate;
startup mount;
alter database recover managed standby database using current logfile disconnect;