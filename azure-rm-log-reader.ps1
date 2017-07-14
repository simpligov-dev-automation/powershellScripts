<#  
.SYNOPSIS  
    powershell script to query azure rm logs used with quickstart template deployment

.DESCRIPTION  
    github: https://raw.githubusercontent.com/jagilber/powershellScripts/master/azure-rm-log-reader.ps1
    gallery: https://gallery.technet.microsoft.com/Azure-Resource-Manager-c1ce252c 

    script authenticates to azure rm 
    runs get-azurermlog and get-azurermresourcegroupdeployment
    colors certain event and deployment operations 
    listbox allows for viewing specific event and deployment details
    can export all events / deployments to text file
    
    requires wmf 5 +
    requires azurerm sdk

.NOTES  
   Author : jagilber
   File Name  : azure-rm-log-reader.ps1
   Version    : 170712 v2
   History    : 

.EXAMPLE  
    .\azure-rm-log-reader.ps1
    query azure rm for all resource manager and deployment logs

.EXAMPLE  
    .\azure-rm-log-reader.ps1 -details
    query azure rm for all resource manager logs and output additional detail to console

.EXAMPLE  
    .\azure-rm-log-reader.ps1 -deploymentname rds-deployment -resourcegroupname rds-1
    query azure rm for all resource manager and deployment logs for rds-deployment and rds-1

.PARAMETER cacheMinutes
    optional int parameter to keep cache of resource groups and deployments before requerying. default is 5 minutes.

.PARAMETER deploymentName
    optional string parameter to view specific deployment

.PARAMETER detail
    optional switch parameter to view event detail in console

.PARAMETER enumSubscriptions
    optional switch to enumerate subscriptions for selection to use

.PARAMETER eventStartTime
    optional date parameter to view logs from specific time. default is -1 day. azure does not keep some events for more than a couple of hours.

.PARAMETER resourcegroupName
    optional string parameter to view specific resource group

.PARAMETER subscriptionId
    optional string parameter to specify subscription id to use

.PARAMETER update
    optional switch to check github for latest version of script
#>  

[CmdletBinding()]
param (
    [int]$cacheMinutes=5,
    [string]$deploymentName,
    [switch]$detail,
    [switch]$enumSubscriptions,
    [DateTime]$eventStartTime=[DateTime]::MinValue,
    [string]$resourceGroupName,
    [string]$subscriptionId,
    [switch]$update
)

$ErrorActionPreference = "Continue" #"SilentlyContinue"
$error.Clear()
Add-Type -AssemblyName PresentationFramework            
Add-Type -AssemblyName PresentationCore  

$global:cacheMinutes = $cacheMinutes
$global:completed = 0
$global:deployments = @{}
$global:deploymentUpdate = [DateTime]::MinValue
$global:eventStartTime = $eventStartTime
$global:exportFile = "azure-rm-log-reader-export.txt"
$global:groups = @{}
$global:index = @{}
$global:jobName = "bgJob"
$global:listbox = $null
$global:listboxEvent = $null
[timespan]$global:refreshTime = "0:0:10.0"#"0:1:00.0"
$global:resourcegroupUpdate = [DateTime]::MinValue
$global:scriptName = $null
$global:subscription = $subscriptionId
$global:timer = $null
$global:window = $null
$updateUrl = "https://raw.githubusercontent.com/jagilber/powershellScripts/master/azure-rm-log-reader.ps1"
$global:profileContext = "$($env:TEMP)\ProfileContext.ctx"

