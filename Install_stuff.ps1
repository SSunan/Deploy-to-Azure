param (
    $sqlDatabaseName,
    $sqlServerName,
    $sqlUserName,
    $sqlPassword,
    $rootPath,
    $appUser,
    $appPassword,
    $loginMYGServer,
    $loginMYGDatabase,
    $loginMYGUser,
    $loginMYGPassword,
    $versionOfAdapter
    )																						

$sqlServerName = $sqlServerName + ".database.windows.net" #adding DNS suffix to Azure SQL Server name

New-Item -Path "$rootPath" -ItemType "directory" -Force
Set-Location $rootPath
$LogFile = "LOGS_DeployToAzure.log"

function WriteLog
{
    Param ([string]$LogString)
    #$LogFile = "LOGS_DeployToAzure.log"
    $DateTime = "[{0:MM/dd/yyyy} {0:HH:mm:ss}]" -f (Get-Date)
    $LogMessage = "$Datetime $LogString"
    Add-content $LogFile -value $LogMessage
}

WriteLog "Creating root path $rootPath"

$urlDownload = "https://github.com/Geotab/mygeotab-api-adapter/releases/download/"
$zipfileOfAdapter = "/MyGeotabAPIAdapter_SCD_win-x64.zip"
$zipfileOfSQL = "/SQLServer.zip"
$urlforzipfileAdapter = $urlDownload + $versionOfAdapter + $zipfileOfAdapter
$urlforzipfileSQL = $urlDownload + $versionOfAdapter + $zipfileOfSQL
$packages = $($urlforzipfileAdapter, $urlforzipfileSQL)

Foreach ($p in $packages)
{   
    $fileName = ($p -split "/")[-1]
    Invoke-WebRequest -Uri $p -UseBasicParsing -outfile $fileName -Verbose   
    Expand-Archive $fileName -Force -Verbose -DestinationPath $rootPath
	WriteLog "Downloading $p and saving as $fileName"
}

##SQL Server Module Install:
Install-PackageProvider -Name NuGet -RequiredVersion 2.8.5.201 -Force -Verbose
#Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
#Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force -Verbose
Install-Module -Name SqlServer -Repository PSGallery -Force -Verbose -AllowClobber 
Install-Module Az.Accounts -MinimumVersion 2.2.0 -Repository PSGallery -Force -Verbose -AllowClobber #needed for MSI login

WriteLog "Trying to connect to SQL Server: $sqlServerName"
#Wait-Event -Timeout 120
Wait-Event -Timeout 30

$createlogin = "CREATE LOGIN [$appUser] WITH PASSWORD=N'$appPassword'"
$createappuser = "CREATE USER [$appUser] FOR LOGIN [$appUser] WITH DEFAULT_SCHEMA=[dbo]; ALTER ROLE [db_datareader] ADD MEMBER [$appUser]; ALTER ROLE [db_datawriter] ADD MEMBER [$appUser];"
$excutescript = "$rootPath\SQLServer\geotabadapterdb-DatabaseCreationScript.sql"
#$sqllogfile = "sql001.log"

WriteLog "CREATE LOGIN [$appUser]."
Invoke-Sqlcmd -ServerInstance $sqlServerName `
            -Database 'master' `
            -Username $sqlUserName `
            -Password $sqlPassword `
            -Query $createlogin `
            -Verbose *>> $LogFile

WriteLog "CREATE USER [$appUser]."	
Invoke-Sqlcmd -ServerInstance $sqlServerName `
            -Database $sqlDatabaseName `
            -Username $sqlUserName `
            -Password $sqlPassword `
            -Query $createappuser `
            -Verbose *>> $LogFile
		
WriteLog "Execute the script file $excutescript."
Invoke-Sqlcmd -ServerInstance $sqlServerName `
            -Database $sqlDatabaseName `
            -Username $sqlUserName `
            -Password $sqlPassword `
            -InputFile $excutescript `
            -Verbose *>> $LogFile

$appSettingsFile = "$rootPath\MyGeotabAPIAdapter_SCD_win-x64\appsettings.json"
$pattern = '//"Database'

#strip out JSON-invalid comment lines
$output = Get-Content $appSettingsFile | Where-Object { $_ -notmatch $pattern}
$output | Set-Content $appSettingsFile #PS didn't like reading from and writing back to the config file in the same line

#manipulate JSON config:
$json = Get-Content $appSettingsFile -Raw | ConvertFrom-Json -Verbose
$json.DatabaseSettings.DatabaseProviderType = 'SQLServer'
$json.DatabaseSettings.DatabaseConnectionString  = "Server=$sqlServerName;Database=$sqlDatabaseName;User Id=$appUser;Password=$appPassword"
$json.LoginSettings.MyGeotabServer  = "$loginMYGServer"
$json.LoginSettings.MyGeotabDatabase  = "$loginMYGDatabase"
$json.LoginSettings.MyGeotabUser  = "$loginMYGUser"
$json.LoginSettings.MyGeotabPassword  = "$loginMYGPassword"
$json | ConvertTo-Json -Depth 32 | Set-Content $appSettingsFile

WriteLog "Updated the appsettings.json file."

#create a Task Scheduler to run the Adapter automatically 
$PSFileName = "psfile_01.ps1"
New-Item -Path $rootPath -Type "file" -Name $PSFileName 
$AdapterLocation = "$rootPath\MyGeotabAPIAdapter_SCD_win-x64"

Set-Content $PSFileName '#This is the script to create a task scheduler for loading the API Adapter.'
Add-Content $PSFileName 'Import-Module ScheduledTasks'
Add-Content $PSFileName '$description = "This task loads the MyGeotab API Adapter automatically at the time when it has been deployed."'
Add-Content $PSFileName '$WorkingLocation = "' -NoNewline
Add-Content $PSFileName -Value $AdapterLocation -NoNewline
Add-Content $PSFileName '"'
Add-Content $PSFileName '$DateTime_TS = (Get-Date).AddMinutes(1)'
Add-Content $PSFileName '$action = New-ScheduledTaskAction -Execute "C:\Windows\System32\cmd.exe" -Argument "/c MyGeotabAPIAdapter.exe" -WorkingDirectory "$WorkingLocation\"'
Add-Content $PSFileName '$trigger = New-ScheduledTaskTrigger -AtStartup -RandomDelay (New-TimeSpan -Minute 1)'
Add-Content $PSFileName '$principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest'
Add-Content $PSFileName '$settings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable -WakeToRun -ExecutionTimeLimit 0'
Add-Content $PSFileName '$task = New-ScheduledTask -Action $action -Description $description -Trigger $trigger -Settings $settings -Principal $principal'
Add-Content $PSFileName 'Register-ScheduledTask "Load_MyGeotabAPIAdapter" -InputObject $task'
Add-Content $PSFileName 'Start-ScheduledTask -TaskName "Load_MyGeotabAPIAdapter"'

WriteLog "Created file $PSFileName for Windows Scheduled Task in the server $env:computername."
Wait-Event -Timeout 30
Powershell.exe ".\$PSFileName"
WriteLog "Created Windows Scheduled Task named Load_MyGeotabAPIAdapter successfully in the server $env:computername."
