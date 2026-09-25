; The Windows installer, built by build-windows.sh from the bundle it has just
; made. Per user and without administrator rights, into
; %LOCALAPPDATA%\Programs\Lumeo, as Windows apps that update themselves out of
; band do: the core only needs the account it runs as, the same as on Linux.
;
; Uninstalling leaves %LOCALAPPDATA%\Lumeo alone: that is the library and the
; downloads, and a reinstall should find them.

#ifndef Version
  #error Run as: iscc /DVersion=X.Y.Z lumeo.iss
#endif

[Setup]
; Fixed for good: it is how Windows knows a new version is this app.
AppId={{82158435-1197-4765-B0B6-5BC91DBFB79F}
AppName=Lumeo
AppVersion={#Version}
AppPublisher=Lumeo
DefaultDirName={autopf}\Lumeo
DisableProgramGroupPage=yes
DisableDirPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
; Explorer has to be told that "Open with" has a new entry.
ChangesAssociations=yes
OutputDir=..\dist
OutputBaseFilename=lumeo-{#Version}-windows-x86_64-setup
SetupIconFile=..\client\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\lumeo.exe
LicenseFile=..\LICENSE
WizardStyle=modern
SolidCompression=yes

[Tasks]
Name: desktopicon; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Files]
Source: "..\client\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Lumeo"; Filename: "{app}\lumeo.exe"
Name: "{autodesktop}\Lumeo"; Filename: "{app}\lumeo.exe"; Tasks: desktopicon

; "Open with Lumeo" for the containers the Linux desktop entry claims. Offered,
; not taken: no extension is made to open with Lumeo by default.
[Registry]
Root: HKA; Subkey: "Software\Classes\Applications\lumeo.exe"; ValueType: string; ValueName: "FriendlyAppName"; ValueData: "Lumeo"; Flags: uninsdeletekey
Root: HKA; Subkey: "Software\Classes\Applications\lumeo.exe\shell\open\command"; ValueType: string; ValueData: """{app}\lumeo.exe"" ""%1"""
Root: HKA; Subkey: "Software\Classes\Applications\lumeo.exe\SupportedTypes"; ValueType: string; ValueName: ".mkv"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\lumeo.exe\SupportedTypes"; ValueType: string; ValueName: ".mp4"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\lumeo.exe\SupportedTypes"; ValueType: string; ValueName: ".m4v"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\lumeo.exe\SupportedTypes"; ValueType: string; ValueName: ".webm"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\lumeo.exe\SupportedTypes"; ValueType: string; ValueName: ".mov"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\lumeo.exe\SupportedTypes"; ValueType: string; ValueName: ".avi"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\lumeo.exe\SupportedTypes"; ValueType: string; ValueName: ".wmv"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\lumeo.exe\SupportedTypes"; ValueType: string; ValueName: ".flv"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\lumeo.exe\SupportedTypes"; ValueType: string; ValueName: ".mpg"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\lumeo.exe\SupportedTypes"; ValueType: string; ValueName: ".ts"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\lumeo.exe\SupportedTypes"; ValueType: string; ValueName: ".ogv"; ValueData: ""
Root: HKA; Subkey: "Software\Classes\Applications\lumeo.exe\SupportedTypes"; ValueType: string; ValueName: ".3gp"; ValueData: ""

[Run]
Filename: "{app}\lumeo.exe"; Description: "{cm:LaunchProgram,Lumeo}"; Flags: nowait postinstall skipifsilent
