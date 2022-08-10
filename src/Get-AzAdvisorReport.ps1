#requires -version 5.1
#requires -RunAsAdministrator
#requires -Module Az, AzAPICall

# For TLS 1.2, we need to use the TLS 1.2 ciphersuite list.
Using Namespace System.Net
Using Namespace System.Runtime.InteropServices

<#
.SYNOPSIS
Provides an Azure Advisor cost recommendation report 

.DESCRIPTION
This script will generate a cost recommendation report for the specified management group.

PRE-REQUISITES:

1. If you already have the Az modules installed, you may still encounter the following error:
    The script 'Deploy-AzureResourceGroup.ps1' cannot be run because the following modules that are specified by the "#requires" statements of the script are missing: Az.
    At line:0 char:0
To resolve, please run the following command to import the Az modules into your current session.
Import-Module -Name Az -Verbose

2. Before executing this script, ensure that you change the directory to the directory where the script is located. For example, if the script is in: c:\<directory-path>\Get-AzAdvisorCostReport.ps1 
(where #.#.# represents the verion) then change to this directory using the following command:
Set-Location -Path C:\<directory-path>

3. AzAPICall Powershell Module is required! https://www.powershellgallery.com/packages/AzAPICall 

.PARAMETER ManagementGroupId
The management group id to generate the cost recommendation report for.

.PARAMETER SubscriptionBatchSize
The number of subscriptions to process in a batch.

.PARAMETER PSModuleRepository
The path to the PowerShell module repository.

.PARAMETER TargetModules
The modules to install in the target session.

.PARAMETER Title
The title of the report.

.EXAMPLE
Get the cost recommendation report for the management group 'management-group-id'
.\Get-AzAdvisorReport.ps1 -ManagementGroupId <management-group-id> -Verbose

.INPUTS
None

.OUTPUTS
The outputs generated from this script includes:
1. A transcript log file to provide the full details of script execution. It will use the name format: Get-AzAdvisorReport-TRANSCRIPT-<Date-Time>.log

.NOTES

CONTRIBUTORS
1. Julian Haward (Original Author)
2. Preston K. Parsard

LEGAL DISCLAIMER:
This Sample Code is provided for the purpose of illustration only and is not intended to be used in a production environment. 
THIS SAMPLE CODE AND ANY RELATED INFORMATION ARE PROVIDED "AS IS" WITHOUT WARRANTY OF ANY KIND, EITHER EXPRESSED OR IMPLIED,
INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE. 
We grant You a nonexclusive, royalty-free right to use and modify the Sample Code and to reproduce and distribute the object code form of the Sample Code, provided that You agree:
(i) to not use Our name, logo, or trademarks to market Your software product in which the Sample Code is embedded;
(ii) to include a valid copyright notice on Your software product in which the Sample Code is embedded; and
(iii) to indemnify, hold harmless, and defend Us and Our suppliers from and against any claims or lawsuits, including attorneys' fees, that arise or result from the use or distribution of the Sample Code.
This posting is provided "AS IS" with no warranties, and confers no rights.

.LINK


.COMPONENT
Azure Infrastructure, PowerShell, Azure Graph Explorer, Azure Advisor, Cost Recommendation

.ROLE
Automation Engineer
DevOps Engineer
Azure Engineer
Azure Administrator
Azure Architect

.FUNCTIONALITY
Generates and Azure Advisor cost recommendation report for the specified management group.

#>

<#
TASK-ITEMS:
VERSION STATUS  DESCRIPTION
#>

<#
AzAPICall Powershell Module is required! https://www.powershellgallery.com/packages/AzAPICall
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory = $True)]
    [string]$ManagementGroupId, #the Id, not the displayName
    [int]$SubscriptionBatchSize = 1000, #max 1000
    [string]$PSModuleRepository = "PSGallery", # Onlinie source for obtaining the AzAPICall module
    [string[]]$TargetModules = @("AzAPICall","Az"), # The name of the modules to be downloaded and installed
    [string]$Title = "AZURE ADVISOR CUSTOM COST REPORT:", # The title of the report
    [int]$separatorWidth = 100, # The width of the separator line
    [string]$doubleSeparator = ("-"*$separatorWidth), # The separator used to separate the title from the report
    [string]$singleSeparator = ("-"*$separatorWidth) # The separator used to separate the report sections
) # end param

