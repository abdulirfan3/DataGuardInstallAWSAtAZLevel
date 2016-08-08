set pages 0 feed off ver off trims on echo off
select bytes/1024/1024 from v$log where rownum < 2;
