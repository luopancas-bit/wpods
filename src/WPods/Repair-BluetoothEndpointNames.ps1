<#
.SYNOPSIS
Previews or repairs the leading-@ Bluetooth audio name failure without restarting services.
.DESCRIPTION
Opt-in compatibility recovery, not a kernel driver or crash fix. Requires an already connected
Bluetooth device. Only present audio parents in the requested device's container are eligible.
The default is read-only. -Apply writes a prefixed display name through CoreAudio, then
republishes only affected active endpoints. No drivers, pairing, services or security settings change.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9A-Fa-f]{12}$')][string]$BluetoothAddress,
    [switch]$Apply,
    [switch]$OnAttach, [string[]]$EndpointId, [switch]$SelectDefault
)
$ErrorActionPreference = 'Stop'
if ($SelectDefault -and !$Apply) { throw '-SelectDefault requires -Apply.' }

Add-Type -TypeDefinition @'
using System;using System.Runtime.InteropServices;
public static class EndpointPropertyRepair {
 [StructLayout(LayoutKind.Sequential)]public struct Key{public Guid guid;public uint pid;}
 [StructLayout(LayoutKind.Explicit,Size=24)]public struct Value{[FieldOffset(0)]public ushort type;[FieldOffset(8)]public IntPtr text;}
 [ComImport,Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]interface Enumerator{
  [PreserveSig]int EnumAudioEndpoints(int flow,uint state,out IntPtr collection);
  [PreserveSig]int GetDefaultAudioEndpoint(int flow,int role,out Device device);
  [PreserveSig]int GetDevice([MarshalAs(UnmanagedType.LPWStr)]string id,out Device device);
  [PreserveSig]int RegisterEndpointNotificationCallback(IntPtr client);
  [PreserveSig]int UnregisterEndpointNotificationCallback(IntPtr client);
 }
 [ComImport,Guid("D666063F-1587-4E43-81F1-B948E807363F"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]interface Device{
  [PreserveSig]int Activate(ref Guid iid,uint context,IntPtr activation,out IntPtr result);
  [PreserveSig]int OpenPropertyStore(uint mode,out Store store);
  [PreserveSig]int GetId(out IntPtr id);
  [PreserveSig]int GetState(out uint state);
 }
 [ComImport,Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]interface Store{
  [PreserveSig]int GetCount(out uint count);
  [PreserveSig]int GetAt(uint index,out Key key);
  [PreserveSig]int GetValue(ref Key key,out Value value);
  [PreserveSig]int SetValue(ref Key key,ref Value value);
  [PreserveSig]int Commit();
 }
 [DllImport("ole32.dll")]static extern int PropVariantClear(ref Value value);
 public static uint State(string id){var e=(Enumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")));Device d=null;try{if(e.GetDevice(id,out d)<0)return 0;uint state;return d.GetState(out state)<0?0:state;}finally{if(d!=null)Marshal.ReleaseComObject(d);Marshal.ReleaseComObject(e);}}
 public static string Update(string id,string name){
  var e=(Enumerator)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")));
  Device d;Store s;int h=e.GetDevice(id,out d);if(h<0)return "GetDevice 0x"+h.ToString("X8");
  h=d.OpenPropertyStore(2,out s);if(h<0)return "OpenPropertyStore 0x"+h.ToString("X8");
  var k=new Key{guid=new Guid("b3f8fa53-0004-438e-9003-51a46e139bfc"),pid=6};
  Value old;int read=s.GetValue(ref k,out old);string previous=read>=0&&old.type==31?Marshal.PtrToStringUni(old.text):null;
  PropVariantClear(ref old); if(read!=unchecked((int)0x80004005)){Marshal.ReleaseComObject(s);Marshal.ReleaseComObject(d);Marshal.ReleaseComObject(e);return "skipped read=0x"+read.ToString("X8");}
  var v=new Value{type=(ushort)(name==null?0:31),text=name==null?IntPtr.Zero:Marshal.StringToCoTaskMemUni(name)};
  try{h=s.SetValue(ref k,ref v);if(h>=0)h=s.Commit();return "read=0x"+read.ToString("X8")+" previous="+previous+" write=0x"+h.ToString("X8");}
  finally{PropVariantClear(ref v);Marshal.ReleaseComObject(s);Marshal.ReleaseComObject(d);Marshal.ReleaseComObject(e);}
 }
}

public static class EndpointRepublish {
 [ComImport,Guid("F8679F50-850A-41CF-9C72-430F290290C8"),InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]interface Policy{
  void Unused1();void Unused2();void Unused3();void Unused4();void Unused5();void Unused6();void Unused7();void Unused8();void Unused9();void Unused10();
  void SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)]string id,int role);
  void SetEndpointVisibility([MarshalAs(UnmanagedType.LPWStr)]string id,[MarshalAs(UnmanagedType.I2)]short visible);
 }
 public static string Refresh(string id){
  var p=(Policy)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")));
  try{p.SetEndpointVisibility(id,0);p.SetEndpointVisibility(id,1);return "success";}
  catch(Exception e){return "0x"+e.HResult.ToString("X8")+" "+e.Message;}
  finally{try{p.SetEndpointVisibility(id,1);}catch{}Marshal.ReleaseComObject(p);}
 }
 public static void Default(string id){var p=(Policy)Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("870AF99C-171D-4F9E-AF0D-E63DF40C2BC9")));try{p.SetDefaultEndpoint(id,0);p.SetDefaultEndpoint(id,1);}finally{Marshal.ReleaseComObject(p);}}
}
'@

