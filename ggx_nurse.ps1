<# 
.SYNOPSIS
Preventative maintenance for LMKR GeoGraphix projects.

.DESCRIPTION
Run this utility periodically on selected projects to:
* remove leftover lock and unloader files (.dbR, .logR, .lok)
* remove accumulated junk temp tables and views
* perform SAP Anywhere's dbunload (like LMKR's ProjectDatabaseRebuilder.exe)
* email start/stop, serious errors, and summary of results
To target a particular project for "nursing", add a text file named
"ggx.nurse" directly in the project's User Files folder. Ex:

C:\ProgramData\GeoGraphix\Projects\Stratton\User Files\ggx.nurse

.PARAMETER default_sender
Email will be sent from this address: ggx_nurse@epcompany.com

.PARAMETER default_recipient
If no emails are specified in trigger files, use this single addresss

.PARAMETER smtp_server
Server to handle PowerShell's Send-MailMessage function: smtp.company.com

.PARAMETER log_dir
Directory to contain time-stamped sets of rebuild logs and other activity

.EXAMPLE
ggx_nurse.ps1 -log_dir "c:\ggxlogs\nurse" 
PowerShell c:\dev\scripts\ggx_nurse.ps1 -email_to rbhughes@logicalcat.com

PowerShell -ExecutionPolicy bypass -File '\\okc1ggx0001\prod_nurse$\ggx_nurse.ps1'

.NOTES
R. Bryan Hughes | rbhughes@logicalcat.com | 303-949-8125
Get-Help .\ggx_nurse.ps1

To run via Scheduled Task (Actions Tab)
Program/script: PowerShell
Add arguments: -ExecutionPolicy bypass -File "\\geoserv\scripts\ggx_nurse.ps1" -log_dir \\whereever\logs
Start in: \\geoserv\scripts

#>



[CmdletBinding()]
param(
  [string]$default_sender = "ggx_nurse@xxxxxx.com",
  [string]$default_recipient = "bhughes1@xxxxxx.com",
  [string]$smtp_server = "smtp.xxxxx.com",
  [string]$log_dir = "c:\\ggx_nurse\\logs"
)



###########################

#Write-Output("{0} --- {1}" -f $a, ($a -match $regex))

# Set-ExecutionPolicy unrestricted

###########################


$logfile #gets defined at runtime for each project
$email_to = New-Object System.Collections.ArrayList


#--------
# Convenience method for writing to stdout and a file.
function Log-Write([string]$s) {
  Write-Host $s -ForegroundColor Yellow
  Add-content $logfile -value $s
}






#---------
# Query the registry to get location of homelist.xml, then parse that
# returns array of project home path strings
function Get-HomeList {
  $ldr = (Get-ItemProperty -path 'HKLM:SOFTWARE\GeoGraphix\Installation Info' -name 'LocalDataRoot').LocalDataRoot
  $hl = $ldr + "HomeList.xml"
  if (Test-Path $hl) {
    [xml]$doc = Get-Content -path $hl
    [array]$homes = $doc.HomeList.Home.LocalPath
    return $homes
  } else {
    Write-Error "Fail! Cannot read HomeList.xml at: $hl"
  }
}

#---------
# What version of Sybase/SAP SQLAnywhere?
# returns version string
function Get-SybDriverName {
  $syb12 = 'HKLM:SOFTWARE\Sybase\SQL Anywhere\SQL Anywhere 12\12.0'
  $syb17 = 'HKLM:SOFTWARE\Sybase\SQL Anywhere\SQL Anywhere 17\17.0'
  
  if (Test-Path $syb17) {
    return "SQL Anywhere 17"
  } elseif (Test-Path $syb12) {
    return "SQL Anywhere 12"
  } else {
    Write-Error "Sybase Driver is not 12 or 17. Update this script!"
  }
}

#---------
# Query the registry for Sybase/SAP installation
# returns string path to dbunload.exe
function Get-DBUnloadPath {
  $syb12 = 'HKLM:SOFTWARE\Sybase\SQL Anywhere\SQL Anywhere 12\12.0'
  $syb17 = 'HKLM:SOFTWARE\Sybase\SQL Anywhere\SQL Anywhere 17\17.0'
  
  if (Test-Path $syb17) {
    return (Get-ItemProperty -path "$syb17" -name 'Location').Location + "BIN64\dbunload.exe"
  } elseif (Test-Path $syb12) {
    return (Get-ItemProperty -path "$syb12" -name 'Location').Location + "BIN64\dbunload.exe"
  } else {
    Write-Error "Sybase Driver is not 12 or 17. Update this script!"
  }
}


