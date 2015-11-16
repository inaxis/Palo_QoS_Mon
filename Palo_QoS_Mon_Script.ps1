param(
[string]$fw,
[string]$if,
[string]$rule = "regular-traffic",
[string]$type = "regular-traffic")

$api_login_string = "ENTER YOUR API KEY HERE"

Function callApiOp ($firewall, $param)
{
    # Function to call an operational-api action
    $request = New-Object System.Net.WebClient
    $apiurl = "https://" + $firewall + "/api/?key=" + $api_login_string + "&type=op&cmd=" + $param
    return [xml]$request.DownloadString($apiurl)
}

Function getConfig ($firewall, $xpath)
{
    # Function to call a config-api action
    $request = New-Object System.Net.WebClient
    $apiurl = "https://" + $firewall + "/api/?key=" + $api_login_string + "&type=config&action=get&xpath=" + $xpath
    [xml]$xml = [xml]$request.DownloadString($apiurl)
    return [xml]$xml.response.result.innerXML
}

#Get the QoS configuration of the firewall
$xd = getConfig $fw "/config/devices/entry[@name='localhost.localdomain']/network/qos"
#$xd = callApiOp $fw "<show><config><running></running></config></show>"

#Extracte the QoS configuration for the supplied interface
$qosinterface = $xd.qos.interface.entry | where {$_.name -eq $if}

#Check if a rule was supplied, if yes extract the configuration of that particular rule
if ($rule -ne "regular-traffic")
{
    $qosRegularRule = $qosinterface.$type.groups.entry.members.entry | where {$_.name -eq $rule}
}
#If the variable $rule is equal to $null then set the following variables
else
{
    $qosRegularRule = "regular"
    $rule = "regular-traffic"
    $rulenumber = 0
}

#Set the xml header and expected prtg root tag
$prtgoutput = '<?xml version="1.0" encoding="Windows-1252" ?>'
$prtgoutput += "<prtg>`n"

#Check if either the interfaceconfig or the ruleconfig is empty
if ($qosinterface -eq $null)
{
    $prtgoutput += "<error>1</error>`n"
    $prtgoutput += "<text>Invalid interface</text>`n"
    $prtgoutput += "</prtg>`n"
    $prtgoutput
    exit
}
if ($qosRegularRule -eq $null)
{
    $prtgoutput += "<error>1</error>`n"
    $prtgoutput += "<text>Invalid QoS Rule</text>`n"
    $prtgoutput += "</prtg>`n"
    $prtgoutput
    exit
}

#Additionally, check if QoS is enabled on the supplied interface
if ($xd.SelectSingleNode("/qos/interface/entry[@name='$if']/enabled").get_InnerXML() -ne "yes")
{
    $prtgoutput += "<error>1</error>`n"
    $prtgoutput += "<text>QoS disabled on this interface</text>`n"
    $prtgoutput += "</prtg>"
    $prtgoutput
    exit
}

if ($rulenumber -ne 0)
{
    #Create an empty hashtable for storing a mappingtable for Qos rulenumber (=node ID) and the rulename
    $rulearray = @{}

    #Count through the regular rules and add their numbers and names to the hashtable
    $count = 1
    foreach ($regularrule in $qosinterface.'regular-traffic'.groups.entry.members.entry)
    {
        $rulearray.Add($regularrule.GetAttribute('name'), $count)
        $count++
    }
    #Get the Node ID for the supplied rulename
    $rulenumber = $rulearray[$rule].tostring()
}

#Get the output of the command "show qos interface <ifname> throughput <nodeid> or for the supplied tunnelinterface"
switch ($type)
{
    "regular-traffic"
    {
        $traffic = callApiOp $fw "<show><qos><interface>$if</interface><throughput>$rulenumber</throughput></qos></show>"
    }
    "tunnel-traffic"
    {
        $traffic = callApiOp $fw "<show><qos><interface>$if</interface><tunnel-throughput>$rule</tunnel-throughput></qos></show>"
    }
    default
    {
        $prtgoutput += "<error>1</error>`n"
        $prtgoutput += "<text>Wrong traffic type. Leave blank for 'regular-traffic' or enter 'tunnel-traffic'</text>`n"
        $prtgoutput += "</prtg>"
        $prtgoutput
        exit
    }
}

