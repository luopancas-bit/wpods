using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using Microsoft.Win32.SafeHandles;
using WPods.Service;

// Exercise RadioLink's real USB/IP cancellation path without touching a Bluetooth adapter.
int failures = 0;
foreach ((byte pipe, bool running, int expectedAborts) in new (byte, bool, int)[]
{
    (0x81, true, 0), // Shared events: preserve bytes consumed by the physical reader.
    (0x82, true, 0), // Shared ACL: preserve fragment framing and WPods' own traffic.
    (0x83, true, 1), // Non-shared pipe: retain cancellation behaviour.
    (0x83, false, 0), // Queued requests must not abort someone else's transfer.
})
{
    using var listener = new TcpListener(IPAddress.Loopback, 0);
    listener.Start();
    using var peer = new TcpClient();
    peer.Connect((IPEndPoint)listener.LocalEndpoint);
    using TcpClient server = listener.AcceptTcpClient();
    using var handle = new SafeFileHandle(new nint(-1), ownsHandle: false);
    using var device = (WinUsbDevice)Activator.CreateInstance(typeof(WinUsbDevice),
        BindingFlags.Instance | BindingFlags.NonPublic, null, [handle], null)!;
    typeof(WinUsbDevice).GetField("_pipes", BindingFlags.Instance | BindingFlags.NonPublic)!
        .SetValue(device, new Dictionary<byte, nint> { [pipe] = new nint(123) });
    int aborts = 0;
    using var link = new RadioLink(server, device, new HciProxy(), (_, _) => aborts++);
    var request = new Urb { Seq = 42, Pipe = pipe, In = true, Length = 257, Running = running };
    var live = (ConcurrentDictionary<uint, Urb>)typeof(RadioLink)
        .GetField("_live", BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(link)!;
    live[request.Seq] = request;
    typeof(RadioLink).GetMethod("Unlink", BindingFlags.Instance | BindingFlags.NonPublic)!
        .Invoke(link, [(uint)43, request.Seq]);
    peer.ReceiveTimeout = 2000;
    var reply = new byte[48];
    peer.GetStream().ReadExactly(reply);
    bool pass = request.Cancelled && aborts == expectedAborts
        && UsbIp.U32(reply, 0) == 4 && UsbIp.U32(reply, 4) == 43;
    Console.WriteLine($"{(pass ? "PASS" : "FAIL")} cancel pipe=0x{pipe:X2} running={running}: aborts={aborts}, expected={expectedAborts}, cancellation acknowledged={request.Cancelled}");
    if (!pass) failures++;
}
{
    var proxy = new HciProxy();
    var type = typeof(HciProxy).GetNestedType("Link", BindingFlags.NonPublic)!;
    var link = Activator.CreateInstance(type, [1, 0UL, false])!;
    var requests = (Dictionary<byte, ushort>)type.GetField("AvdtpRequests")!.GetValue(link)!;
    var note = typeof(HciProxy).GetMethod("NoteInboundSignalingLocked", BindingFlags.NonPublic | BindingFlags.Instance)!;
    // ReadOnlySpan cannot be passed through reflection; exercise the channel registration seam directly.
    var add = typeof(HciProxy).GetMethod("AddAvdtpChannel", BindingFlags.NonPublic | BindingFlags.Static)!;
    add.Invoke(null, [link, (ushort)0x40, (ushort)0x60]);
    add.Invoke(null, [link, (ushort)0x40, (ushort)0x60]);
    var state = type.GetField("Avdtp")!.GetValue(link)!;
    bool duplicateSafe = (ushort)state.GetType().GetField("MediaRemote")!.GetValue(state)! == 0;
    Console.WriteLine($"{(duplicateSafe ? "PASS" : "FAIL")} duplicate signaling response does not become media channel");
    if (!duplicateSafe) failures++;
}
return failures == 0 ? 0 : 1;
