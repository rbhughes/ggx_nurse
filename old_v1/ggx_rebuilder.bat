@echo off

::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:: GeoGraphix Discovery Automatic Project Rebuilder
::
:: 2015-07-01 -- R. Bryan Hughes -- rbhughes@logicalcat.com -- 303-949-8125
::
:: v.0 2015-07-01
:: Works okay. occasionally ProjectDatabaseRebuilder.exe launches with greyed-
:: out project list and hangs. Cause is not yet determined, but not due to 
:: missing last active project. Adding a timer (ping self) does not resolve
:: either. Problems seemed to increase following R2015.1 release
::
:: v.1 2016-02-18
:: * Refactored to remove external call for rebuilder .cmd file
:: * Removed temp ERROR.log "pessimistic log"--never used it
:: * Removed all hostname hard-coded hostname and IPV6 address entirely
:: * Added blat emailer functionality (experimental!)
:: * Added log archiving
::
::     2016-02-23
:: * Added pre-email that sends project.txt to signify script start
:: * added some missing goto:EOFs
::
::     2016-03-03
:: * ProjectDatabaseRebuilder.exe is terrible. The greyed-out list hang keeps
::   occurring at random, so I replaced it with Sybase dbunload.exe. No more 
::   broken-by-design, pointless .NET GUI to deal with.
:: * Dropping the LMKR .exe means dropping the fake UNC arg in projects.txt
:: * Capture each project's dbunload output to logs
:: * Email a summary of activity, including temp table drops
:: * Archive removed, dbunload output gets copied to logs now
::
::     2016-03-09
:: * Added parsing ability to dynamically build the DBN for SQLAnywhere connect
::   strings. The format is (loosely) <project>-<home> with spaces either
::   removed or replaced--this one uses underscores. This allows projects.txt
::   to simply be a list of paths with no delimiters.
::
::     2016-07-14
:: * Added WELLHEADER_ to list of regex (glob) matches for Views to purge. It
::   turns out these are referenced by the WBFTT views that were already among
::   the list of views that should not exist without valid connections.
::   
::     2016-10-18
:: * Added WellHeaderAndBlob_nnnnnnnn to regex matches. These are apparently
::   also referenced by other views.
::  
::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:: This utility recurses through the projects specified in "projects.txt" and 
:: performs the following actions:
::
:: 0.  :premail  : email project.txt file to signal rebuilder start
:: 1.  :distasks : disable backup tasks that can stop/start GGX services
:: 2.  :stopggx  : stop GGX services (primarily to disconnect users)
:: 3.  :rmloks   : recursively find and delete lok and dbR files
:: 4.  :startggx : start GGX services
:: 5.  :droptabl : purge troublesome leftover temp tables in gxdb.db
:: 6.  :dropview : purge troublesome leftover temp views in gxdb.db
:: 7.  :clearvar : reset vars used by this script
:: 8.  :rebuild  : run SQLAnywhere dbunload.exe on each project
:: 9.  :dropbadv : drop views that are still currupt after a rebuild
:: 10. :enatasks : re-enable backup tasks that stop/start GGX services
:: 11. :postmail : email summary file for all rebuilds
::
::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::

setlocal EnableDelayedExpansion

set _DBI="C:\Program Files (x86)\GeoGraphix\SQL Anywhere 12\BIN64\dbisql.com"
set _DBU="C:\Program Files (x86)\GeoGraphix\SQL Anywhere 12\BIN64\dbunload.exe"
set _ENG=GGX_%COMPUTERNAME%
set _ZZZ=%TEMP%zzz.tmp
set _RGX="R_TEMP_SOURCE.* WBFTT.* GGX_TMP_CREATE_ZONES.* TS_TEMP.* WELLHEADER_* WellHeaderAndBlob_[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]$"
set _MAILTO="bhughes1@example.com,rbhughes@logicalcat.com"
set _SMTP=smtp.mycompany.com
set _LOGDIR="logs"
set _SUMMARY="summary.txt"

call :main
goto:END

