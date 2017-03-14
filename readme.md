ggx_nurse
---------

### A simple LMKR GeoGraphix Discovery preventative maintenance script.

![red_crosss](/red_cross.png?raw=true "red_cross")
![lmkr_ggx](/lmkr_ggx.png?raw=true "lmkr_ggx")

LMKR's [GeoGraphix Discovery] Suite is a interpretation software package used by geoscientists and engineers in the E&P industry. At the heart of every Discovery project is a SAP (formerly Sybase) [SQLAnywhere] database. Even a modest environment may have dozens of projects containing millions of well and production records, and they are typically distributed across several project servers.

While SQLAnywhere usually does a good job of auto-tuning for daily usage, it can't 
quite handle the aftermath of bulk imports common to Discovery projects. Heavy I/O from busy interpreters and the occasional orphaned temp tables from crashes or spatial query failures eventually degrade performance.

LMKR recognized the need for this maintenance (either preventative or post-mortem) and released a rebuilder utility. However, this utility is unapologetically GUI-only, difficult to automate and rather unreliable. It also doesn't remove orphaned temp tables, lock files, or have robust logging.

---

####The [ggx_nurse] is here to cure all that!

###Features
* Pre and post-email notification
* Logging for every project rebuild and full job summary
* Removes temp and lock files: `.dbR .logR .lok`
* Drops all known "leftover" temp tables and views in project databases
* Tested in Discovery versions 2015.x and 2016.x (others work too)
* Yep, it's just a PowerShell v3 script
* Triggered by user-definable flag files


###Dosage

Run about once a week on your most active Discovery projects to prevent all sorts of ailments. Typically, administrators should run this on each Discovery project server at night via a Scheduled Task. It will stop/start the GGX Services, which will close existing sessions.

The project home will need some free disk space. A good rule of thumb is about 2x the size of largest gxdb.db + gxdb_production.db files among all projects.


###Quick Start

**Trigger Files**

Place a file named `ggx.nurse` directly into a project's "User Files" directory.
Example:

`C:\ProgramData\GeoGraphix\Stratton\User Files\ggx.nurse`

_File content in ggx.nurse is ignored._


###Dependencies and Assumptions:


* Discovery 2015.1 or above is installed
* The server has PowerShell v3 or newer
* Project Homes are accessible to the account running the script
* Normal PowerShell restrictions apply; contact your sys-admins for details.

If you like to live (slightly) dangerously, you can disable PowerShell restrictions like this:

`Set-ExecutionPolicy unrestricted`


[SQLAnywhere]:http://go.sap.com/product/data-mgmt/sql-anywhere.html
[GeoGraphix Discovery]:http://www.lmkr.com/geographix
[ggx_nurse]:https://github.com/rbhughes/ggx_nurse