#---------
# Check the given string table/view name to see if it matches a known
# naughty pattern. These are semi-documented by LMKR
# returns boolean, leftover (and disposable) or not
function Test-LeftoverTableOrView([string]$objName) {
  #param( [string]$objName )

  $r0 = '^xxxxxxxxxxxxxxxWELL$'
  $r1 = '^R_TEMP_SOURCE.*'
  $r2 = '^WBFTT.*'
  $r3 = '^GGX_TMP_CREATE_ZONES.*'
  $r4 = '^TS_TEMP.*'
  $r5 = '^WELLHEADER_.*'
  $r6 = '^WellHeaderAndBlob_[0-9]{8}'
  $r7 = '^WBS.{32}$'
  #$r8 = '^WBFT[0-9]{8}'

  $regex = "($r0|$r1|$r2|$r3|$r4|$r5|$r6|$r7)"
  
  if ($objName -match $regex) {
    return $true
  } else {
    return $false
  }
}


#---------
# Build a database name string like Discovery does (sorta). It assumes 
# that the project exists in root of home. Doesn't matter much here.
# returns project-home formatted string
function Get-ProjDBN([string]$path) {
  $proj = Split-Path $path -Leaf
  $ph = Split-Path (Split-Path $path) -Leaf
  return ("$proj-$ph" -replace ' ', '_')
}



#---------
# Construct SQLAnywhere connection parameters based on path, etc.
# returns connection parameter string
function Initialize-ConnParams([string] $project) {
  $dbf = "$project\gxdb.db"
  $dbn = Get-ProjDBN($project)
  $eng = "GGX_$env:computername"
  $params = "UID=dba;PWD=sql;DBN=$dbn;DBF=$dbf;ENG=$eng"
  return $params
}



#---------
# Reads content of a trigger file to collect any valid emails. These get
# used by the $email_to variable. Sorry, I forgot where I stole that awful regex--
# will add attribution later--not sure if it fully works yet.
# returns a somewhat-validated email string
function Get-ScrubbedEmail([string] $path) {
  $content = (Get-Content $path)
  if ($content) {
    $re="[a-z0-9!#\$%&'*+/=?^_`{|}~-]+(?:\.[a-z0-9!#\$%&'*+/=?^_`{|}~-]+)*@(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?"
    $m = [regex]::Match($content, $re, "IgnoreCase ")
    return $m.value
  }
}




#---------
# WARNING: can be a bit slow in large environments!
# Recurse through all the project homes managed by this server. If a project's
# User Files folder contains a ggx.nurse file, add it to the list.
# TODO: set recursion depth limit to speed things up a bit
# returns array of project path strings to rebuild
function Get-ProjectRebuildList {
  
  $rebuilds = New-Object System.Collections.ArrayList
  foreach($ph in Get-HomeList) {
    Write-Progress -Activity "Recursing Project Home: $ph"

    if ((Test-Path $ph) -eq $False) { continue }
    $dirs = Get-ChildItem -Directory $ph -Recurse
    
    foreach($adir in $dirs) {
      
      $projggx = $adir.FullName + "\project.ggx.xml"
      $trigger = $adir.FullName + "\User Files\ggx.nurse"
      
      if ((Test-Path $projggx) -and (Test-Path $trigger)) {
        [void]$rebuilds.add($adir.FullName)
        [void]$email_to.add( (Get-ScrubbedEmail($trigger)) )
      }
    }
  }
  return $rebuilds
}



#---------
# Send an email to every recipient parsed from trigger files or default.
# Calling functions determine the subject/body content
function Send-Email([string]$subj, [string]$body) {

  #$email_to = $email_to | ? {$_}
  $email_to = ($email_to | Sort-Object | Get-Unique -AsString)
  if (! $email_to ) {
    #Log-Write "no emails parsed from trigger files. Using default: $default_recipient"
    $email_to = $default_recipient
  }

  try {
    Send-MailMessage -from $default_sender -to $email_to -subject $subj -body $body -SmtpServer $smtp_server -ErrorAction Stop
  } catch {
    $error = $_.Exception.Message
    Write-Error $error
    Write-Error $email_to
    Log-Write $error
    Log-Write $email_to
  }
}



#---------
# Remove some leftover files, known to cause trouble
function Remove-LeftoverFiles([string]$proj) {
  Log-Write "leftover files..."
  $leftovers = Get-ChildItem -Recurse $proj -Include *.dbR, *.logR, *.lok
  foreach ( $x in $leftovers) {
    Remove-Item $x.FullName -Force
    Log-Write "REMOVED: $x"
  }
}



