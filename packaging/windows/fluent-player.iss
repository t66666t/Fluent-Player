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
AppId={{9B96EEC0-E65C-4D95-B59B-BB90E07BE26C}
AppName=Fluent Player
AppVersion={#AppVersion}
AppPublisher=Fluent Player contributors
AppPublisherURL=https://github.com/t66666t/Video-master
AppSupportURL=https://github.com/t66666t/Video-master/issues
AppUpdatesURL=https://github.com/t66666t/Video-master/releases
DefaultDirName={localappdata}\Programs\FluentPlayer
DefaultGroupName=Fluent Player
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=FluentPlayer-v{#AppVersion}-windows-x64-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\video_player_app.exe
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
Name: "{group}\Fluent Player"; Filename: "{app}\video_player_app.exe"; WorkingDir: "{app}"; AppUserModelID: "io.github.t66666t.FluentPlayer"
Name: "{autodesktop}\Fluent Player"; Filename: "{app}\video_player_app.exe"; WorkingDir: "{app}"; Tasks: desktopicon; AppUserModelID: "io.github.t66666t.FluentPlayer"

[Registry]
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\io.github.t66666t.FluentPlayer"; ValueType: string; ValueName: "DisplayName"; ValueData: "Fluent Player"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\io.github.t66666t.FluentPlayer"; ValueType: string; ValueName: "IconUri"; ValueData: "{app}\data\flutter_assets\android\app\src\main\res\mipmap-xxxhdpi\launcher_icon.png"

[Run]
Filename: "{app}\video_player_app.exe"; Description: "Open Fluent Player"; Flags: nowait postinstall skipifsilent unchecked
