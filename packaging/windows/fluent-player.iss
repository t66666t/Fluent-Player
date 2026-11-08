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
AppName=Fluent Player
AppVersion={#AppVersion}
AppPublisher=Teezy Community
AppPublisherURL=https://github.com/t66666t/Fluent-Player
AppSupportURL=https://github.com/t66666t/Fluent-Player/issues
AppUpdatesURL=https://github.com/t66666t/Fluent-Player/releases
DefaultDirName={localappdata}\Programs\Fluent Player
UsePreviousAppDir=no
DefaultGroupName=Fluent Player
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=FluentPlayer-v{#AppVersion}-windows-x64-setup
SetupIconFile=..\..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\fluent-player.exe
LicenseFile=..\..\LICENSE
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

; Wizard text comes from the Simplified Chinese translation kept beside this script.
[Languages]
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: desktopicon; Description: "{cm:CreateDesktopIcon}"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Fluent Player"; Filename: "{app}\fluent-player.exe"; WorkingDir: "{app}"; AppUserModelID: "cn.teezy.fluentplayer.standard"
Name: "{autodesktop}\Fluent Player"; Filename: "{app}\fluent-player.exe"; WorkingDir: "{app}"; Tasks: desktopicon; AppUserModelID: "cn.teezy.fluentplayer.standard"

[Registry]
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\cn.teezy.fluentplayer.standard"; ValueType: string; ValueName: "DisplayName"; ValueData: "Fluent Player"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\AppUserModelId\cn.teezy.fluentplayer.standard"; ValueType: string; ValueName: "IconUri"; ValueData: "{app}\data\flutter_assets\android\app\src\main\res\mipmap-xxxhdpi\launcher_icon.png"

[Run]
Filename: "{app}\fluent-player.exe"; Description: "{cm:LaunchProgram,Fluent Player}"; Flags: nowait postinstall skipifsilent unchecked

#define EditionRunner "fluent-player.exe"
#define OtherEditionRunner "fluent-player-pro.exe"
#define EditionCompany "Teezy Community"
#define EditionProduct "Fluent Player"
#include "edition_guard.iss"