function New-TranscriptLog
{
    [CmdletBinding()]
    [OutputType([string[]])]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LogDirectory,

        [Parameter(Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        [string]$LogPrefix
    ) # end param

    # Get curent date and time
    $TimeStamp = (get-date -format u).Substring(0, 16)
    $TimeStamp = $TimeStamp.Replace(" ", "-")
    $TimeStamp = $TimeStamp.Replace(":", "")
    $Script:TimeStamp = $TimeStamp

    # Construct transcript file full path
    $TranscriptFile = "$LogPrefix-TRANSCRIPT" + "-" + $TimeStamp + ".log"
    $script:Transcript = Join-Path -Path $LogDirectory -ChildPath $TranscriptFile

    # Create log and transcript files
    New-Item -Path $Transcript -ItemType File -Verbose 
} # end function

function Set-TlsSecurityProtocolType
{
    [CmdletBinding()]
    param()
# Use TLS 1.2 to support Nuget provider
Write-Host "Configuring security protocol to use TLS 1.2 for Nuget support when installing modules." -Verbose
[ServicePointManager]::SecurityProtocol = [SecurityProtocolType]::Tls12
}
function Get-RequiredModule
{
    [CmdletBinding(DefaultParameterSetName = "Get-RequiredModule")]
    param
    (
        [string[]]$TargetModules,
        [string]$PSModuleRepository
    ) # end param
    # Module repository setup and configuration
    Set-PSRepository -Name $PSModuleRepository -InstallationPolicy Trusted -Verbose
    Install-PackageProvider -Name Nuget -ForceBootstrap -Force

    foreach ($TargetModule in $TargetModules)
    { 
        # Bootstrap dependent module
        if (Get-InstalledModule -Name $TargetModule -ErrorAction SilentlyContinue)
        {
            # If module exists, update it
            [string]$currentVersionADM = (Find-Module -Name $TargetModule -Repository $PSModuleRepository).Version
            [string]$installedVersionADM = (Get-InstalledModule -Name $TargetModule).Version
            If ($currentVersionADM -ne $installedVersionADM)
            {
                # Update modules if required
                Update-Module -Name $TargetModule -Force -ErrorAction SilentlyContinue -Verbose
            } # end if
        } # end if
        # If the modules aren't already loaded, install and import it.
        else
        {
            Install-Module -Name $TargetModule -Repository $PSModuleRepository -Force -Verbose
        } #end If
        Import-Module -Name $TargetModule -Verbose
    } #end foreach
} #end Get-RequiredModule
function getEntities
{
    Write-Host 'Entities'
    $startEntities = Get-Date
    $currentTask = ' Getting Entities'
    Write-Host $currentTask
    #https://management.azure.com/providers/Microsoft.Management/getEntities?api-version=2020-02-01
    $uri = "$($azAPICallConf['azAPIEndpointUrls'].ARM)/providers/Microsoft.Management/getEntities?api-version=2020-02-01"
    $method = 'POST'
    $script:arrayEntitiesFromAPI = AzAPICall -AzAPICallConfiguration $azAPICallConf -uri $uri -method $method -currentTask $currentTask

    Write-Host "  $($arrayEntitiesFromAPI.Count) Entities returned"

    $endEntities = Get-Date
    Write-Host " Getting Entities duration: $((NEW-TIMESPAN -Start $startEntities -End $endEntities).TotalSeconds) seconds"

    $startEntitiesdata = Get-Date
    Write-Host ' Processing Entities data'
    $script:htSubscriptionsMgPath = @{}
    $script:htManagementGroupsMgPath = @{}
    $script:htEntities = @{}
    $script:htEntitiesPlain = @{}

    foreach ($entity in $arrayEntitiesFromAPI)
    {
        $script:htEntitiesPlain.($entity.Name) = @{}
        $script:htEntitiesPlain.($entity.Name) = $entity
    }

    foreach ($entity in $arrayEntitiesFromAPI)
    {
        if ($entity.Type -eq '/subscriptions')
        {
            $script:htSubscriptionsMgPath.($entity.name) = @{}
            $script:htSubscriptionsMgPath.($entity.name).ParentNameChain = $entity.properties.parentNameChain
            $script:htSubscriptionsMgPath.($entity.name).ParentNameChainDelimited = $entity.properties.parentNameChain -join '/'
            $script:htSubscriptionsMgPath.($entity.name).Parent = $entity.properties.parent.Id -replace '.*/'
            $script:htSubscriptionsMgPath.($entity.name).ParentName = $htEntitiesPlain.($entity.properties.parent.Id -replace '.*/').properties.displayName
            $script:htSubscriptionsMgPath.($entity.name).DisplayName = $entity.properties.displayName
            $array = $entity.properties.parentNameChain
            $array += $entity.name
            $script:htSubscriptionsMgPath.($entity.name).path = $array
            $script:htSubscriptionsMgPath.($entity.name).pathDelimited = $array -join '/'
            $script:htSubscriptionsMgPath.($entity.name).level = (($entity.properties.parentNameChain).Count - 1)
        }
        if ($entity.Type -eq 'Microsoft.Management/managementGroups')
        {
            if ([string]::IsNullOrEmpty($entity.properties.parent.Id))
            {
                $parent = '__TenantRoot__'
            }
            else
            {
                $parent = $entity.properties.parent.Id -replace '.*/'
            }
            $script:htManagementGroupsMgPath.($entity.name) = @{}
            $script:htManagementGroupsMgPath.($entity.name).ParentNameChain = $entity.properties.parentNameChain
            $script:htManagementGroupsMgPath.($entity.name).ParentNameChainDelimited = $entity.properties.parentNameChain -join '/'
            $script:htManagementGroupsMgPath.($entity.name).ParentNameChainCount = ($entity.properties.parentNameChain | Measure-Object).Count
            $script:htManagementGroupsMgPath.($entity.name).Parent = $parent
            $script:htManagementGroupsMgPath.($entity.name).ChildMgsAll = ($arrayEntitiesFromAPI.where( { $_.Type -eq 'Microsoft.Management/managementGroups' -and $_.properties.ParentNameChain -contains $entity.name } )).Name
            $script:htManagementGroupsMgPath.($entity.name).ChildMgsDirect = ($arrayEntitiesFromAPI.where( { $_.Type -eq 'Microsoft.Management/managementGroups' -and $_.properties.Parent.Id -replace '.*/' -eq $entity.name } )).Name
            $script:htManagementGroupsMgPath.($entity.name).DisplayName = $entity.properties.displayName
            $script:htManagementGroupsMgPath.($entity.name).Id = ($entity.name)
            $array = $entity.properties.parentNameChain
            $array += $entity.name
            $script:htManagementGroupsMgPath.($entity.name).path = $array
            $script:htManagementGroupsMgPath.($entity.name).pathDelimited = $array -join '/'
        }

        $script:htEntities.($entity.name) = @{}
        $script:htEntities.($entity.name).ParentNameChain = $entity.properties.parentNameChain
        $script:htEntities.($entity.name).Parent = $parent
        if ($parent -eq '__TenantRoot__')
        {
            $parentDisplayName = '__TenantRoot__'
        }
        else
        {
            $parentDisplayName = $htEntitiesPlain.($htEntities.($entity.name).Parent).properties.displayName
        }
        $script:htEntities.($entity.name).ParentDisplayName = $parentDisplayName
        $script:htEntities.($entity.name).DisplayName = $entity.properties.displayName
        $script:htEntities.($entity.name).Id = $entity.Name
    }

    Write-Host "  $(($htManagementGroupsMgPath.Keys).Count) Management Groups returned"
    Write-Host "  $(($htSubscriptionsMgPath.Keys).Count) Subscriptions returned"

    $endEntitiesdata = Get-Date
    Write-Host " Processing Entities data duration: $((NEW-TIMESPAN -Start $startEntitiesdata -End $endEntitiesdata).TotalSeconds) seconds"

    if (-not $htManagementGroupsMgPath.($ManagementGroupId))
    {
        Write-Host "ManagementGroupId '$ManagementGroupId' could not be found" -ForegroundColor DarkRed
        throw
    }

    $script:arrayEntitiesFromAPISubscriptionsCount = ($arrayEntitiesFromAPI.where( { $_.type -eq '/subscriptions' -and $_.properties.parentNameChain -contains $ManagementGroupId } ) | Sort-Object -Property id -Unique).count
    $script:arrayEntitiesFromAPIManagementGroupsCount = ($arrayEntitiesFromAPI.where( { $_.type -eq 'Microsoft.Management/managementGroups' -and $_.properties.parentNameChain -contains $ManagementGroupId } )  | Sort-Object -Property id -Unique).count + 1

    $endEntities = Get-Date
    Write-Host "Processing Entities duration: $((NEW-TIMESPAN -Start $startEntities -End $endEntities).TotalSeconds) seconds"
}
function getSubscriptions
{
    $startGetSubscriptions = Get-Date
    $currentTask = 'Getting all Subscriptions'
    Write-Host "$currentTask"
    $uri = "$($azAPICallConf['azAPIEndpointUrls'].ARM)/subscriptions?api-version=2020-01-01"
    $method = 'GET'
    $requestAllSubscriptionsAPI = AzAPICall -AzAPICallConfiguration $azAPICallConf -uri $uri -method $method -currentTask $currentTask

    Write-Host " $($requestAllSubscriptionsAPI.Count) Subscriptions returned"
    $script:htAllSubscriptionsFromAPI = @{}
    foreach ($subscription in $requestAllSubscriptionsAPI)
    {
        $script:htAllSubscriptionsFromAPI.($subscription.subscriptionId) = @{}
        $script:htAllSubscriptionsFromAPI.($subscription.subscriptionId).subDetails = $subscription
    }

    $endGetSubscriptions = Get-Date
    Write-Host "Getting all Subscriptions duration: $((NEW-TIMESPAN -Start $startGetSubscriptions -End $endGetSubscriptions).TotalSeconds) seconds"
}

function getInScopeSubscriptions
{
    $childrenSubscriptions = $arrayEntitiesFromAPI.where( { $_.properties.parentNameChain -contains $ManagementGroupID -and $_.type -eq '/subscriptions' } ) | Sort-Object -Property id -Unique
    
    if (($childrenSubscriptions).Count -eq 0)
    {
        Write-Host "ManagementGroupId: $ManagementGroupId has $(($childrenSubscriptions).Count) child subscriptions" -ForegroundColor DarkRed
        throw
    }
    else
    {
        Write-Host "ManagementGroupId: $ManagementGroupId has $(($childrenSubscriptions).Count) child subscriptions"
    }
    
    $script:subsToProcessInCustomDataCollection = [System.Collections.ArrayList]@()
    $script:outOfScopeSubscriptions = [System.Collections.ArrayList]@()
    foreach ($childrenSubscription in $childrenSubscriptions)
    {
    
        $sub = $htAllSubscriptionsFromAPI.($childrenSubscription.name)
        if ($sub.subDetails.subscriptionPolicies.quotaId.startswith('AAD_', 'CurrentCultureIgnoreCase') -or $sub.subDetails.state -ne 'Enabled')
        {
            if (($sub.subDetails.subscriptionPolicies.quotaId).startswith('AAD_', 'CurrentCultureIgnoreCase'))
            {
                $null = $script:outOfScopeSubscriptions.Add([PSCustomObject]@{
                        subscriptionId      = $childrenSubscription.name
                        subscriptionName    = $childrenSubscription.properties.displayName
                        outOfScopeReason    = "QuotaId: AAD_ (State: $($sub.subDetails.state))"
                        ManagementGroupId   = $htSubscriptionsMgPath.($childrenSubscription.name).Parent
                        ManagementGroupName = $htSubscriptionsMgPath.($childrenSubscription.name).ParentName
                        Level               = $htSubscriptionsMgPath.($childrenSubscription.name).level
                    })
            }
            if ($sub.subDetails.state -ne 'Enabled')
            {
                $null = $script:outOfScopeSubscriptions.Add([PSCustomObject]@{
                        subscriptionId      = $childrenSubscription.name
                        subscriptionName    = $childrenSubscription.properties.displayName
                        outOfScopeReason    = "State: $($sub.subDetails.state)"
                        ManagementGroupId   = $htSubscriptionsMgPath.($childrenSubscription.name).Parent
                        ManagementGroupName = $htSubscriptionsMgPath.($childrenSubscription.name).ParentName
                        Level               = $htSubscriptionsMgPath.($childrenSubscription.name).level
                    })
            }
        }
        else
        {
    
            $null = $script:subsToProcessInCustomDataCollection.Add([PSCustomObject]@{
                    subscriptionId      = $childrenSubscription.name
                    subscriptionName    = $childrenSubscription.properties.displayName
                    subscriptionQuotaId = $sub.subDetails.subscriptionPolicies.quotaId
                })
        }
    }

    if (($subsToProcessInCustomDataCollection).Count -eq 0)
    {
        Write-Host "ManagementGroupId: $ManagementGroupId has no valid child subscriptions (check `$outOfScopeSubscriptions)" -ForegroundColor DarkRed
        throw
    }
    else
    {
        Write-Host "ManagementGroupId: $ManagementGroupId has $(($subsToProcessInCustomDataCollection).Count) valid child subscriptions (check `$outOfScopeSubscriptions)"
    }
}

Set-TlsSecurityProtocolType -Verbose

# Obtain the AzApiCall module from the AzurePowerShell module gallery
Get-RequiredModule -TargetModule $TargetModules -PSModuleRepository $PSModuleRepository -Verbose

#region TRANSCRIPT
# Create Log file
[string]$Transcript = $null
$scriptName = $MyInvocation.MyCommand.name
# Use script filename without exension as a log prefix
$LogPrefix = $scriptName.Split(".")[0]
$logPath = $HOME
$LogDirectory = Join-Path $logPath -ChildPath $LogPrefix -Verbose
# Create log directory if not already present
If (-not(Test-Path -Path $LogDirectory -ErrorAction SilentlyContinue))
{
    New-Item -Path $LogDirectory -ItemType Directory -Verbose
} # end if

# funciton: Create log files for transcript
New-TranscriptLog -LogDirectory $LogDirectory -LogPrefix $LogPrefix -Verbose

Start-Transcript -Path $Transcript -IncludeInvocationHeader -Verbose
#endregion TRANSCRIPT

#region Authenticate to Azure
Write-Host "Please see the open dialogue box in your browser to authenticate to your Azure subscription..."

# Clear any possible cached credentials for other subscriptions, but only if not running in cloud shell
if (-not($CloudEnvironmentMap))
{
    Clear-AzContext
    Connect-AzAccount -Environment AzureCloud 
} # end if

# https://docs.microsoft.com/en-us/azure/azure-government/documentation-government-get-started-connect-with-ps
# To connect to AzureUSGovernment, use:
# Connect-AzAccount -EnvironmentName AzureUSGovernment
Do
{
    # TASK-ITEM: List subscriptions
    (Get-AzSubscription).Name
	[string]$Subscription = Read-Host "Please enter your subscription name, i.e. [MySubscriptionName] "
	$Subscription = $Subscription.ToUpper()
} #end Do
Until ($Subscription -in (Get-AzSubscription).Name)
Select-AzSubscription -SubscriptionName $Subscription -Verbose
#endregion Authenticate to Azure

try
{
    $azAPICallConf = initAzAPICall #-DebugAzAPICall $True
}
catch
{
    Write-Host "Install AzAPICall Powershell Module https://www.powershellgallery.com/packages/AzAPICall" -ForegroundColor DarkRed
    Write-Host "Install-Module -Name AzAPICall" -ForegroundColor Yellow
    throw
}

$header = "$Title $(Get-Date)"

Write-Host $doubleSeparator -ForegroundColor DarkYellow
Write-Host $header
Write-Host $singleSeparator -ForegroundColor DarkYellow

getEntities
getSubscriptions
getInScopeSubscriptions

#| where tostring(properties.category) has "Cost"
$query = @"
AdvisorResources 
| where (type == 'microsoft.advisor/recommendations')
| extend Impact = properties.impact
| extend resourceType = properties.impactedField
| extend ResourceName = properties.impactedValue
| extend Type = properties['extendedProperties']['resourceType']
| extend savingsAmount = properties['extendedProperties']['savingsAmount']
| extend annualSavingsAmount = properties['extendedProperties']['annualSavingsAmount']
| extend currentSku = properties['extendedProperties']['currentSku']
| extend targetSku = properties['extendedProperties']['targetSku']
| extend displayName = properties['managementGroupAncestorsChain'][0]['displayName']['0']
| extend tagName = tostring(properties.tags)
| extend Metadata = properties.resourceMetadata
| extend Problem = properties.shortDescription.problem
| extend Solution = properties.shortDescription.solution
| extend roleName = properties['extendedProperties']['roleName']
| extend percentSavings = properties['extendedProperties']['percentSavings']
| extend Currency = tostring(properties.extendedProperties.savingsCurrency)
| extend Link = strcat('https://portal.azure.com/#blade/Microsoft_Azure_Expert/RecommendationListBlade/recommendationTypeId/', tostring(properties.recommendationTypeId))
| project AffectedResource=tostring(properties.resourceMetadata.resourceId),Impact=properties.impact,resourceGroup,Metadata=properties.resourceMetadata,savingsAmount,annualSavingsAmount,percentSavings=properties.extendedProperties,Currency,currentSku,targetSku,roleName,subscriptionId,Recommendation=tostring(properties.shortDescription.problem), Link, tags, location
"@

$arrayAdvisorResults = [System.Collections.ArrayList]@()

$counterBatch = [PSCustomObject] @{ Value = 0 }
$subscriptionsBatch = $subsToProcessInCustomDataCollection | Group-Object -Property { [math]::Floor($counterBatch.Value++ / $SubscriptionBatchSize) }
$subscriptionsBatchCount = ($subscriptionsBatch | Measure-Object).Count
$uri = "$($azAPICallConf['azAPIEndpointUrls'].ARM)/providers/Microsoft.ResourceGraph/resources?api-version=2021-03-01"
$method = "POST"
$cnt = 0
foreach ($batch in $subscriptionsBatch)
{ 
    $cnt++
    Write-Host " Batch #$($cnt)/$subscriptionsBatchCount - Executing query for $($batch.Group.subscriptionId.Count) Subscriptions"
    $subscriptions = '"{0}"' -f ($batch.Group.subscriptionId -join '","')
    $body = @"
{
"query": "$($query)",
"subscriptions": [$($subscriptions)]
}
"@

    $res = (AzAPICall -AzAPICallConfiguration $azAPICallConf -uri $uri -method $method -body $body -listenOn 'Content' -currentTask "Advisor query")
    if ($res.count -gt 0)
    {
        foreach ($resource in $res)
        {
            $mgInfo = $htSubscriptionsMgPath.($resource.subscriptionId)
            $resource | Add-Member -MemberType NoteProperty -Name 'ManagementGroupId' -Value $mgInfo.Parent
            $resource | Add-Member -MemberType NoteProperty -Name 'ManagementGroupPath' -Value $mgInfo.ParentNameChainDelimited
            $resource | Add-Member -MemberType NoteProperty -Name 'SubscriptionName' -Value $mgInfo.DisplayName
            $null = $arrayAdvisorResults.Add($resource)
        }
    }
    Write-Host "  $($res.count) advisories found"
}

#the results are here: $arrayAdvisorResults
$advisorResultsFileName = "advisorResults.csv"

$advisorResultsPath = Join-Path $LogDirectory -ChildPath $advisorResultsFileName 

Write-Host $doubleSeparator
Write-Host "Array Advisor Results:"
Write-Host $doubleSeparator
Write-Host $singleSeparator
$arrayAdvisorResults
$arrayAdvisorResults | Export-Csv -Path $advisorResultsPath -NoTypeInformation
Write-Host $singleSeparator
Write-Host "End of Report"
Write-Host $singleSeparator

Stop-Transcript -Verbose

# Create prompt and response objects for continuing script and opening logs.
$openTranscriptPrompt = "Would you like to open the transcript and results now ? [YES/NO]"
Do
{
    $openTranscriptResponse = read-host $openTranscriptPrompt
    $openTranscriptResponse = $openTranscriptResponse.ToUpper()
} # end do
Until ($openTranscriptResponse -eq "Y" -OR $openTranscriptResponse -eq "YES" -OR $openTranscriptResponse -eq "N" -OR $openTranscriptResponse -eq "NO")

if ($IsMacOS)
{
    Write-Host "The nano editor is used to open the transcript and results."
    Write-Host "If necessary, please install nano using: brew install nano or use another available editor."
    Pause
}

# Exit if user does not want to continue
If ($openTranscriptResponse -in 'Y', 'YES')
{
    if (($IsLinux) -or ($IsMacOS))
    { 
        Set-Location -Path $LogDirectory -Verbose
        nano -v $Transcript
        nano -v $advisorResultsPath
        Set-Location -Path $HOME -Verbose
    } # end if 
    elseif (($IsWindows) -or ($PSVersionTable.PSEdition -eq "Desktop"))
    {
        Start-Process -FilePath notepad.exe $Transcript -Verbose
        Start-Process -FilePath notepad.exe $advisorResultsPath -Verbose
    } # end else
} #end condition
else
{
    # Terminate script
    Write-Host "End of Script!"
    $doubleSeparator
} # end else