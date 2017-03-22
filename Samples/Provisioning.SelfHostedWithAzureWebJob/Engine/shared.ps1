$ProgressPreference = "SilentlyContinue"
$WarningPreference = "SilentlyContinue"
Add-Type -Path $PSScriptRoot\bundle\Microsoft.SharePoint.Client.Taxonomy.dll -ErrorAction SilentlyContinue
Add-Type -Path $PSScriptRoot\bundle\Microsoft.SharePoint.Client.DocumentManagement.dll -ErrorAction SilentlyContinue
Add-Type -Path $PSScriptRoot\bundle\Microsoft.SharePoint.Client.WorkflowServices.dll -ErrorAction SilentlyContinue
Add-Type -Path $PSScriptRoot\bundle\Microsoft.SharePoint.Client.Search.dll -ErrorAction SilentlyContinue

Add-Type -Path $PSScriptRoot\bundle\Newtonsoft.Json.dll -ErrorAction SilentlyContinue
Add-Type -Path $PSScriptRoot\bundle\Microsoft.IdentityModel.Extensions.dll -ErrorAction SilentlyContinue
Import-Module $PSScriptRoot\bundle\SharePointPnPPowerShellOnline.psd1 -ErrorAction SilentlyContinue

Set-PnPTraceLog -Off

$tenantURL = ([environment]::GetEnvironmentVariable("APPSETTING_TenantURL"))
if(!$tenantURL){
    $tenant = ([environment]::GetEnvironmentVariable("APPSETTING_Tenant"))
    $tenantURL = [string]::format("https://{0}.sharepoint.com",$tenant)
}

$primarySiteCollectionAdmin = ([environment]::GetEnvironmentVariable("APPSETTING_PrimarySiteCollectionOwnerEmail"))
$siteDirectorySiteUrl = ([environment]::GetEnvironmentVariable("APPSETTING_SiteDirectoryUrl"))
$siteDirectoryList = '/Lists/Sites'
$managedPath = 'teams' # sites/teams
$columnPrefix = 'PZL_'
$propBagTemplateInfoStampKey = "_PnP_AppliedTemplateInfo" #pnp packages
$propBagTemplateNameStampKey = "_PnP_AppliedTemplateName" #conseptual templates

$Global:lastContextUrl = ''

#Azure appsettings variables - remove prefix when adding in azure
$appId = ([environment]::GetEnvironmentVariable("APPSETTING_AppId"))
if(!$appId){
    $appId = ([environment]::GetEnvironmentVariable("APPSETTING_ClientId"))
}

$appSecret = ([environment]::GetEnvironmentVariable("APPSETTING_AppSecret"))
if(!$appSecret){
    $appSecret = ([environment]::GetEnvironmentVariable("APPSETTING_ClientSecret"))
}

$uri = [Uri]$tenantURL
$tenantUrl = $uri.Scheme + "://" + $uri.Host
$tenantAdminUrl = $tenantUrl.Replace(".sharepoint", "-admin.sharepoint")


function Connect([string]$Url){    
    if($Url -eq $Global:lastContextUrl){
        return
    }
    if ($appId -ne $null -and $appSecret -ne $null) {
        Connect-PnPOnline -Url $Url -AppId $appId -AppSecret $appSecret
    } else {
        Connect-PnPOnline -Url $Url
    }
    $Global:lastContextUrl = $Url
}

function GetMailContent{
    Param(
        [string]$email,
        [string]$mailFile
    )
    $ext = "en";
    if($mail) {
        $ext = $email.Substring($email.LastIndexOf(".")+1)
    }
    $filename = "$PSScriptRoot/resources/$mailFile-mail-$ext.txt"
    if(-not (Test-Path $filename)) {
        $ext = "en"
        $filename = "$PSScriptRoot/resources/$mailFile-mail-$ext.txt"
    }
    return ([IO.File]::ReadAllText($filename)).Split("|")
}

function GetLoginName{
    Param(
        [int]$lookupId
    )
    Connect -Url "$tenantURL$siteDirectorySiteUrl"
    $web = Get-PnPWeb
    $user = Get-PnPListItem -List $web.SiteUserInfoList -Id $lookupId
    return $user["Name"]    
}

function SetRequestAccessEmail([string]$siteUrl, [string]$ownersEmail) {
    Connect -Url $siteUrl
    $emails = Get-PnPRequestAccessEmails
    if($emails -ne $ownersEmail) {
        Write-Output "`tSetting site request e-mail to $ownersEmail"    
        Set-PnPRequestAccessEmails -Emails $ownersEmail
    }
}

function SyncPermissions{
    Param(
        [string]$siteUrl,
        [Microsoft.SharePoint.Client.ListItem]$item
    )

    Write-Output "`tSyncing owners/members/visitors from site to directory list"
    Connect -Url $siteUrl
    $visitorsGroup = Get-PnPGroup -AssociatedVisitorGroup -ErrorAction SilentlyContinue
    $membersGroup = Get-PnPGroup -AssociatedMemberGroup -ErrorAction SilentlyContinue
    $ownersGroup = Get-PnPGroup -AssociatedOwnerGroup -ErrorAction SilentlyContinue

    $visitors = @($visitorsGroup.Users | select -ExpandProperty LoginName)
    $members = @($membersGroup.Users | select -ExpandProperty LoginName)
    $owners = @($ownersGroup.Users | select -ExpandProperty LoginName)

    Connect -Url "$tenantURL$siteDirectorySiteUrl"

    $owners = @($owners -notlike 'SHAREPOINT\system' |% {New-PnPUser -LoginName $_ | select -ExpandProperty ID} | sort) 
    $members = @($members -notlike 'SHAREPOINT\system' |% {New-PnPUser -LoginName $_ | select -ExpandProperty ID} | sort) 
    $visitors = @($visitors -notlike 'SHAREPOINT\system' |% {New-PnPUser -LoginName $_ | select -ExpandProperty ID} | sort) 
    
    $existingOwners = @($item["$($columnPrefix)SiteOwners"] | select -ExpandProperty LookupId | sort)
    $existingMembers = @($item["$($columnPrefix)SiteMembers"] | select -ExpandProperty LookupId | sort)
    $existingVisitors = @($item["$($columnPrefix)SiteVisitors"] | select -ExpandProperty LookupId | sort)

    $diffOwner = Compare-Object -ReferenceObject $owners -DifferenceObject $existingOwners -PassThru
    $diffMember = Compare-Object -ReferenceObject $members -DifferenceObject $existingMembers -PassThru
    $diffVisitor = Compare-Object -ReferenceObject $visitors -DifferenceObject $existingVisitors -PassThru

    if($diffOwner -or $diffMember -or $diffVisitor) {
        Write-Host "`tUpdating changed owners/members/visitors"
        $siteItem = Set-PnPListItem -List $siteDirectoryList -Identity $itemId -Values @{"$($columnPrefix)SiteOwners" = $owners; "$($columnPrefix)SiteMembers" = $members; "$($columnPrefix)SiteVisitors" = $visitors}
    }
}