#---------
# Stop GGX Services (ignore dependencies, don't care about order)
# (no logging, email recipients not defined yet)
function Stop-GGXServices {
  Stop-Service -force -displayname "GGX Network Access Service"
  Stop-Service -force -displayname "GGX Database Service"
  Stop-Service -force -displayname "GGX List Service (v2)"
}



#---------
# Start GGX Services
# (no logging, email recipients not defined yet)
function Start-GGXServices {
  Start-Service -displayname "GGX Network Access Service" 
  Start-Service -displayname "GGX Database Service"
  Start-Service -displayname "GGX List Service (v2)"
}




#---------
# 1. Establish a connection to a project's SQLAnywhere database
# 2. Collect a list of all table names
# 3. Regex match on table name, leftovers get added to the "gallows" list
# 4. Collect a list of all view names
# 5. Regex match on view name, leftovers get added to the "gallows" list
# 6. Drop all tables/views that matched the regex
# 7. Collect list of (newly?) invalid views
# 8. Clear and create new gallows list of invalid views
# 9. Drop invalid views
# 10. Catch any errors, and close connection
#
# invalid view query from:
# http://froebe.net/blog/2013/09/04/fw-howto-list-invalid-views-in-sybase-iq/
#
# NOTE: There should only be one set of invalid views after deleting leftover
# tables; by their nature, there shouldn't be sub-dependents. If needed,
# re-work this function to call sa_dependent_views(<table>) instead. 
function Remove-LeftoverTablesAndViews([string] $project) {
  $gallows = New-Object System.Collections.ArrayList

  $params = Initialize-ConnParams($project)
  $driver = Get-SybDriverName
  $connString = "driver={$driver};$params" 

  $conn = New-Object System.Data.Odbc.OdbcConnection
  $conn.ConnectionString = $connString
  $conn.Open()
  
  #-----
  Log-Write "leftover tables..."
  $q_TableNames = "exec sp_tables '%', 'DBA', '%', `"'TABLE'`""
  $cmd = New-Object System.Data.Odbc.OdbcCommand($q_TableNames, $conn)
  $cmd.CommandTimeout = 30
  $ds_TableNames = New-Object System.Data.DataSet
  $da = New-Object System.Data.Odbc.odbcDataAdapter($cmd)
  [void]$da.Fill($ds_TableNames)
  
  foreach ($row in $ds_TableNames.Tables[0].Rows) {
    if (Test-LeftoverTableOrView $row.table_name) {
      $drop = "drop table if exists " + $row.table_name + ";"
      [void]$gallows.Add($drop)
    } 
  }

  #-----
  Log-Write "leftover views..."
  $q_ViewNames = "exec sp_tables '%', 'DBA', '%', `"'VIEW'`""
  $cmd = New-Object System.Data.Odbc.OdbcCommand($q_ViewNames, $conn)
  $cmd.CommandTimeout = 30
  $ds_ViewNames = New-Object System.Data.DataSet
  $da = New-Object System.Data.Odbc.odbcDataAdapter($cmd)
  [void]$da.Fill($ds_ViewNames)

  foreach ($row in $ds_ViewNames.Tables[0].Rows) {
    if (Test-LeftoverTableOrView $row.table_name) {
      $drop = "drop view if exists " + $row.table_name + ";"
      [void]$gallows.Add($drop)
    } 
  }
  
  #-----
  if ( $gallows.Count -gt 0 ) {
    
    $q_drops = $gallows -join ' '
    $cmd = New-Object System.Data.Odbc.OdbcCommand($q_drops, $conn)
    $cmd.CommandTimeout = 30
    $ds_drops = New-Object System.Data.DataSet
    $da = New-Object System.Data.Odbc.odbcDataAdapter($cmd)
    [void]$da.Fill($ds_drops)

    if ($ds_drops.HasErrors) {
      Log-Write "ERRORS encountered when dropping leftover tables/views!"
      Log-Write "(You should probably review in SAP Studio)"
      Log-Write $gallows
    } else {
      Log-Write "drop leftover tables/views:"
      Log-Write $gallows
    }
  }

  #-----
  Log-Write "invalid views..."
  $q_InvalidViews = "select T.table_name from sysobject O, " +
  "systab T, sysuser U where T.object_id = O.object_id and U.user_id = T.creator " +
  "and O.status = 2 and O.object_type = 2"
  $cmd = New-Object System.Data.Odbc.OdbcCommand($q_InvalidViews, $conn)
  $cmd.CommandTimeout = 30
  $ds_InvalidViews = New-Object System.Data.DataSet
  $da = New-Object System.Data.Odbc.odbcDataAdapter($cmd)
  [void]$da.Fill($ds_InvalidViews)

  $gallows.Clear()

  foreach ($row in $ds_InvalidViews.Tables[0].Rows) {
    Write-Host $row.table_name
    $drop = "drop view if exists " + $row.table_name + ";"
    [void]$gallows.Add($drop)
  }

  #-----
  if ( $gallows.Count -gt 0 ) {
    
    $q_drops = $gallows -join ' '
    $cmd = New-Object System.Data.Odbc.OdbcCommand($q_drops, $conn)
    $cmd.CommandTimeout = 30
    $ds_drops = New-Object System.Data.DataSet
    $da = New-Object System.Data.Odbc.odbcDataAdapter($cmd)
    [void]$da.Fill($ds_drops)

    if ($ds_drops.HasErrors) {
      Log-Write "ERRORS encountered when dropping invalid views!"
      Log-Write "(You should probably review in SAP Studio)"
      Log-Write $gallows
    } else {
      Log-Write "drop invalid views:"
      Log-Write $gallows
    }
  }
 
  $conn.Close()
}