# ----------------------------------------------------------------------------------------------------------------
function main()
{
    [xml]$xaml = @"
    <Window 
        xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        x:Name="Window" Title="$($MyInvocation.ScriptName)" WindowStartupLocation = "CenterScreen" ResizeMode="CanResize"
        ShowInTaskbar = "True" Background = "lightgray" Width="1200" Height="800"> 
        <DockPanel>
        <Grid>
            <Grid.RowDefinitions>
                <RowDefinition Height="25" />
                <RowDefinition Height="*" />
                <RowDefinition Height="5" />
                <RowDefinition Height="500" />
            </Grid.RowDefinitions>
            <Label x:Name="labelRefresh" Width="100" Margin="0,0,0,0" HorizontalAlignment="Left" Content="Last Refresh:" Grid.Row="0"/>
            <Label x:Name="labelRefreshTime" Width="100" Margin="100,0,0,0" HorizontalAlignment="Left" Content="" Grid.Row="0"/>
            <Label x:Name="labelGroups" Width="100" Margin="200,0,0,0" HorizontalAlignment="Left" Content="Groups Count:" Grid.Row="0"/>
            <Label x:Name="labelGroupsCount" Width="50" Margin="300,0,0,0" HorizontalAlignment="Left" Content="" Grid.Row="0"/>
            <Label x:Name="labelDeployments" Width="125" Margin="350,0,0,0" HorizontalAlignment="Left" Content="Deployments Count:" Grid.Row="0"/>
            <Label x:Name="labelDeploymentsCount" Width="50" Margin="475,0,0,0" HorizontalAlignment="Left" Content="" Grid.Row="0"/>
            <Label x:Name="labelEvents" Width="100" Margin="525,0,0,0" HorizontalAlignment="Left" Content="Events Count:" Grid.Row="0"/>
            <Label x:Name="labelEventsCount" Width="50" Margin="625,0,0,0" HorizontalAlignment="Left" Content="" Grid.Row="0"/>
            <Button x:Name="exportButton" Width="100" Margin="0,0,200,0" HorizontalAlignment="Right" Content="Export" Grid.Row="0"/>
            <Button x:Name="refreshButton" Width="100" Margin="0,0,0,0" HorizontalAlignment="Right" Content="Refresh" Grid.Row="0"/>
            <Button x:Name="clearButton" Width="100" Margin="0,0,100,0" HorizontalAlignment="Right" Content="Clear" Grid.Row="0"/>
            <ListBox x:Name="listbox" Grid.Row="1" Height="Auto" />
            <GridSplitter Grid.Row="2" Height="5" HorizontalAlignment="Stretch" />
            <ListBox x:Name="listboxEvent" Grid.Row="3" Height="Auto" />
           </Grid>
      </DockPanel>
    </Window>
"@

    get-workingDirectory
    authenticate-azureRm

    # set sub if passed as argument. requires auth
    if(![string]::IsNullOrEmpty($subscriptionId) -or $enumSubscriptions)
    {

        if($enumSubscriptions)
        {
            $null = get-subscriptions
        }
        else
        {
            # set subscription
            Set-AzureRmContext -SubscriptionId $subscriptionId
            # save context for jobs
            Save-AzureRmContext -Path $global:profileContext -Force 
        }
    }

    $global:Window=[Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
    $global:timer = new-object Windows.Threading.DispatcherTimer

    $global:scriptname = [IO.Path]::GetFileNameWithoutExtension($MyInvocation.ScriptName)
    
    if($update)
    {
        if((get-update -updateUrl $updateUrl -destinationFile $global:scriptname))
        {
            write-host "file updated. restart script."
            return
        }
    }

    #Connect to Controls
    $clearButton = $global:Window.FindName('clearButton')
    $exportButton = $global:Window.FindName('exportButton')
    $refreshButton = $global:Window.FindName('refreshButton')
    $refreshLabel = $global:Window.FindName('labelRefreshTime')
    $groupsLabel = $global:Window.FindName('labelGroupsCount')
    $deploymentsLabel = $global:Window.FindName('labelDeploymentsCount')
    $eventsLabel = $global:Window.FindName('labelEventsCount')

    $global:listbox = $global:Window.FindName('listbox')
    $global:listboxEvent = $global:Window.FindName('listboxEvent')

    $global:listbox.Add_SelectionChanged({open-event})

    if($global:eventStartTime -eq [DateTime]::MinValue)
    {
        $global:eventStartTime =  ([DateTime]::Now).AddDays(-1)
    }
    else
    {
        $eventStartTimeConvert
        if([DateTime]::TryParse($global:eventStartTime,[ref] $global:eventStartTimeConvert))
        {
            $global:eventStartTime = $eventStartTimeConvert
        }
        else
        {
            $global:eventStartTime =  ([DateTime]::Now).AddDays(-1)
        }
    }
    
    $global:Window.Add_Closing({
        $global:completed = 1
        $global:timer.Stop()
        get-job -Name $global:jobName | receive-job
        get-job -Name $global:jobName | remove-job -Force
    })
    
    $global:Window.Add_Loaded({

        $global:timer.Add_Tick({

            if($global:completed)
            {
                $global:timer.Stop()
            }

            write-host "$([DateTime]::Now) timer start routine"

            $jobResults = receive-backgroundJob

            if($jobResults.GroupOutput)
            {
                foreach($result in $jobResults.GroupOutput.GetEnumerator())
                {
                    if($result.Value)
                    {
                        foreach($item in $result.Value)
                        {
                            add-eventItem -lbitem $item -color "Yellow"
                        }
                    }
                }
            }

            if($jobResults.DeploymentOutput)
            {
                foreach($result in $jobResults.DeploymentOutput.GetEnumerator())
                {
                    if($result.Value)
                    {
                        foreach($item in $result.Value)
                        {
                            add-depitem -lbitem $result.Value -color "DarkOrange"                
                        }
                    }
                }
            }

            #check-backgroundJob
            #run-commands
            $global:listbox.Items.SortDescriptions.Clear()
            $global:listbox.Items.SortDescriptions.Add((new-object ComponentModel.SortDescription("Content", [ComponentModel.ListSortDirection]::Descending)))     

            $deploymentsLabel.Content = $jobResults.Deployments.Count
            $groupsLabel.Content = $jobResults.ResourceGroups.Count
            $refreshLabel.Content = [DateTime]::Now.ToLongTimeString()
            $eventsLabel.Content = $global:listbox.Items.Count


            write-host "$([DateTime]::Now) finished timer"
        })

        write-host "form loaded:"
        
        #[Windows.Input.Mouse]::SetCursor([Windows.Input.Cursors]::AppStarting)
        #run-commands    
        #[Windows.Input.Mouse]::SetCursor([Windows.Input.Cursors]::Arrow)

        $deploymentsLabel.Content = $global:deployments.Count
        $groupsLabel.Content = $global:groups.Count
        $refreshLabel.Content = [DateTime]::Now.ToLongTimeString()
        $eventsLabel.Content = $global:listbox.Items.Count

        #Start timer
        $global:timer.Interval = [TimeSpan]$global:refreshTime
        $global:timer.Start()
    })

    #Events
    $clearButton.Add_Click({ clear-list })
    $exportButton.Add_Click({ export-list })
    $refreshButton.Add_Click({ reset-list })

    try
    {
        $null = start-backgroundJob
        $global:Window.ShowDialog()
    }
    catch
    {
        write-host "window:exception:$($error)"
        #$error.Clear()
    }
    finally
    {
        $global:completed = 1
        $global:timer.Stop()

        get-job -Name $global:jobName | receive-job -ErrorAction SilentlyContinue
        get-job -Name $global:jobName -ErrorAction SilentlyContinue | remove-job -Force -ErrorAction SilentlyContinue

        if([IO.File]::Exists($global:profileContext))
        {
            [IO.File]::Delete($global:profileContext)
        }
    }
}

# ----------------------------------------------------------------------------------------------------------------
function add-depitem($lbitem, $color)
{
    try
    {
        [Windows.Controls.ListBoxItem]$lbi = new-object Windows.Controls.ListBoxItem
        $lbi.Background = $color
        $failed = $false
        $state = $lbitem.ProvisioningState

        if([string]::IsNullOrEmpty($state)) 
        { 
            $state = $lbitem.Properties.ProvisioningState 
        }

        $operation = $lbitem.ProvisioningOperation 

        if([string]::IsNullOrEmpty($operation))
        {
            $operation = $lbitem.Properties.ProvisioningOperation
        }

        if($state -imatch "Failed")
        {
            $lbi.Background = "Red"
            $failed = $true
        }
        elseif($state -imatch "Succeeded" -and $operation -imatch "EvaluateDeploymentOutput")
        {
            $lbi.Background = "Chartreuse"
        }
        elseif($state -imatch "Succeeded")
        {
            $lbi.Background = "YellowGreen"
        }
        elseif($state -imatch "Started")
        {
            $lbi.Background = "LightGreen"
        }
        elseif($state -imatch "Completed")
        {
            $lbi.Background = "Gray"
        }

        $lbi.Content = "$((get-localTime -time (get-time -item $lbitem)))" `
            + "   DEPLOYMENT: $($lbitem.ResourceGroupName)" `
            + "   $($lbItem.DeploymentName)" `
            + "   $($state)" `
            + "   $($operation)" `
            + "   $($lbitem.Properties.TargetResource.resourceType)" `
            + "   $($lbitem.Properties.TargetResource.resourceName)" `
            + "   $($lbitem.Output)"
    
        if(!$global:index.ContainsKey((get-time -item $lbitem)))
        {
            if($detail)
            {
                if($failed)
                {
                    write-host $lbi.Content -BackgroundColor Red
                }
                else
                {
                    write-host $lbi.Content -BackgroundColor Green
                }
            }

            $lbi.Tag = $lbitem
            $ret = $global:listbox.Items.Insert(0,$lbi)
            $global:index.Add((get-time -item $lbitem),$($lbitem.CorrelationId))
        }
        else
        {
            if($detail)
            {
                write-host "$(($item | out-string)) exists"
            }
        }
    }
    catch
    {
        write-host "add-depitem:exception:$($error)"
        $error.Clear()
    }
}

# ----------------------------------------------------------------------------------------------------------------
function add-eventItem($lbitem, $color)
{
    [Windows.Controls.ListBoxItem]$lbi = new-object Windows.Controls.ListBoxItem

    $lbi.Background = $color
    $failed = $false

    if($lbitem.Status -imatch "Fail")
    {
        $lbi.Background = "Red"
        $failed = $true
    }
    elseif($lbitem.Status -imatch "Succeeded")
    {
        $lbi.Background = "LightBlue"

        if($lbitem.OperationName -imatch "delete")
        {
            $lbi.Background = "DarkGray"
        }
    }
    elseif($lbitem.Status -imatch "Started")
    {
        $lbi.Background = "LightGreen"
    }
    elseif($lbitem.Status -imatch "Completed")
    {
        $lbi.Background = "Gray"
    }

    $statusCode = [string]::Empty

    if([regex]::IsMatch($lbitem.Properties,"statusCode.\W+:\W+(.+)"),[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    {
        $statusCode = [string](([regex]::Match($lbitem.Properties,"statusCode.\W+:\W+(.+)",[Text.RegularExpressions.RegexOptions]::IgnoreCase)).Groups[1].Value).Trim()
    }

    $statusMessage = [string]::Empty

    if([regex]::IsMatch($lbitem.Properties,"statusMessage.\W+:\W+`"(.+)`""),[Text.RegularExpressions.RegexOptions]::IgnoreCase)
    {
        $statusMessage = [string](([regex]::Match($lbitem.Properties,"statusMessage.\W+:\W+`"(.+)`"",[Text.RegularExpressions.RegexOptions]::IgnoreCase)).Groups[1].Value).Trim()
    }

    if($lbitem.Properties.Content.statusMessage -ne $null) 
    { 
        $statusMessage = $lbitem.Properties.Content.statusMessage
    }

    # take first two directories from operationname and use to find additional information in resourceid
    $opNameBase = [string]::Empty
    
    if([regex]::IsMatch($lbitem.OperationName,'^(.+?/.+?)/',[Text.RegularExpressions.RegexOptions]::IgnoreCase))
    {
        $opNameBase = ([regex]::Match($lbitem.OperationName,'^(.+?/.+?)/')).Groups[1].Value
    }

    $resourcePath = [string]::Empty

    if([regex]::IsMatch($lbitem.ResourceId,$opNameBase,[Text.RegularExpressions.RegexOptions]::IgnoreCase))
    {
        $resourcePath = ([regex]::Match($lbitem.ResourceId,"($($opNameBase).+)")).Groups[1].Value
    }
    else
    {
        $resourcePath = [IO.Path]::GetFileName($lbitem.ResourceId)
    }

    $lbi.Content = "$((get-localTime -time (get-time -item $lbitem)))" `
        + "   EVENT: $($lbitem.ResourceGroupName)" `
        + "   $($lbitem.Status)" `
        + "   $($lbitem.SubStatus)" `
        + "   STATUS: $($statusCode)" `
        + "   MESSAGE: $($statusMessage)" `
        + "   $($resourcePath)"
    
    if($lbItem.EventDataId -eq $null -or !$global:index.ContainsKey((get-time -item $lbitem)))
    {
        if($detail)
        {
            if($failed)
            {
                write-host $lbi.Content -BackgroundColor Red
            }
            else
            {
                write-host $lbi.Content -BackgroundColor Green
            }
        }

        if($lbitem.EventTimeStamp -gt $global:eventStartTime)
        {
            $global:eventStartTime = $lbitem.EventTimeStamp
        }

        $lbi.Tag = $lbitem
        $ret = $global:listbox.Items.Insert(0,$lbi)
        $global:index.Add((get-time -item $lbitem),$($lbitem.CorrelationId))
    }
    else
    {
        if($detail)
        {
            write-host "$(($item | out-string)) exists"
        }
    }
}

# ----------------------------------------------------------------------------------------------------------------
function authenticate-azureRm($context = $Null)
{

    if($context)
    {
        $ctx = $null
        $ctx = Import-AzureRmContext -Path $context
        # bug to be fixed 8/2017
        # From <https://github.com/Azure/azure-powershell/issues/3954> 
        [void]$ctx.Context.TokenCache.Deserialize($ctx.Context.TokenCache.CacheData)
        return $true
    }

    # make sure at least wmf 5.0 installed
    if ($PSVersionTable.PSVersion -lt [version]"5.0.0.0")
    {
        write-host "update version of powershell to at least wmf 5.0. exiting..." -ForegroundColor Yellow
        start-process "https://www.bing.com/search?q=download+windows+management+framework+5.0"
        # start-process "https://www.microsoft.com/en-us/download/details.aspx?id=50395"
        exit
    }

    #  verify NuGet package
	$nuget = get-packageprovider nuget -Force

	if (-not $nuget -or ($nuget.Version -lt [version]::New("2.8.5.22")))
	{
		write-host "installing nuget package..."
		install-packageprovider -name NuGet -minimumversion ([version]::New("2.8.5.201")) -force
	}

    $allModules = (get-module azure* -ListAvailable).Name
	#  install AzureRM module
	if ($allModules -inotcontains "AzureRM")
	{
        # at least need profile, resources, insights, logicapp
        if ($allModules -inotcontains "AzureRM.profile")
        {
            write-host "installing AzureRm.profile powershell module..."
            install-module AzureRM.profile -force
        }
        if ($allModules -inotcontains "AzureRM.resources")
        {
            write-host "installing AzureRm.resources powershell module..."
            install-module AzureRM.resources -force
        }
        if ($allModules -inotcontains "AzureRM.insights")
        {
            write-host "installing AzureRm.insights powershell module..."
            install-module AzureRM.insights -force
        }
        if ($allModules -inotcontains "AzureRM.logicapp")
        {
            write-host "installing AzureRm.logicapp powershell module..."
            install-module AzureRM.logicapp -force

        }
            
        Import-Module azurerm.profile        
        Import-Module azurerm.resources        
        Import-Module azurerm.insights
        Import-Module azurerm.logicapp
		#write-host "installing AzureRm powershell module..."
		#install-module AzureRM -force
        
	}
    else
    {
        Import-Module azurerm
    }

    # authenticate
    try
    {
        $rg = @(Get-AzureRmResourceGroup)
                
        if($rg)
        {
            write-host "job:auth passed $($rg.Count)"
        }
        else
        {
            write-host "job:auth error $($error)" -ForegroundColor Yellow
            throw [Exception]
        }
    }
    catch
    {
        try
        {
            Add-AzureRmAccount
        }
        catch
        {
            write-host "exception authenticating. exiting $($error)" -ForegroundColor Yellow
            exit 1
        }
    }

    Save-AzureRmContext -Path $profileContext -Force
}

# ----------------------------------------------------------------------------------------------------------------
function check-backgroundJob()
{
    Write-Verbose "check-backgroundjob:enter"

    $job = $null

    if(!($job = get-job -Name $global:jobName -ErrorAction SilentlyContinue))
    {
        write-host "job does not exist: $($global:jobName)"
        $job = start-backgroundJob
    }
    else
    {
        if($detail)
        {
            write-host "job exists: $($global:jobName)"
        }
    }

    if($job.State -ine "Running")
    {
        write-host "job state: $($job.State)"
        $job = start-backgroundJob
    }

    if($detail)
    {
        write-host "job state: $($job.State)"
    }
}

# ----------------------------------------------------------------------------------------------------------------
function clear-list()
{
    $global:listbox.Items.Clear()
    $global:listboxEvent.Items.Clear()
    $global:index.Clear()
    #$global:eventStartTime = [DateTime]::Now.AddDays(-1)
}

# ----------------------------------------------------------------------------------------------------------------
function do-backgroundJob($jobInfo)
{
    $count = 0
    while ($true)
    {
        write-host "doing background job $($jobInfo.action)"
        # for job debugging
        # when attached with -debug switch, set $jobInfo.debugPreference to SilentlyContinue to debug
        while($jobInfo.debugPreference -imatch "Inquire")
        {
		    write-host "waiting to debug background job $($jobInfo.action) : $($jobInfo.debugPreference)"
		    write-host "set jobInfo.debugPreference = SilentlyContinue to break debug loop"
            start-sleep -Seconds 1
        }

        authenticate-azureRm -context $jobInfo.profileContext

        # set global start time from job
        $global:eventStartTime = $jobInfo.eventStartTime
        $currentTimeStamp = 0
        $rgCount = 0

        while($true)
        {
            $jobResults = new-jobResults

            try
            {
                # wait for command
                if($jobInfo.detail)
                {
                    write-host "$([DateTime]::Now) job:running commands"
                }

                $error.clear()
                $jobResults = run-commands -jobObject $jobResults
                $jobResults.LastUpdateTime = [DateTime]::Now

                if($jobInfo.detail)
                {
                    write-host "$([DateTime]::Now) job:finished processing results count: $($jobResults.Output.Count)"
                    write-host "results: $($jobResults | format-list * | out-string)"
                }

                # output result object
                $jobResults
            }
            catch
            {
                $jobResults.LastResult = $error
                $jobResults
                $error.Clear()

                #if(!authenticate-azurerm)
                #{
                 #   return
                #}
            }

            Start-Sleep -Seconds 10
        }

        $jobInfo.result = $count
        $jobInfo
        Start-Sleep -Seconds ($global:refreshTime / 2)
        $count++
    }
}

# ----------------------------------------------------------------------------------------------------------------
function enum-deployments($resoureGroup = ".")
{
    if(![string]::IsNullOrEmpty($deploymentname))
    {
        return ($global:deployments = @{$resoureGroup = @{$deploymentname = 0}})
    }

    if([DateTime]::Now.AddMinutes(-$global:cacheMinutes) -gt [DateTime]$global:deploymentUpdate)
    {
        $global:deploymentUpdate = [DateTime]::Now

        foreach($group in (enum-resourceGroups).GetEnumerator())
        {
            $deployments = (Get-AzureRmResourceGroupDeployment -ResourceGroupName $($group.Key)).DeploymentName

            foreach($deployment in $deployments)
            {
                if(!$global:deployments.ContainsKey($group.Key))
                {
                    $global:deployments.Add($group.Key,@{})    
                }

                if($deployment.TimeStamp -gt $global:eventStartTime)
                {
                    if(!$global:deployments[$group.Key].ContainsKey($deployment.DeploymentName))
                    {
                        $global:deployments[$group.Key].Add($deployment.DeploymentName, 0)
                    }
                }
            }
        }
    }

    return ($global:deployments | Where-object Keys -imatch $resoureGroup).Values
}

# ----------------------------------------------------------------------------------------------------------------
function enum-resourceGroups()
{
    $global:groups = @{}
    if(![string]::IsNullOrEmpty($resourceGroupName))
    {
        
        $global:groups.Add($resourcegroupname,0)
        return ($global:groups)
    }

    if([DateTime]::Now.AddMinutes(-$global:cacheMinutes) -gt [DateTime]$global:resourcegroupUpdate)
    {
        $groups = (Get-AzureRmResourceGroup | Get-AzureRmResourceGroupDeployment | Where-Object TimeStamp -gt $($global:eventStartTime) | Select-Object ResourceGroupName -Unique).ResourceGroupName
        
        if($groups.Count -eq 0)
        {
            $groups = (Get-AzureRmResourceGroup  | Select-Object ResourceGroupName -Unique).ResourceGroupName
        }

        foreach($group in $groups)
        {
            $global:groups.Add($group,0)
        }
    }

    return $global:groups
}

# ----------------------------------------------------------------------------------------------------------------
function export-list()
{
    [Windows.Input.Mouse]::SetCursor([Windows.Input.Cursors]::AppStarting)

    [Text.StringBuilder]$sb = new-object Text.StringBuilder
    $fileName = "$(get-location)\$([DateTime]::Now.ToString("yyyy-MM-dd-HH-mm"))-$($global:exportFile)"

    if([IO.File]::Exists($fileName))
    {
        write-host "deleting file $($fileName)"
        [IO.File]::Delete($fileName)    
    }
    
    $sb.AppendLine("{")
    foreach($item in $global:listbox.Items)
    {
        if($detail)
        {
            write-host "exporting: $($item.Content)"
        }

        $sb.AppendLine("//----------------------------------------------------------------------------------------")
        $sb.AppendLine("//$($item.Content.ToString().Trim())")
        #$sb.AppendLine("$($item.Tag | ConvertTo-Json -Depth 100),")
        $sb.AppendLine("$(format-record -inputString ($item.Tag | ConvertTo-Json -Depth 100)),")
    }
    
    out-file -Append -InputObject "$($sb.ToString().Trim(","))}" -FilePath $fileName
    write-host "finished exporting to: $([IO.Path]::GetFullPath($fileName))"

    start-process $fileName
    [Windows.Input.Mouse]::SetCursor([Windows.Input.Cursors]::Arrow)
}

# ----------------------------------------------------------------------------------------------------------------
function format-eventView($item,$listBoxItem)
{
    if(($item | format-list | out-string) -imatch "(level.+\:.+Error)|provisioningstate.+\:.+failed")
    {
        $listBoxItem.Background = "AliceBlue"
        $listBoxItem.Foreground = "Red"

        if($detail)
        {
            write-host ($item | format-list * | out-string) -BackgroundColor Red
        }
    }
    else
    {
        $listBoxItem.Background = "AliceBlue"
        $listBoxItem.Foreground = "Green"

        if($detail)
        {
            write-host ($item | format-list * | out-string) -BackgroundColor Green
        }
    }

    return $listBoxItem
}

# ----------------------------------------------------------------------------------------------------------------
function format-record([string]$inputString)
{
    #get rid of in order:
    # \" literal
    # " literal
    # new line literals and replace with new line tab tab
    # { and replace with { new line tab tab
    # } and replace with } new line tab tab
    # , new line and replace with new line
    # , and replace with new line tab tab

    return ((($inputString).Replace("\u0027","'").Replace("\`"","").Replace("`"","").Replace("\r\n","`r`n`t`t").Replace("{","{`r`n`t`t").Replace("}","`r`n`t`t}") -replace ",`r`n","`r`n") -replace ",","`r`n`t`t")
}

# ----------------------------------------------------------------------------------------------------------------
function get-localTime([string]$time)
{
    if(![string]::IsNullOrEmpty($time))
    {
        $time = $time.Replace("Z","")
        return [System.TimeZoneInfo]::ConvertTimeFromUtc($time, [System.TimeZoneInfo]::Local).ToString("o")
    }

    return $null
}

# ----------------------------------------------------------------------------------------------------------------
function get-subscriptions()
{
    write-host "enumerating subscriptions"
    $subList = @{}
    $subs = Get-AzureRmSubscription -WarningAction SilentlyContinue
    $newSubFormat = (get-module AzureRM.Resources).Version.ToString() -ge "4.0.0"
            
    if($subs.Count -gt 1)
    {
        [int]$count = 1
        foreach($sub in $subs)
        {
           if($newSubFormat)
           { 
                $message = "$($count). $($sub.name) $($sub.id)"
                $id = $sub.id
           }
           else
           {
                $message = "$($count). $($sub.SubscriptionName) $($sub.SubscriptionId)"
                $id = $sub.SubscriptionId
           }

            write-host $message
            [void]$subList.Add($count,$id)
            $count++
        }
        
        [int]$id = Read-Host ("Enter number for subscription to enumerate or {enter} to query all:")
        $null = Set-AzureRmContext -SubscriptionId $subList[$id].ToString()
    }
    
    return
}

# ----------------------------------------------------------------------------------------------------------------
function get-time($item)
{
    $retVal = ($global:eventStartTime).ToString("o")

    try
    {
        if($item -eq $null)
        {
            return $retVal
        }

        if(($utcTime = $item.TimeStamp) -eq $null)
        {
            if(($utcTime = $item.EventTimeStamp) -eq $null)
            {
                if(($utcTime = $item.Properties.TimeStamp) -eq $null)
                {
                    return $retVal
                }
                else
                {
                    $utcTime = $item.Properties.TimeStamp
                }
            }
            else
            {
                $utcTime = $item.EventTimeStamp
            }
        }
        else
        {
            $utcTime = $item.TimeStamp
        }
        
        if([string]::IsNullOrEmpty($utcTime) -or !([DateTime]::Parse($utcTime)))
        {
            write-host "get-time: returning current time"
            return $retVal
        }

        try
        {
            $retVal = $utcTime.ToString("o")
        }
        catch
        {
            $error.clear()
            return $utcTime
        }
        
        return $retVal
    }
    catch
    {
        write-host "exception:get-time $($error)"
        $error.Clear()
        return $retVal
    }
}

# ----------------------------------------------------------------------------------------------------------------
function get-workingDirectory()
{
    $retVal = [string]::Empty
    if (Test-Path variable:\hostinvocation)
    {
        $retVal = $hostinvocation.MyCommand.Path
    }
    else
    {
        $retVal = (get-variable myinvocation -scope script).Value.Mycommand.Definition
    }
  
    if (Test-Path $retVal)
    {
        $retVal = (Split-Path $retVal)
    }
    else
    {
        $retVal = (Get-Location).path
        write-host "get-workingDirectory: Powershell Host $($Host.name) may not be compatible with this function, the current directory $retVal will be used."
    } 
 
    Set-Location $retVal | out-null
    return $retVal
}

# ----------------------------------------------------------------------------------------------------------------
function get-update($updateUrl, $destinationFile)
{
    write-host "get-update:checking for updated script: $($updateUrl)"

    try 
    {
        $git = Invoke-RestMethod -Method Get -Uri $updateUrl 

        # git  may not have carriage return
        if ([regex]::Matches($git, "`r").Count -eq 0)
        {
            $git = [regex]::Replace($git, "`n", "`r`n")
        }

        if (![IO.File]::Exists($destinationFile))
        {
            $file = ""    
        }
        else
        {
            $file = [IO.File]::ReadAllText($destinationFile)
        }

        if (([string]::Compare($git, $file) -ne 0))
        {
            write-host "copying script $($destinationFile)"
            [IO.File]::WriteAllText($destinationFile, $git)
            return $true
        }
        else
        {
            write-host "script is up to date"
        }
        
        return $false
    }
    catch [System.Exception] 
    {
        write-host "get-update:exception: $($error)"
        $error.Clear()
        return $false    
    }
}

# ----------------------------------------------------------------------------------------------------------------
function is-deployment($items)
{
    $items = @($items)
    try
    {
        if($items.Count -gt 0 -and $items[0].EventTimeStamp -ne $null)
        {
            return $false
        }
        elseif($items.Count -gt 0 -and ($items[0].TimeStamp -ne $null -or $items[0].Properties.Timestamp -ne $null))
        {
            return $true
        }
    }
    catch
    {
        write-host "exception:is-deployment: $($error)"
        $error.Clear()
        return $null
    }
}      

# ----------------------------------------------------------------------------------------------------------------
function new-jobResults()
{
    $jobResults = @{}
    $jobResults.GroupOutput = @{} #New-Object Collections.ArrayList}
    $jobResults.DeploymentOutput = @{} #New-Object Collections.ArrayList}
    $jobResults.LastUpdateTime = $null
    $jobResults.LastResult = $null
    $jobResults.ResourceGroups = 0
    $jobResults.Deployments = 0

    return $jobResults
}

# ----------------------------------------------------------------------------------------------------------------
function open-event()
{
    if($detail)
    {
        write-host $global:listbox
    }

    [Windows.Input.Mouse]::SetCursor([Windows.Input.Cursors]::AppStarting)

    try
    {
        $ret = $global:listboxEvent.Items.Clear()
        $item = $global:listbox.SelectedItem.Tag
        [Windows.Controls.ScrollViewer]$lbi = new-object Windows.Controls.ScrollViewer
        $lbi.MaxHeight = $global:listboxEvent.ActualHeight - 10 
        $lbi.MinWidth = $global:listboxEvent.ActualWidth - 5

        if(is-deployment -items $item)
        {
            $jsonItem = $item | ConvertTo-Json -Depth 100
            $lbi.Content = format-record -inputString $jsonItem

            if(![string]::IsNullOrEmpty($item.DeploymentName))
            {
                $ops = (Get-AzureRmResourceGroupDeploymentOperation -DeploymentName $($item.DeploymentName) -ResourceGroupName $($item.ResourceGroupName))
            }
            else
            {
                $ops = $item
            }

            if(@($ops).Count -eq 1)
            {
                $height = $global:listboxEvent.ActualHeight
            }
            else
            {
                $height = $global:listboxEvent.ActualHeight / 2
            }

            foreach($op in $ops)
            {
                [Windows.Controls.ScrollViewer]$dlbi = new-object Windows.Controls.ScrollViewer
                $dlbi.MaxHeight = $height
                $dlbi.MinWidth = $global:listboxEvent.ActualWidth - 5
                
                $dlbi.Content = format-record -inputString ($op | convertto-json -depth 100)
                $ret = $global:listboxEvent.Items.Add((format-eventView -item $item -listBoxItem $dlbi))
            }
        }
        else
        {
            # remove noise
            $item.Authorization = $Null # "(removed)"
            $item.Claims = $null # "(removed)"
            $jsonItem = $item | convertto-json -Depth 100
            $lbi.Content = format-record -inputString $jsonItem 
            
            $ret = $global:listboxEvent.Items.Add((format-eventView -item $item -listBoxItem $lbi))
        }
    }
    catch
    {
        write-host "open-event:exception $($error)"
        $error.Clear()
    }
    finally
    {
        [Windows.Input.Mouse]::SetCursor([Windows.Input.Cursors]::Arrow)
    }
}

# ----------------------------------------------------------------------------------------------------------------
function receive-backgroundJob([bool]$once = $false)
{
    try
    {
        if($detail)
        {
            write-host "$([DateTime]::Now) receiving job"
        }

        $count = 0
        $job = $Null
        $jobResultsList = @{}
        $jobResults = new-jobResults
        $jobResults.LastUpdateTime = [DateTime]::MinValue
        $ret = @{}
        $totalCount = ($global:refreshTime.TotalSeconds * 2)

        if($once)
        {
            $totalCount = 1
        }

        while($count -le $totalCount)
        {
            $job = get-job -Name $global:jobName 
            $jobResultsList = receive-job -Job $job
            
            if($jobResultsList -ne $Null)
            {
                break
            }

            start-sleep -Milliseconds 100
            [void]$count++
        }
    
        if($count -ge $totalCount)
        {
            if(!$once)
            {
                write-host "error:receivebackgroundjob timed out" -ForegroundColor Red
            }

            return $false
        }

        if(@($jobResultsList).Count -gt 1)
        {
            Write-Warning "more than 1 job results returned. $(@($jobResultsList).Count)" 
            $jobResults = $jobResultsList[@($jobResultsList).Count -1]
        }
        else
        {
            $jobResults = $jobResultsList
        }

        # check pipeline # pipeline will always be $jobResults[0]
        if(![string]::IsNullOrEmpty($jobResults) -and ($jobResults.GetType().Name -ine "HashTable"))
        {
            write-host "job pipeline error: $($jobResults)" -ForegroundColor Yellow
        }

        # check error
        if(![string]::IsNullOrEmpty($jobResults.LastResult))
        {
            write-host "job last result: $($jobResults.LastResult)"
        
            if([regex]::IsMatch($jobResults.LastResult,"login\."))
            {
                write-host "job needs to be restarted: $($lastUpdateTime)"
                $null = start-backgroundJob
            }
        }
                
        if(![string]::IsNullOrEmpty($jobResults.LastUpdateTime))
        {
            $lastUpdateTime = [DateTime]::MinValue

            if([DateTime]::TryParse($jobResults.LastUpdateTime,[ref] $lastUpdateTime))
            {
                if([DateTime]::Now.Add(-($global:refreshTime)) -gt $lastUpdateTime)
                {
                    write-host "error in job, update time is stale: $($lastUpdateTime)"
                }
               
                $ret = $jobResults
                write-host "receive-job returning $(@($ret).Count) results" -ForegroundColor Green
            }
            else
            {
                write-host "error:job results lastupdatetime unable to parse $($jobResults.LastUpdateTime)"
            }
        }

        return $ret
    }
    catch
    {
        write-host "receive-background job exception $($error)"
        $error.Clear()
    }
}

# ----------------------------------------------------------------------------------------------------------------
function reset-list()
{
    $global:eventStartTime = ([DateTime]::Now).AddDays(-1)
    $global:deploymentUpdate = [DateTime]::MinValue
    $global:resourcegroupUpdate = [DateTime]::MinValue
    $global:deployments = @{}
    $global:groups = @{}

    run-commands 
    $refreshLabel.Content = [DateTime]::Now.ToLongTimeString()
}

# ----------------------------------------------------------------------------------------------------------------
function run-command($group, $items)
{
    try
    {
        if($detail)
        {
            write-host "$([DateTime]::Now) run-command  group: $($group.Key) items: $($items.Count)"
        }
        
        if(@($items).Count -lt 1 -and $group.Value -eq 0)
        {
            # remove from list
            $global:groups[$group.Key] = -1
            return
        }
        else
        {
            $global:groups[$group.Key] += @($items).Count
        }

        if(is-deployment -items $items)
        {
            $allItems = @{}

            foreach($item in $items)
            {
                [DateTime]$timeadjust = $item.TimeStamp

                while($allItems.ContainsKey($timeadjust.ToString("o")))
                {
                    $timeadjust = $timeadjust.AddTicks(1)
                }

                [void]$allItems.Add($timeadjust.ToString("o"), $item)

                if(!$global:deployments[$group.Key].ContainsKey($item.DeploymentName))
                {
                    [void]$global:deployments[$group.Key].Add($item.DeploymentName, 0)
                }

                if($global:deployments[$group.Key][$item.DeploymentName] -lt 0)
                {
                    continue
                }
                
                $ops = Get-AzureRmResourceGroupDeploymentOperation -DeploymentName $($item.DeploymentName) -ResourceGroupName $($group.Key)

                if(@($ops).count -lt 1 -and $global:deployments[$group.Key][$item.DeploymentName] -eq 0)
                {
                    $global:deployments[$group.Key][$item.DeploymentName] -eq -1
                    continue
                }
                else
                {
                    $global:deployments[$group.Key][$item.DeploymentName] += $ops.Count
                }

                foreach($op in $ops)
                {
                    [DateTime]$timeadjust = $op.Properties.TimeStamp

                    while($allItems.ContainsKey($timeadjust))
                    {
                        $timeadjust = $timeadjust.AddTicks(1)
                    }

                    [void]$allItems.Add($timeadjust, $op)
                }
            }    
            
            #foreach($sItem in $allItems.GetEnumerator())
            #{
            #    add-depitem -lbitem $sItem.Value -color "DarkOrange"
            #}  
            return $allItems.Values
        }
        else
        {
            #foreach($item in $items)
            #{
            #    add-eventItem -lbitem $item -color "Yellow"
            #}      
            return $items
        }
    }
    catch
    {
        write-host "Exception:run-command $($error | Format-List *)"
        #$error.Clear()
    }
}

# ----------------------------------------------------------------------------------------------------------------
function run-commands($jobObject = $null)
{
    $ret = $null

    # background job
    if($jobObject)
    {
        $jobResults = $jobObject
    }
    else
    {
        $jobResults = new-jobResults
        $jobResults.LastUpdateTime = [DateTime]::Now
    }

    try
    {
       # [Windows.Input.Mouse]::SetCursor([Windows.Input.Cursors]::AppStarting)
        
        $ret = enum-deployments
        $localTime = get-time -item $global:eventStartTime

        # use temp group so $global:groups can be modifed in run-command
        $tempGroups = @{}

        write-host "run-commands:group count: $($global:groups.Count) time: $($localTime)"

        foreach($tgroup in $global:groups.GetEnumerator())
        {
            if($tgroup.Value -ge 0)
            {
                [void]$tempGroups.Add($tgroup.Key,$tgroup.Value)
            }
        }

        foreach($group in $tempGroups.GetEnumerator())
        {
            if(!$group)
            {
                continue
            }

            write-host "run-commands:get-azsurermlog -detailedoutput -resourcegroup $($group.Key) -starttime $($localTime)"
            [void]$jobResults.GroupOutput.Add($group.key, 
                (run-command -group $group -items @(get-azurermlog -DetailedOutput -ResourceGroup $group.Key -StartTime $localTime)))
            #[void]$jobResults.GroupOutput.Add($group.key, 
            #    (new-object Collections.ArrayList (,@(get-azurermlog -DetailedOutput -ResourceGroup $group.Key -StartTime $localTime))))

            # todo: filter not working. timestamp in 2 locations
            [void]$jobResults.DeploymentOutput.Add($group.key, 
                (run-command -group $groupy -items @(Get-AzureRmResourceGroupDeployment -ResourceGroupName $group.Key | Where-Object TimeStamp -ge $localTime)))
            #[void]$jobResults.DeploymentOutput.Add($group.key, 
            #    (new-object Collections.ArrayList (,@(Get-AzureRmResourceGroupDeployment -ResourceGroupName $group.Key | Where-Object TimeStamp -ge $localTime))))
        }

        $jobResults.Deployments = $global:deployments
        $jobResults.ResourceGroups = $tempGroups
        return $jobResults    
    }
    catch
    {
        write-host "run-commands:exception:$($error)"
        $error.clear()
    }
    finally
    {
        #[Windows.Input.Mouse]::SetCursor([Windows.Input.Cursors]::Arrow)
    }
}



#-------------------------------------------------------------------
function start-backgroundJob()
{
    write-host "starting background job"

    # add values here to pass to jobs
    $jobInfo = @{}
    $jobInfo.action = "rpc job"
    $jobInfo.jobName = $global:jobname
    $jobInfo.invocation = $MyInvocation
    $JobInfo.backgroundJobFunction = (get-item function:do-backgroundJob)
    $jobInfo.profileContext = $profileContext
    $jobInfo.detail = $detail
    $jobInfo.verbosePreference = $VerbosePreference
    $jobInfo.debugPreference = $DebugPreference
    $jobInfo.result = $null
    $jobInfo.eventStartTime = $global:eventStartTime

    try
    {
        if(get-job $global:jobname -ErrorAction SilentlyContinue)
        {
            write-host "removing old job $($global:jobname)"
            remove-job -Name $global:jobname -Force
        } 

        $job = Start-Job -ScriptBlock `
        { 
            param($jobInfo)
            . $($jobInfo.invocation.scriptname)
            & $jobInfo.backgroundJobFunction $jobInfo

        } -Name $jobInfo.jobName -ArgumentList $jobInfo

        if($DebugPreference -ine "SilentlyContinue")
        {
            ### debug job
            Start-Sleep -Seconds 5
            debug-job -Job $job
            pause
        }

        return $job
    }
    catch
    {
        write-host "start-backgroundjob: exception: $($error)"
        exit 1
        $error.Clear()
    }
}


# ----------------------------------------------------------------------------------------------------------------
if ($host.Name -ine "ServerRemoteHost")
{
    main
}

