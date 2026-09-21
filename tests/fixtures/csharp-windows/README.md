# csharp-windows

A project that can only build on Windows: `net8.0-windows` with
`UseWindowsForms`, which needs the Windows Desktop targeting pack.

It exists because the C# preset defaulted to `ubuntu-latest` while the one
production C# application in the fleet targets a Windows-only framework, so the
preset could not serve it at all. Two self-test legs use this fixture: one
builds it on `windows-latest` and must pass, the other attempts it on Linux and
must fail with a message naming the platform.

The second leg is the one that matters. A runner input that is never exercised
on the runner it was added for proves nothing.
