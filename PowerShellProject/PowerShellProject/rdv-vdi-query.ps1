<#
.SYNOPSIS  
    powershell script to rds deployment for virtualization hosts and vdi machines
    

.DESCRIPTION  
    powershell script to rds deployment for virtualization hosts and vdi machines
    machines that are running will be queried for rdp port, process list, qwinsta, network and share connectivity

.NOTES  
   Author     : jagilber
   Version    : 161208.1 original
   History    : 

.EXAMPLE  
    .\rdv-vdi-query.ps1
    query for connection broker and run script

.EXAMPLE  
    .\rdv-vdi-query.ps1 -activeBroker broker01
    query specific connection broker and run script
 
.PARAMETER activeBroker
    optional parameter to specify active connection broker
#>

param(
[Parameter(Mandatory=$false)]
[string]$activeBroker,
[string]$sessionHostsFile,
[string]$virtualizationHostsFile,
[string]$desktopsFile,
[switch]$update
)

Set-StrictMode -Version "latest"
$desktops = @{}
$virtualizationHosts = @{}
$sessionHosts = @{}
$outFile = "rdv-vdi-query.txt"
$error.clear()
$updateUrl = "https://raw.githubusercontent.com/jagilber/powershellScripts/master/PowerShellProject/PowerShellProject/rdv-vdi-query.ps1"