$media = @(Get-PnpDevice -PresentOnly -Class Media)
$primary = @($media | Where-Object {
    $_.InstanceId.StartsWith('BTHENUM\', [StringComparison]::OrdinalIgnoreCase) -and
    $_.InstanceId.IndexOf($BluetoothAddress, [StringComparison]::OrdinalIgnoreCase) -ge 0
})
if (!$primary.Count) { throw 'No present Bluetooth audio parent matches the requested address.' }
$containers = @($primary | ForEach-Object {
    (Get-PnpDeviceProperty -InstanceId $_.InstanceId -KeyName DEVPKEY_Device_ContainerId).Data.ToString()
})
$parentIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($device in $media) {
    if (!$device.InstanceId.StartsWith('BTH', [StringComparison]::OrdinalIgnoreCase)) { continue }
    $container = (Get-PnpDeviceProperty -InstanceId $device.InstanceId -KeyName DEVPKEY_Device_ContainerId -ErrorAction SilentlyContinue).Data
    if ($null -ne $container -and $container.ToString() -in $containers) {
        [void]$parentIds.Add($device.InstanceId)
    }
}

$machine = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
$results = @()
$observed = @()
try {
    foreach ($flow in @('Render', 'Capture')) {
        $audio = $machine.OpenSubKey('SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\' + $flow)
        if ($null -eq $audio) { continue }
        try {
            foreach ($guid in $audio.GetSubKeyNames()) {
                $properties = $audio.OpenSubKey($guid + '\Properties')
                if ($null -eq $properties) { continue }
                try {
                    $binding = [string]$properties.GetValue('{b3f8fa53-0004-438e-9003-51a46e139bfc},2')
                    if (!$binding.StartsWith('{1}.BTH', [StringComparison]::OrdinalIgnoreCase) -or !$parentIds.Contains($binding.Substring(4))) { continue }
                    $rawName = [string]$properties.GetValue('{b3f8fa53-0004-438e-9003-51a46e139bfc},6')

                    $id = if ($flow -eq 'Render') { '{0.0.0.00000000}.' + $guid } else { '{0.0.1.00000000}.' + $guid }
                    if ($EndpointId -and $id -notin $EndpointId) { continue }
                    $liveState = [EndpointPropertyRepair]::State($id)
                    if ($OnAttach -and $flow -eq 'Render' -and $binding.StartsWith('{1}.BTHENUM\', [StringComparison]::OrdinalIgnoreCase)) {
                        $observed += [pscustomobject]@{Id=$id;State=$liveState;NameNeedsRepair=$rawName.StartsWith('@',[StringComparison]::Ordinal)}
                    }
                    if (!$rawName.StartsWith('@', [StringComparison]::Ordinal)) { continue }
                    if ($liveState -notin @(1, 8)) { continue }
                    if ($OnAttach) {
                        if ($flow -ne 'Render' -or $liveState -ne 1 -or !$binding.StartsWith('{1}.BTHENUM\', [StringComparison]::OrdinalIgnoreCase)) { continue }
                    }
                    $replacement = 'Bluetooth ' + $rawName
                    $row = [ordered]@{Id=$id;OriginalName=$rawName;Replacement=$replacement;StateBefore=$liveState;Applied=$false;Published=$false;DefaultChanged=$false}
                    if ($Apply) {
                        $row.WriteResult = [EndpointPropertyRepair]::Update($id, $replacement)
                        if ($row.WriteResult -match 'write=0x00000000') {
                            $row.Applied = $true
                            $existing = Get-PnpDevice -PresentOnly -InstanceId ('SWD\MMDEVAPI\' + $id) -ErrorAction SilentlyContinue
                            if (!$existing) { $row.PublishResult = [EndpointRepublish]::Refresh($id) }
                            $node = Get-PnpDevice -PresentOnly -InstanceId ('SWD\MMDEVAPI\' + $id) -ErrorAction SilentlyContinue
                            $row.StateAfter = [EndpointPropertyRepair]::State($id)
                            $row.Published = $null -ne $node -and $node.Status -eq 'OK' -and $row.StateAfter -eq 1
                            if ($SelectDefault -and $flow -eq 'Render' -and $binding.IndexOf($BluetoothAddress, [StringComparison]::OrdinalIgnoreCase) -ge 0 -and $row.Published) {
                                [EndpointRepublish]::Default($id)
                                $row.DefaultChanged = $true
                            }
                        }
                    }
                    $results += [pscustomobject]$row
                } finally { $properties.Dispose() }
            }
        } finally { $audio.Dispose() }
    }
} finally { $machine.Dispose() }
if ($OnAttach) {
    $ready = @($observed | Where-Object {
        $_.State -eq 1 -and (!$_.NameNeedsRepair -or $_.Id -in @($results | Where-Object Published | ForEach-Object Id))
    }).Count -gt 0
    [pscustomobject]@{Ready=$ready;Observed=$observed;Repairs=$results} | ConvertTo-Json -Depth 5 -Compress
} else { $results }