#Reduce the output to an array of max. 8 values which should only contain bandwidth values in kbps
$regex = '([cC]lass\s\d[:\s]\s{0,}\d{0,}\skbps)'
$traffic = $traffic.response.result | Select-String -Pattern $regex -AllMatches | % { $_.Matches } | % { $_.Value }

#Replace special characters, which need to be escaped in a regex string
$temprule = $rule.Replace(".","\.").Replace(" ","\s")
#Regex string which extracts the needed information from the command "show qos interface <IF> counter"
$counterRegex = '(\s{1,}\d{1,}\s{1,}\d{1,}\s' + $temprule + '\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\n((?:\s{1,}-Class\s{1,}\d{1}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,3}\n)+)|\s{1,}\d{1,}\s{1,}\d{1,}\s' + $temprule + '\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\n)'
$qoscounter = callApiOp $fw "<show><qos><interface>$if<counter></counter></interface></qos></show>"
$qoscounter = $qoscounter.response.result  | Select-String -Pattern $counterRegex | % { $_.Matches } | % { $_.Value }

#Create sensors for every QoS class
for ($i = 1; $i -le 8; $i++)
{
    $regex = '([cC]lass\s' + $i.tostring() + '[:\s]\s{0,}\d{0,}\skbps)'
    $line = $traffic | Select-String -Pattern $regex | % { $_.Matches } | % { $_.Value }
    $maxbandwidth = $null
    $egressguaranteed = $null

    if ($line -eq $null)
    {
        $trafficvalue = 0
        $class = $i
        $classname = "class" + $class.ToString()
    }
    else 
    {
        #convert the $line variable with the bandwith to an integer variable
        $trafficvalue = $line | Select-String -Pattern '(\d*\skbps)' | % { $_.Matches } | % { $_.Value } | Select-String -Pattern '(\d*)' | % { $_.Matches } | % { $_.Value }
        $trafficvalue = [int]$trafficvalue
        $class = $line | Select-String -Pattern '([cC]lass\s\d)' | % { $_.Matches } | % { $_.Value } | Select-String -Pattern '(\d)' | % { $_.Matches } | % { $_.Value }
        $classname = "class" + $class.ToString()
    }
    [decimal]$bps = $trafficvalue * 1024
    [decimal]$kbps = $trafficvalue
    [decimal]$mbps = $trafficvalue / 1024

    #Get the applied QoS Profilename if a rulename was supplied or get the profile for default profile for regular/tunnel traffic
    if ($rule -ne "regular-traffic")
    {
        $qosProfileName = $xd.SelectSingleNode("/qos/interface/entry [@name='$if']/$type/groups/entry [@name='$type-group']/members/entry [@name='$rule']/qos-profile").get_InnerXML()
    }
    else
    {
        $qosProfileName = $qosinterface.$type.'default-group'.InnerText
    }

    #Check if a maximum egress value was set in the profile for the specific class
    if ($xd.SelectSingleNode("/qos/profile/entry [@name='$qosProfileName']/class/entry [@name='$classname']/class-bandwidth/egress-max") -ne $null)
    {
        try {
            [int32]$maxbandwidth = $xd.SelectSingleNode("/qos/profile/entry [@name='$qosProfileName']/class/entry [@name='$classname']/class-bandwidth/egress-max").get_InnerXML()
        }
        catch {
            $maxbandwidth = $null
        }
    }

    #Check if the max-egress value was empty or zero; if yes get the aggregate max-egress value from the QoS Profile
    if (($maxbandwidth -eq $null) -or ($maxbandwidth -eq 0))
    {
        try {
            [int32]$maxbandwidth = $xd.SelectSingleNode("/qos/profile/entry [@name='$qosProfileName']/aggregate-bandwidth/egress-max").get_InnerXML()
        }
        catch {
            $maxbandwidth = $null
        }

        #Check if the aggregate max-egress value was empty or zero; if yes get the max-egress value for regular traffic on that interface
        if (($maxbandwidth -eq $null) -or ($maxbandwidth -eq 0))
        {
            try {
                [int32]$maxbandwidth = $qosinterface.$type.bandwidth.'egress-max'
            }
            catch {
                $maxbandwidth = $null
            }

            #Check if the regular traffic max-egress value was empty or zero; if yes get the max-egress value of the interface
            if (($maxbandwidth -eq $null) -or ($maxbandwidth -eq 0))
            {
                try {
                    [int32]$maxbandwidth = $qosinterface.'interface-bandwidth'.'egress-max'
                }
                catch {
                    $maxbandwidth = $null
                }

                #Check if the max-egress value on the interface is empty or zero; if yes get the speed value of the physical interface
                if (($maxbandwidth -eq $null) -or ($maxbandwidth -eq 0))
                {
                    $op = "<show><interface>" + $if + "</interface></show>"
                    $interface = callApiOp $fw $op
                    [int32]$maxbandwidth = $interface.response.result.hw.speed
                }
            }
        }
    }

    #Check if a guaranteed egress value was set in the profile for the specific class
    if ($xd.SelectSingleNode("/qos/profile/entry [@name='$qosProfileName']/class/entry [@name='$classname']/class-bandwidth/egress-guaranteed") -ne $null)
    {
        try {
            [int32]$egressguaranteed = $xd.SelectSingleNode("/qos/profile/entry [@name='$qosProfileName']/class/entry [@name='$classname']/class-bandwidth/egress-guaranteed").get_InnerXML()
        }
        catch {
            $egressguaranteed = $null
        }
    }

    #Check if the guaranteed-egress value was empty or zero; if yes get the aggregate guaranteed-egress value from the QoS Profile
    if (($egressguaranteed -eq $null) -or ($egressguaranteed -eq 0))
    {
        try {
            [int32]$egressguaranteed = $xd.SelectSingleNode("/qos/profile/entry [@name='$qosProfileName']/aggregate-bandwidth/egress-guaranteed").get_InnerXML()
        }
        catch {
            $egressguaranteed = $null
        }

        #Check if the aggregate guaranteed-egress value was empty or zero; if yes get the guaranteed-egress value for regular traffic on that interface
        if (($egressguaranteed -eq $null) -or ($egressguaranteed -eq 0))
        {
            try {
                [int32]$egressguaranteed = $qosinterface.$type.bandwidth.'egress-guaranteed'
            }
            catch {
                $egressguaranteed = $null
            }
        }
    }

    $prtgoutput += "<result>`n"
    $prtgoutput += "<channel>" + $classname +"</channel>`n"
    $prtgoutput += "<unit>Custom</unit>`n"
    $prtgoutput += "<customunit>Mbit/s</customunit>`n"
    $prtgoutput += "<mode>Absolute</mode>`n"
    $prtgoutput += "<showChart>1</showChart>`n"
    $prtgoutput += "<showTable>1</showTable>`n"
    $prtgoutput += "<float>1</float>`n"
    $prtgoutput += "<value>" + $mbps.ToString() + "</value>`n"
    $prtgoutput += "<LimitMode>1</LimitMode>`n"
    $prtgoutput += "<LimitMaxError>" + $maxbandwidth.ToString() + "</LimitMaxError>`n"
    $prtgoutput += "<LimitErrorMsg>The bandwidth  of " + $classname + " exeeds the configured max. value of " + $maxbandwidth.ToString() + " mbps</LimitErrorMsg>`n"

    #if there is a value for egress-guaranteed and it is not 0 then create a warning-limit in the traffic-channel and an additional sensor for making this limit visible in the chart
    if ($egressguaranteed -ne $null -and $egressguaranteed -ne 0)
    {
        $prtgoutput += "<LimitMaxWarning>" + $egressguaranteed.ToString() + "</LimitMaxWarning>`n"
        $prtgoutput += "<LimitWarningMsg>The bandwidth of " + $classname + " exeeds the configured guaranteed value of " + $egressguaranteed.ToString() + " mbps</LimitWarningMsg>`n"
        $prtgoutput += "</result>`n"

        $prtgoutput += "<result>`n"
        $prtgoutput += "<channel>" + $classname +" egress-guaranteed</channel>`n"
        $prtgoutput += "<unit>Custom</unit>`n"
        $prtgoutput += "<customunit>Mbit/s</customunit>`n"
        $prtgoutput += "<mode>Absolute</mode>`n"
        $prtgoutput += "<showChart>1</showChart>`n"
        $prtgoutput += "<showTable>0</showTable>`n"
        $prtgoutput += "<float>1</float>`n"
        $prtgoutput += "<value>" + $egressguaranteed.ToString() + "</value>`n"
        $prtgoutput += "</result>`n"
    }
    else
    {
        $prtgoutput += "</result>`n"            
    }

    $prtgoutput += "<result>`n"
    $prtgoutput += "<channel>" + $classname +" egress-max</channel>`n"
    $prtgoutput += "<unit>Custom</unit>`n"
    $prtgoutput += "<customunit>Mbit/s</customunit>`n"
    $prtgoutput += "<mode>Absolute</mode>`n"
    $prtgoutput += "<showChart>1</showChart>`n"
    $prtgoutput += "<showTable>0</showTable>`n"
    $prtgoutput += "<float>1</float>`n"
    $prtgoutput += "<value>" + $maxbandwidth.ToString() + "</value>`n"
    $prtgoutput += "</result>`n"

    #Calculate the used bandwidth in percent
    $percent = ($mbps / $maxbandwidth) * 100

    $prtgoutput += "<result>`n"
    $prtgoutput += "<channel>" + $classname +" Percentage</channel>`n"
    $prtgoutput += "<unit>Percent</unit>`n"
    $prtgoutput += "<mode>Absolute</mode>`n"
    $prtgoutput += "<showChart>1</showChart>`n"
    $prtgoutput += "<showTable>1</showTable>`n"
    $prtgoutput += "<float>1</float>`n"
    $prtgoutput += "<value>" + $percent + "</value>`n"
    $prtgoutput += "</result>`n"

    $regex = 'Class\s' + $class.toString() + '\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}(\d{1,12})\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,3}'
    $droppedPackets = $qoscounter | Select-String -Pattern $regex | % { $_.Matches } | % { $_.Value }
    if ($droppedPackets -ne $null)
    {
        $regex = 'Class\s' + $class.toString() + '\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}\d{1,}\s{1,}'
        $droppedPackets = $droppedPackets -replace $regex,'' | Select-String -Pattern '\d{1,}' | % { $_.Matches } | % { $_.Value }
        $prtgoutput += "<result>`n"
        $prtgoutput += "<channel>" + $classname +" dropped Packets</channel>`n"
        $prtgoutput += "<unit>#</unit>`n"
        $prtgoutput += "<mode>Difference</mode>`n"
        $prtgoutput += "<showChart>1</showChart>`n"
        $prtgoutput += "<showTable>1</showTable>`n"
        $prtgoutput += "<float>0</float>`n"
        $prtgoutput += "<value>" + $droppedPackets + "</value>`n"
        $prtgoutput += "</result>`n"
    }
}

#Close the xml root tag and show the output
$prtgoutput += "</prtg>"
$prtgoutput
