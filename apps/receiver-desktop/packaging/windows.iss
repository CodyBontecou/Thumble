#define AppVersion "0.1.0"
#define SourceDir GetEnv("THUMBLE_DESKTOP_DIST")

[Setup]
AppId={{179A0788-27B4-43D2-8463-A2D1A92F1464}
AppName=Thumble Receiver
AppVersion={#AppVersion}
AppPublisher=Thumble
AppPublisherURL=https://thumble.io
DefaultDirName={localappdata}\Programs\ThumbleReceiver
DefaultGroupName=Thumble
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=Thumble-Receiver-{#AppVersion}-windows-x64-setup
Compression=lzma2
SolidCompression=yes
UninstallDisplayIcon={app}\thumble-receiver.exe
CloseApplications=yes
RestartApplications=no
WizardStyle=modern

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Thumble Receiver"; Filename: "{app}\thumble-receiver.exe"

[Registry]
Root: HKCU; Subkey: "Software\Classes\thumble-receiver"; ValueType: string; ValueName: ""; ValueData: "URL:Thumble Receiver"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\thumble-receiver"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKCU; Subkey: "Software\Classes\thumble-receiver\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\thumble-receiver.exe"" --oauth-callback ""%1"""
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: none; ValueName: "ThumbleReceiver"; Flags: uninsdeletevalue

[Run]
Filename: "{app}\thumble-receiver.exe"; Description: "Open Thumble Receiver"; Flags: nowait postinstall skipifsilent