#---------
# Run SQLAnywhere dbunload.exe to dump and reinsert all tables.
# Note, we go through some trouble to collect invocation stderr of dbunload.
# Ignore stdout, but log output to append later.
function Invoke-GXDBRebuild([string]$proj, [string]$dbulog) {
  Log-Write "running dbunload..."
  $dbunload = Get-DBUnloadPath
  $params = Initialize-ConnParams($proj)
  $argz = "-ar", "-c", "`"$params`"", "-o", "`"$dbulog`""
  $ignore_stdout = Invoke-Expression "& `"$dbunload`" $argz" -ErrorVariable errz

  if ($LastExitCode -ne 0) {
    [void]$errz.Add($proj)
    [void]$errz.Add("DBUNLOAD invocation failure using:")
    [void]$errz.Add($dbunload + " " +$argz -join " ")
    return ($errz -join "`n`n")
  } else {
    return $true
  }
}



###############################################################################


#----- create $log_dir if it does not exist
if (-Not (Test-Path -Path $log_dir)) {
  New-Item -ItemType directory -Path $log_dir
}

#----- create date-stamp dir for this run
$base = new-item -force -type directory "$log_dir\$(get-date -f yyyy-MM-dd)"


#----- recurse to collect projects. Enforce (paranoid) uniqueness
$rebuilds = Get-ProjectRebuildList
$t0 = $rebuilds.Count
$rebuilds = ($rebuilds | Sort-Object | Get-Unique -AsString)
$t1 = $rebuilds.Count
if ($t0 -ne $t1) {
  LogWrite "REBUILDS NOT UNIQUE! HomeList.xml may be corrupt!!!!!"
}


#----- send start message (we started earlier, but wait for rebuild list)
Send-Email "STARTED ~~~ $env:computername" ($rebuilds -join [Environment]::NewLine)


#----- clear active sessions
Stop-GGXServices


#----- (optional) while services are down, remove leftover files
#foreach($proj in $rebuilds) {
#  Remove-LeftoverFiles $proj
#}

#----- crank up GGX services. Someone might try to reconnect; should be ok.
Start-GGXServices


#----- main project loop (see functions for details)
foreach($proj in $rebuilds) {

  $logfile = Join-Path -Path $base -ChildPath ((Get-ProjDBN($proj)) + "_nurse.log")

  $dbulog = Join-Path -Path $env:temp -ChildPath ((Get-ProjDBN($proj)) + "_dbunload.log")
  
  Log-Write `n$proj

  Remove-LeftoverFiles $proj

  Remove-LeftoverTablesAndViews $proj 

  $rebuild_result = Invoke-GXDBRebuild $proj $dbulog
  if ($rebuild_result -ne $true) {
    Send-Email "ERROR! ~~~ $env:computername" $rebuild_result
  } 
  Add-Content $logfile -value (Get-Content $dbulog)
  Remove-Item $dbulog -Force

  Log-Write "nursing done!"
  Log-Write "$logfile`n`n"
}



#----- send alert email if abnormal exit. Otherwise send end message.
# If dbunload.exe fails--usually because a dependent child view's parent got 
# dropped--it will leave behind an unprocessed.sql file in the same directory
# that dbunload was invoked. It is probably not serious, but you should
# verify, re-run ggx_nurse, and manually delete the unprocessed.sql file.
if ($LastExitCode -ne 0) { 
  Send-Email "ABNORMAL EXIT ~~~ $env:computername" $LastExitCode
} elseif ( Test-Path "unprocessed.sql") {
  Send-Email "ERROR: unprocessed.sql ~~~ $env:computername" (Get-Content "unprocessed.sql")
} else {
  Send-Email "FINISHED ~~~ $env:computername" ($rebuilds -join [Environment]::NewLine)
}