#----------------------------------------------------------------------------
function main()
{
    Start-Transcript -Path $outFile -Append
    write-host "----------------------------------------"
    write-host "$(get-date) starting"
    
    get-workingDirectory

    if($update)
    {
        if(git-update -updateUrl $updateUrl -destinationFile $MyInvocation.ScriptName)
        {
            write-host "script updated. restart"
            return
        }
    }


    if([string]::IsNullOrEmpty($activeBroker))
    {
        if(($availability = Get-RDConnectionBrokerHighAvailability))
        {
            $activeBroker = $availability.ActiveManagementServer
        }

        if([string]::IsNullOrEmpty($activeBroker))
        {
            if((Get-RDServer).roles -eq "RDS-CONNECTION-BROKER") 
            {
                $activeBroker = (Get-RDServer | ? Roles -eq "RDS-CONNECTION-BROKER").Server
            }
            else
            {
                write-host "pass active connection broker name as argument for script. returning"
                return
            }
        }
    }

    write-host "$(get-date) using active broker: $($activeBroker)"
    $desktopCollections = Get-RDVirtualDesktopCollection -ConnectionBroker $activeBroker
    $sessionCollections = Get-RDSessionCollection -ConnectionBroker $activeBroker

    write-host "$(get-date) checking virtualization"
    if(![string]::IsNullOrEmpty($virtualizationHostsFile))
    {
        # read from file
        foreach($virtualizationhost in (Get-Content -Raw $virtualizationHostsFile))
        {
            if(!$virtualizationHosts.ContainsKey($virtualizationHost))
            {
                write-host "adding virtualization host from file $($virtualizationHost)"
                $virtualizationHosts.Add($virtualizationHost,@{})
            }
        }
    }
    else
    {
        # query deployment
        foreach($desktopCollection in $desktopCollections)
        {
            foreach($virtualizationHost in (Get-RDVirtualDesktop -CollectionName $desktopCollection.CollectionName -ConnectionBroker $activeBroker).HostName)
            {
                if(!$virtualizationHosts.ContainsKey($virtualizationHost))
                {
                    write-host "adding virtualization host $($virtualizationHost)"
                    $virtualizationHosts.Add($virtualizationHost,@{})
                }
            }
        }
    }

    write-host "$(get-date) checking session"
    if(![string]::IsNullOrEmpty($sessionHostsFile))
    {
        foreach($sessionHost  in (Get-Content -Raw $sessionHostsFile))
        {
            if(!$sessionHosts.ContainsKey($sessionHost))
            {
                write-host "adding session host from file $($sessionHost)"
                $sessionHosts.Add($sessionHost,@{})
            }
        }
    }
    else
    {
        foreach($sessionCollection in $sessionCollections)
        {
            foreach($sessionHost in (Get-RDSessionHost -CollectionName $sessionCollection.CollectionName -ConnectionBroker $activeBroker).SessionHost)
            {
                if(!$sessionHosts.ContainsKey($sessionHost))
                {
                    write-host "adding session host $($sessionHost)"
                    $sessionHosts.Add($sessionHost,@{})
                }
            }
        }
    }

    write-host "$(get-date) checking desktop"
    if(![string]::IsNullOrEmpty($desktopsFile))
    {
        foreach($desktop  in (Get-Content -Raw $desktopsFile))
        {
            if(!$desktops.ContainsKey($desktop))
            {
                write-host "adding desktop from file $($desktop)"
                $desktops.Add($desktop,@{})
            }
        }
    }
    else
    {
        foreach($desktopCollection in $desktopCollections)
        {
            foreach($desktop in (Get-RDVirtualDesktop -CollectionName $desktopCollection.CollectionName -ConnectionBroker $activeBroker).VirtualDesktopName)
            {
                if(!$desktops.ContainsKey($desktop))
                {
                    write-host "adding desktop $($desktop)"
                    $desktops.Add($desktop,@{})
                }
            }
        }
    }

    write-host "$(get-date) querying virtualization hosts"
    foreach($vhost in $virtualizationHosts.GetEnumerator())
    {
        $vhost.Value.Available = (Test-NetConnection -ComputerName $vhost.Name -Port 135).TcpTestSucceeded
        if($vhost.Value.Available)
        {
            $vhost.Value.Vms = get-vm -ComputerName $vhost.Name
        }
        else
        {
            write-host "error: vhost not available $($vhost.Name)" -ForegroundColor Red
        }
    }

    write-host "$(get-date) querying desktops"
    foreach($desktop in $desktops.GetEnumerator())
    {
        # check hyper-v list
        $vhostDesktop = $virtualizationHosts.Values.Vms | ? Name -imatch $desktop.Name

        #

        if(@($vhostDesktop).Count -gt 1)
        {
            write-host "error: more that one desktop found in virtualization hosts list $($desktop.Name). skipping." -ForegroundColor Red
        }
        elseif(@($vhostDesktop).Count -lt 1)
        {
            write-host "error: desktop not not found in virtualization hosts list $($desktop.Name). skipping." -ForegroundColor Red
            continue
        }

        write-host "desktop found in virtualization hosts list $($desktop.Name)" -ForegroundColor Green
        $vhostDesktop
        
        if($vhostDesktop.State -imatch "Running")
        {
            $desktop.Value.Available = (Test-NetConnection -ComputerName $desktop.Name -Port 135).TcpTestSucceeded
        
            
            if($desktop.Value.Available)
            {
                #$vhost.Value.Vms = get-vm -ComputerName $vhost.Name
            }
            else
            {
                # requery?
                write-host "error: desktop not available $($desktop.Name)" -ForegroundColor Red
            }

            $desktop.Value.RDPAvailable = (Test-NetConnection -ComputerName $desktop.Name -Port 3389).TcpTestSucceeded
            if($desktop.Value.RDPAvailable)
            {
                #$vhost.Value.Vms = get-vm -ComputerName $vhost.Name
            }
            else
            {
                # requery?
                write-host "error: desktop RDP not available $($desktop.Name)" -ForegroundColor Red
            }

            $desktop.Value.QwinstaResultsError = $null
            $desktop.Value.QWinstaResults = Invoke-expression "qwinsta.exe /server:$($desktop.Name) /VM"
            if($desktop.Value.QWinstaResults)
            {
                #$vhost.Value.Vms = get-vm -ComputerName $vhost.Name
            }
            else
            {
                # requery?
                $desktop.Value.QwinstaResultsError = $error
                $error.Clear()
                write-host "error: desktop qwinsta not available $($desktop.Name)" -ForegroundColor Red
            }

            $desktop.Value.ShareResultsError = $null
            $desktop.Value.ShareResults = test-path "\\$($desktop.Name)\admin$"
            if($desktop.Value.ShareResults)
            {
                #$vhost.Value.Vms = get-vm -ComputerName $vhost.Name
            }
            else
            {
                # requery?
                $desktop.Value.ShareResultsError = $error
                $error.Clear()
                write-host "error: desktop share not available $($desktop.Name)" -ForegroundColor Red
            }

            $desktop.Value.ProcessResultsError = $null
            $desktop.Value.ProcessResults = Invoke-expression "tasklist /s $($desktop.Name) /v"
            if($desktop.Value.ProcessResults)
            {
                #$vhost.Value.Vms = get-vm -ComputerName $vhost.Name
            }
            else
            {
                # requery?
                $desktop.Value.ShareResultsError = $error
                $error.Clear()
                write-host "error: desktop share not available $($desktop.Name)" -ForegroundColor Red
            }
        }
        else
        {
            # requery?
            write-host "warning:desktop state is not running $($desktop.Name). current state: $($vhostDesktop.State)" -ForegroundColor Yellow
        }
    }


    write-host "$(get-date) exporting data"
    $sessionHosts | ConvertTo-Json -Depth 3 | out-file ("$($outFile).sessionhosts.txt")
    $virtualizationHosts | ConvertTo-Json -Depth 3 | out-file ("$($outFile).virtualizationhosts.txt")
    $desktops | ConvertTo-Json -Depth 3 | out-file ("$($outFile).desktops.txt")
    
    Stop-Transcript
    write-host "log is here:$($outFile)"
    write-host "$(get-date) finished"
    write-host "----------------------------------------"

}

#----------------------------------------------------------------------------
function git-update($updateUrl, $destinationFile)
{
    log-info "get-update:checking for updated script: $($updateUrl)"

    try 
    {
        $git = Invoke-RestMethod -Method Get -Uri $updateUrl 
        $gitClean = [regex]::Replace($git, '\W+', "")

        if(![IO.File]::Exists($destinationFile))
        {
            $fileClean = ""    
        }
        else
        {
            $fileClean = [regex]::Replace(([IO.File]::ReadAllBytes($destinationFile)), '\W+', "")
        }

        if(([string]::Compare($gitClean, $fileClean) -ne 0))
        {
            log-info "copying script $($destinationFile)"
            [IO.File]::WriteAllText($destinationFile, $git)
            return $true
        }
        else
        {
            log-info "script is up to date"
        }
        
        return $false
        
    }
    catch [System.Exception] 
    {
        log-info "get-update:exception: $($error)"
        $error.Clear()
        return $false    
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
        log-info "get-workingDirectory: Powershell Host $($Host.name) may not be compatible with this function, the current directory $retVal will be used."
        
    } 
 
    Set-Location $retVal | out-null
    return $retVal
}

#----------------------------------------------------------------------------
main