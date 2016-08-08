set pages 0 lines 300 trims on head off feed off ver off
select '# ---------------------------'||chr(10)||
       '# --  Instance Information --'||chr(10)||
       '# ---------------------------'||chr(10)||
       'Host Name: '||host_name||chr(10)||
       'Instance Name: '||instance_name||chr(10)||
       'Version: '||version||chr(10)||
       'Startup Time: '||to_char(startup_time, 'DD-MON-RR HH24:MI:SS')||chr(10)||
       'Instance Role: '||instance_role||chr(10)||
       'Blocked:' ||blocked
from v$instance
/
select '# ---------------------------'||chr(10)||
       '# --  Database Information --'||chr(10)||
       '# ---------------------------'||chr(10)||
       'Name: '||name ||chr(10)||
       'Database Role: '||database_role ||chr(10)||
       'Created: '||created ||chr(10)||
       'Log Mode: '||log_mode ||chr(10)||
       'Open Mode: '||open_mode ||chr(10)||
       'Protection Mode: '||protection_mode ||chr(10)||
       'Protection Level: '||protection_level ||chr(10)||
       'Current SCN: '||current_scn ||chr(10)||
       'Flashback on: '||flashback_on||chr(10)||
       'Open Mode: '||open_mode ||chr(10)||
--       'Primary DB Unique Name: '||primary_db_unique_name ||chr(10)||
       'DB Unique Name: '||db_unique_name ||chr(10)||
       'Archivelog Change#: '||archivelog_change# ||chr(10)||
--       'Archivelog Compression: '||archivelog_compression ||chr(10)||
       'Switchover Status: '||switchover_status ||chr(10)||
       'Remote Archive: '||remote_archive||chr(10)||
       'Supplemental Log PK: '||supplemental_log_data_pk||' - '||
         'Supplemental Log UI: '||supplemental_log_data_ui||chr(10)||
       'Data Guard Broker:' ||dataguard_broker||chr(10)||
       'Force Logging: '||force_logging 
  from v$database
/

set serveroutput on size 1000000
declare

cursor c1 is
select value from v$nls_parameters where parameter = ('NLS_LANGUAGE');
cursor c2 is
select value from v$nls_parameters where parameter = ('NLS_TERRITORY');
cursor c3 is
select value from v$nls_parameters where parameter = ('NLS_CHARACTERSET');
cursor c4 is
select value from v$nls_parameters where parameter='NLS_NCHAR_CHARACTERSET';
v_lang varchar2(55);
v_terr varchar2(55);
v_char varchar2(55);
v_nls varchar2(55);

begin
dbms_output.put_line('# -----------------------------------');
dbms_output.put_line('# --  NLS Characterset Information --');
dbms_output.put_line('# -----------------------------------');
open c1; fetch c1 into v_lang; close c1;
open c2; fetch c2 into v_terr; close c2;
open c3; fetch c3 into v_char; close c3;
open c4; fetch c4 into v_nls; close c4;

dbms_output.put_line('NLS_LANG: '||v_lang||'_'||v_terr||'.'||v_char);
dbms_output.put_line('NLS NCHAR Character Set: '||v_nls);

end;
/

set pages 14
set verif on
set lines 80
set hea on


