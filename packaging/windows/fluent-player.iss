#ifndef AppVersion
  #error AppVersion must be supplied by package_windows_release.ps1
#endif
#ifndef BundleDir
  #error BundleDir must point at the staged runtime, not the source checkout
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif

[Setup]
AppId={{627EC819-F9DA-4D7C-84F3-B9BC408AD30C}
AppName=Fluent Player Community
AppVersion={#AppVersion}
AppPublisher=Fluent Player Community contributors
AppPublisherURL=https://github.com/t66666t/Video-master
AppSupportURL=https://github.com/t66666t/Video-master/issues
AppUpdatesURL=https://github.com/t66666t/Video-master/releases
DefaultDirName={localappdata}\Programs\FluentPlayerCommunity
DefaultGroupName=Fluent Player Community
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=FluentPlayerCommunity-v{#AppVersion}-windows-x64-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\fluent_player_community.exe
LicenseFile=..\..\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: desktopicon; Description: "Create a desktop shortcut"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Fluent Player Community"; Filename: "{app}\fluent_player_community.exe"; WorkingDir: "{app}"; AppUserModelID: "io.github.t66666t.FluentPlayerCommunity"
Name: "{autodesktop}\Fluent Player Community"; Filename: "{app}\fluent_player_community.exe"; WorkingDir: "{app}"; Tasks: desktopicon; AppUserModelID: "io.github.t66666t.FluentPlayerCommunity"

[Registry]
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\io.github.t66666t.FluentPlayerCommunity"; ValueType: string; ValueName: "DisplayName"; ValueData: "Fluent Player Community"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\io.github.t66666t.FluentPlayerCommunity"; ValueType: string; ValueName: "IconUri"; ValueData: "{app}\data\flutter_assets\android\app\src\main\res\mipmap-xxxhdpi\launcher_icon.png"

[Run]
Filename: "{app}\fluent_player_community.exe"; Description: "Open Fluent Player Community"; Flags: nowait postinstall skipifsilent unchecked
