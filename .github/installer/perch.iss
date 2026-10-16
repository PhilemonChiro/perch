; Inno Setup script for Perch — produces a single-file Windows installer.
; The app version is passed in from CI:  iscc /DAppVersion=0.1.3 perch.iss
; SourceDir is the windeployqt output folder (dist\), passed as /DSourceDir=...

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\..\dist"
#endif

[Setup]
AppId={{B6F6A6C2-7C3E-4E5B-9E0A-9D1E5E7A5C01}
AppName=Perch
AppVersion={#AppVersion}
AppPublisher=Philemon Chiro
AppPublisherURL=https://github.com/PhilemonChiro/perch
DefaultDirName={autopf}\Perch
DefaultGroupName=Perch
DisableProgramGroupPage=yes
; Per-user install so no admin prompt is needed.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
OutputDir=.
OutputBaseFilename=Perch-Setup-x64
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName=Perch
#if FileExists(AddBackslash(SourceDir) + "perch.ico")
SetupIconFile={#SourceDir}\perch.ico
#endif

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Additional icons:"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Perch"; Filename: "{app}\Perch.exe"; IconFilename: "{app}\perch.ico"
Name: "{group}\Uninstall Perch"; Filename: "{uninstallexe}"
Name: "{autodesktop}\Perch"; Filename: "{app}\Perch.exe"; IconFilename: "{app}\perch.ico"; Tasks: desktopicon

[Run]
Filename: "{app}\Perch.exe"; Description: "Launch Perch"; Flags: nowait postinstall skipifsilent
