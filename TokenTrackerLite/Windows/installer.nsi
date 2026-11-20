Unicode true
!include "MUI2.nsh"
!include "x64.nsh"
!include "LogicLib.nsh"
!ifndef APP_VERSION
  !define APP_VERSION "0.2.2"
!endif
Name "TokenTracker Lite"
OutFile "${OUTPUT_FILE}"
InstallDir "$LOCALAPPDATA\Programs\TokenTracker Lite"
InstallDirRegKey HKCU "Software\TokenTrackerLite" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 32
VIProductVersion "0.2.2.0"
VIAddVersionKey /LANG=2052 "ProductName" "TokenTracker Lite"
VIAddVersionKey /LANG=2052 "FileDescription" "TokenTracker Lite Windows 64 位安装程序"
VIAddVersionKey /LANG=2052 "FileVersion" "${APP_VERSION}"
VIAddVersionKey /LANG=2052 "LegalCopyright" "TokenTracker — MIT License"
!define MUI_ICON "..\..\TokenTrackerWin\assets\trayicon.ico"
!define MUI_ABORTWARNING
!define MUI_FINISHPAGE_RUN "$INSTDIR\TokenTrackerLite.exe"
!define MUI_FINISHPAGE_RUN_TEXT "启动 TokenTracker Lite"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES
!insertmacro MUI_LANGUAGE "SimpChinese"

Function .onInit
  ${IfNot} ${RunningX64}
    MessageBox MB_OK|MB_ICONSTOP "此版本需要 Windows 10/11 64 位。"
    Abort
  ${EndIf}
  SetShellVarContext current
  SetRegView 64
  FindWindow $0 "" "TokenTracker Lite"
  ${If} $0 != 0
    SendMessage $0 0x804D 0 0
    Sleep 500
  ${EndIf}
FunctionEnd

Section "TokenTracker Lite" Main
  SetOutPath "$INSTDIR"
  File /r "${PUBLISH_DIR}/*"
  WriteUninstaller "$INSTDIR\Uninstall.exe"
  CreateDirectory "$SMPROGRAMS\TokenTracker Lite"
  CreateShortcut "$SMPROGRAMS\TokenTracker Lite\TokenTracker Lite.lnk" "$INSTDIR\TokenTrackerLite.exe"
  CreateShortcut "$SMPROGRAMS\TokenTracker Lite\卸载.lnk" "$INSTDIR\Uninstall.exe"
  CreateShortcut "$DESKTOP\TokenTracker Lite.lnk" "$INSTDIR\TokenTrackerLite.exe"
  WriteRegStr HKCU "Software\TokenTrackerLite" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\TokenTrackerLite" "DisplayName" "TokenTracker Lite"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\TokenTrackerLite" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\TokenTrackerLite" "DisplayIcon" "$INSTDIR\TokenTrackerLite.exe"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\TokenTrackerLite" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\TokenTrackerLite" "UninstallString" '$\"$INSTDIR\Uninstall.exe$\"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\TokenTrackerLite" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\TokenTrackerLite" "NoRepair" 1
SectionEnd

Function un.onInit
  SetShellVarContext current
  SetRegView 64
  FindWindow $0 "" "TokenTracker Lite"
  ${If} $0 != 0
    SendMessage $0 0x804D 0 0
    Sleep 500
  ${EndIf}
FunctionEnd
Section "Uninstall"
  Delete "$DESKTOP\TokenTracker Lite.lnk"
  RMDir /r "$SMPROGRAMS\TokenTracker Lite"
  RMDir /r "$INSTDIR"
  DeleteRegKey HKCU "Software\TokenTrackerLite"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\TokenTrackerLite"
SectionEnd