::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:main
(echo %date% %time% ----- START rebuilds: %COMPUTERNAME% && echo.) > %_SUMMARY% 
call :premail
call :distasks
call :stopggx
call :rmloks
call :startggx
call :droptabl
call :dropview
call :rebuild
call :dropbadv
call :enatasks
(echo %date% %time% ----- END rebuilds: %COMPUTERNAME% && echo.) >> %_SUMMARY% 
call :postmail
call :clearvar
goto:EOF


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:distasks
schtasks /change /tn ggx_services_STOP /disable
schtasks /change /tn ggx_services_START /disable
goto:EOF


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:enatasks
schtasks /change /tn ggx_services_STOP /enable
schtasks /change /tn ggx_services_START /enable
goto:EOF


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:stopggx
echo ___ stopping GGX services
net stop /y "GGX Database Service" /yes
net stop /y "GGX List Service (v2)" /yes
net stop /y "GGX Network Access Service" /yes
goto:EOF


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:startggx
echo ___ starting GGX services
net start "GGX Database Service" /yes
net start "GGX List Service (v2)" /yes
net start "GGX Network Access Service" /yes
goto:EOF


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:rmloks
echo ___ deleting [.lok .logR .dbR] files
::for /F "tokens=2 delims=|" %%A in (projects.txt) do (
for /F "tokens=*" %%A in (projects.txt) do (
  pushd %%A
  del /Q/S/F *.lok
  del /Q/S/F *.logR
  del /Q/S/F *.dbR
  popd
)
goto:EOF


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:: Use dbisql.com to dump a list of tables, then use findstr on that to check
:: for known troublesome temp tables (based on regex matches). Call
:: dbisql.com again to drop the temp tables, and finally, delete temps
:droptabl
for /F "tokens=*" %%A in (projects.txt) do (
  echo ___ purge temp tables: %%A

  set _STR=%%A
  set _STR=!_STR: =_!
  call:reverseString !_STR!
  for /f "tokens=1,2 delims=\" %%a in ("!_STR!") do set _CHOP=%%b-%%a
  call:reverseString !_CHOP!
  set _DBN=!_STR!

  set _DBF=%%A\gxdb.db
  set _TMP=%TEMP%tmps_!_DBN!.txt
  set _SQL=sp_tables '%%', 'DBA', '%%', "'TABLE'"

  !_DBI! -q -c "UID=dba;PWD=sql;DBN=!_DBN!;DBF=!_DBF!;ENG=!_ENG!" !_SQL! ; output to !_TMP! QUOTE ' ' ALL

  findstr /R !_RGX! !_TMP! > !_ZZZ!
  
  for /F "tokens=3 delims=," %%a in (!_ZZZ!) do (
    !_DBI! -c "UID=dba;PWD=sql;DBN=!_DBN!;DBF=!_DBF!;ENG=!_ENG!" drop table if exists %%a;
    echo %date% %time% ===== dropped table %%a in %%A
  )
  del !_ZZZ!
  del !_TMP!
  set _CHOP=
  set _STR=
  set _DBN=
)
goto:EOF



::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:: See droptabl for details. May be rare, but corrupt views can happen.
:dropview
for /F "tokens=*" %%A in (projects.txt) do (
  echo ___  purge temp views: %%A

  set _STR=%%A
  set _STR=!_STR: =_!
  call:reverseString !_STR!
  for /f "tokens=1,2 delims=\" %%a in ("!_STR!") do set _CHOP=%%b-%%a
  call:reverseString !_CHOP!
  set _DBN=!_STR!

  set _DBF=%%A\gxdb.db
  set _TMP=%TEMP%tmps_!_DBN!.txt
  set _SQL=sp_tables '%%', 'DBA', '%%', "'VIEW'"

  !_DBI! -q -c "UID=dba;PWD=sql;DBN=!_DBN!;DBF=!_DBF!;ENG=!_ENG!" !_SQL! ; output to !_TMP! QUOTE ' ' ALL

  findstr /R !_RGX! !_TMP! > !_ZZZ!
  
  for /F "tokens=3 delims=," %%a in (!_ZZZ!) do (
    !_DBI! -c "UID=dba;PWD=sql;DBN=!_DBN!;DBF=!_DBF!;ENG=!_ENG!" drop view if exists %%a;
    echo %date% %time% ===== dropped view %%a in %%A
  )
  del !_ZZZ!
  del !_TMP!
  set _CHOP=
  set _STR=
  set _DBN=
)
goto:EOF



::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:: Just a dbunload with -ar flags.
:rebuild
FOR /F %%A IN ('WMIC OS GET LocalDateTime ^| FINDSTR \.') DO @SET B=%%A
set _TSTAMP=%B:~0,4%_%B:~4,2%_%B:~6,2%
for /F "tokens=*" %%A in (projects.txt) do (
  echo ___           rebuild: %%A

  set _STR=%%A
  set _STR=!_STR: =_!
  call:reverseString !_STR!
  for /f "tokens=1,2 delims=\" %%a in ("!_STR!") do set _CHOP=%%b-%%a
  call:reverseString !_CHOP!
  set _DBN=!_STR!
  set _DBF=%%A\gxdb.db

  set _LOGFILE=!_TSTAMP!_!_DBN!.log
  (echo !date! !time!     rebuilding !_DBN! && echo.) >> %_SUMMARY% 
  !_DBU! -ar -c "UID=dba;PWD=sql;DBN=!_DBN!;DBF=!_DBF!;ENG=!_ENG!" -o !_LOGFILE!

  (echo !date! !time!     done { !_DBF! } && echo.) >> !_LOGFILE!
  echo moving !_LOGFILE! to %_LOGDIR%
  move !_LOGFILE! %_LOGDIR%
  (echo !date! !time!     done { !_LOGFILE! } && echo.) >> %_SUMMARY%
)
goto:EOF



::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:: RUN ONLY AFTER REBUILD!
:: If the rebuild utility encounters a corrupt/invalid view (usually because 
:: antecendant tables were corrupt or missing) it will leave behind an 
:: unprocessed.sql file. If this file exists, drop all views that sQLAnywhere 
:: considers "invalid" in the systables. Yes, this CAN RESULT IN DATA LOSS, but 
:: if a rebuild failed to fix it, the gxdb was too far gone.
:dropbadv
if exist unprocessed.sql (
  for /F "tokens=*" %%A in (projects.txt) do (
  echo ___ unprocessed.sql, purge corrupt views: %%A

    set _STR=%%A
    set _STR=!_STR: =_!
    call:reverseString !_STR!
    for /f "tokens=1,2 delims=\" %%a in ("!_STR!") do set _CHOP=%%b-%%a
    call:reverseString !_CHOP!
    set _DBN=!_STR!

    set _DBF=%%A\gxdb.db
    set _TMP=%TEMP%tmps_!_DBN!.txt
    set _SQL=select t.table_name from sysobject o, systab t, sysuser u where t.object_id = o.object_id and u.user_id = t.creator and o.status = 2 and o.object_type = 2

    !_DBI! -q -c "UID=dba;PWD=sql;DBN=!_DBN!;DBF=!_DBF!;ENG=!_ENG!" !_SQL! ; output to !_TMP! QUOTE ' ' ALL

    for /F "tokens=*" %%a in (!_TMP!) do (
      !_DBI! -c "UID=dba;PWD=sql;DBN=!_DBN!;DBF=!_DBF!;ENG=!_ENG!" drop view if exists %%a;
      echo %date% %time% ===== dropped corrupt view %%a in %%A
    )
    
    del !_TMP!
    set _CHOP=
    set _STR=
    set _DBN=
  )

  echo moving unprocessed.sql to %_LOGDIR%
  type unprocessed.sql >> %_SUMMARY%
  move unprocessed.sql %_LOGDIR%\unprocessed_sql_!_LOGFILE!.txt
)
goto:EOF


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:: Watch out for other uses of _STR (lazy function)
:reverseString
  set _tmpa=
  set _line=
  set _rline=
  set _rnum=

  set _line=%~1
  set _rnum=0

  :LOOP
  call set _tmpa=%%_line:~%_rnum%,1%%%
  set /a _rnum+=1
  if not "%_tmpa%" equ "" (
  set _rline=%_tmpa%%_rline%
  goto LOOP
  )
  set _STR=%_rline%
goto:EOF


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:clearvar
echo ___ clearing local variables
set _DBI=
set _DBU=
set _ENG=
set _ZZZ=
set _RGX=
set _MAILTO=
set _SMTP=
set _LOGDIR=
set _SUMMARY=
set _DBN=
set _DBF=
set _TMP=
set _SQL=
set _TSTAMP=
set _LOGFILE=
set _STR
set _tmpa=
set _line=
set _rline=
set _rnum=
cls
goto:EOF


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:premail
blat.exe projects.txt -to %_MAILTO% -f ggx_nurse@mycompany.com -server %_SMTP% -subject "%COMPUTERNAME% GGX rebuild launched"
goto:EOF


::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::
:postmail
blat.exe %_SUMMARY% -to %_MAILTO% -f ggx_nurse@mycompany.com -server %_SMTP% -subject "%COMPUTERNAME% GGX rebuild results"
goto:EOF


:END
@echo on
echo GGX_Nurse Complete
