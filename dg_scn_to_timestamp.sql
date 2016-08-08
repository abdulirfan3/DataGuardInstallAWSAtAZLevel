set echo off ver off feed off head off pages 0;
select scn_to_timestamp(current_scn) from v$database;
