; Compile only through tool/package_windows.ps1 for a verified release payload.
#ifndef PayloadDir
  #error PayloadDir must name the verified installer payload directory.
#endif
#ifndef ReleaseVersion
  #error ReleaseVersion is required.
#endif
#ifndef ReleaseBuildNumber
  #error ReleaseBuildNumber is required.
#endif
#ifndef OutputDirectory
  #error OutputDirectory is required.
#endif
#ifndef OutputFilename
  #error OutputFilename is required.
#endif
#ifndef ProjectRoot
  #define ProjectRoot "..\.."
#endif

#define ProductName "BK 提词器"
#define ProductExe "BK 提词器.exe"
#define ProductVersion ReleaseVersion + "+" + ReleaseBuildNumber
#define FileVersion ReleaseVersion + "." + ReleaseBuildNumber

[Setup]
AppId=BeyondChenlin.BKTeleprompter
AppName={#ProductName}
AppVersion={#ReleaseVersion}
AppVerName={#ProductName} {#ReleaseVersion}
AppPublisher=陈林
AppContact=beyond.chenlin@gmail.com
AppSupportURL=mailto:beyond.chenlin@gmail.com
AppCopyright=Copyright (C) 2026 陈林.
DefaultDirName={localappdata}\Programs\BKTeleprompter
DefaultGroupName={#ProductName}
UsePreviousAppDir=yes
UsePreviousGroup=yes
UsePreviousTasks=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.18362
DisableWelcomePage=no
DisableProgramGroupPage=yes
AllowNoIcons=yes
WizardStyle=modern
SetupIconFile={#ProjectRoot}\windows\runner\resources\app_icon.ico
UninstallDisplayName={#ProductName}
UninstallDisplayIcon={app}\{#ProductExe}
AppReadmeFile={app}\使用说明.txt
Uninstallable=yes
CloseApplications=yes
RestartApplications=no
OutputDir={#OutputDirectory}
OutputBaseFilename={#OutputFilename}
Compression=lzma2
SolidCompression=yes
VersionInfoCompany=陈林
VersionInfoDescription={#ProductName}安装程序
VersionInfoCopyright=Copyright (C) 2026 陈林.
VersionInfoProductName={#ProductName}
VersionInfoVersion={#FileVersion}
VersionInfoTextVersion={#ProductVersion}
VersionInfoProductVersion={#FileVersion}
VersionInfoProductTextVersion={#ProductVersion}

[Languages]
Name: "chinesesimplified"; MessagesFile: "vendor\ChineseSimplified.isl"

[Messages]
WelcomeLabel2=本向导将为当前用户安装 [name/ver]，无需管理员权限。%n%n安装包已包含中文语音模型。升级和卸载均保留您的稿件、设置及语音模型。%n%n请先保存稿件并关闭正在运行的提词器，然后继续。
FinishedLabel=BK 提词器已安装完成。%n%n您可以通过桌面或开始菜单打开程序。中文语音模型将在首次使用时自动准备到用户数据目录。
ConfirmUninstall=您确定要卸载 %1 吗？%n%n稿件、设置及用户语音模型会保留，重新安装后可继续使用。
UninstalledAll=%1 已卸载。%n%n您的稿件、设置及用户语音模型已保留。

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "快捷方式："; Flags: checkedonce

[Files]
; The package script stages an explicit allowlist. It never stages user app_data.
Source: "{#PayloadDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#ProductName}"; Filename: "{app}\{#ProductExe}"; WorkingDir: "{app}"; IconFilename: "{app}\{#ProductExe}"
Name: "{group}\卸载 {#ProductName}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\{#ProductName}"; Filename: "{app}\{#ProductExe}"; WorkingDir: "{app}"; IconFilename: "{app}\{#ProductExe}"; Tasks: desktopicon

; Deliberately no [Run], [InstallDelete], or [UninstallDelete] actions:
; installation never launches the app, migrates user data, or deletes a data tree.

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  TargetDirectory: String;
  UserDataDirectory: String;
begin
  Result := '';
  TargetDirectory := AddBackslash(ExpandConstant('{app}'));
  UserDataDirectory := AddBackslash(ExpandConstant('{localappdata}\BKTeleprompter\app_data'));
  if CompareText(Copy(TargetDirectory, 1, Length(UserDataDirectory)), UserDataDirectory) = 0 then
  begin
    Result := '程序不能安装在用户数据目录内。请选择单独的程序安装目录。';
    Exit;
  end;
  if DirExists(TargetDirectory + 'app_data') and
     (not FileExists(TargetDirectory + 'bk-installed.json')) then
  begin
    Result := '此目录包含便携版数据。请选择新的安装目录，原有稿件和设置会保留在原位置。';
  end;
end;
