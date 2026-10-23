; ============================================================================
;  DBPilot Windows 安装包（NSIS）
;
;  用法（CI 与本地一致）：
;    makensis /DVERSION=1.0.0 /DSRCDIR=build\windows\x64\runner\Release \
;             /DOUTFILE=DBPilot-1.0.0-windows-x64-setup.exe packaging\windows\installer.nsi
;
;  必需参数：
;    VERSION    版本号（不带 v，例如 1.0.0）
;    SRCDIR     flutter build windows --release 的产物目录
;    OUTFILE    生成的安装包路径
;
;  可选参数：
;    APP_ICON   安装包与卸载项图标（默认用 runner 里的 app_icon.ico）
;
;  设计取舍：
;    * 默认装到 Program Files（需要管理员权限），但允许用户改目录；
;    * 卸载时保留用户数据（%APPDATA%\com.rustmyadmin\DBPilot），
;      避免升级/重装把连接配置删掉；
;    * 安装包本身不携带任何用户数据，只装程序文件。
; ============================================================================

Unicode true

!ifndef VERSION
  !error "缺少 /DVERSION=<版本号>"
!endif
!ifndef SRCDIR
  !error "缺少 /DSRCDIR=<Release 产物目录>"
!endif
!ifndef OUTFILE
  !error "缺少 /DOUTFILE=<输出安装包路径>"
!endif

; makensis 按**脚本所在目录**解析相对路径（不是当前工作目录），
; 而脚本位于 packaging/windows/ 下，所以仓库根是 ../..。
; 图标与许可证都走这个前缀，避免 CI 里 CWD 不同导致的找不到文件。
!define REPO_ROOT       "..\.."

!define APP_NAME        "DBPilot"
!define APP_PUBLISHER   "L-Y-P"
!define APP_URL         "https://github.com/L-Y-P/DBPilot"
!define APP_EXE         "DBPilot.exe"
!define UNINST_KEY      "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\DBPilot"
!define REG_APP_PATH    "Software\\DBPilot"

Name "${APP_NAME} ${VERSION}"
OutFile "${OUTFILE}"
BrandingText "${APP_NAME} ${VERSION}"

; 安装目录：默认 Program Files，允许用户修改。
InstallDir "$PROGRAMFILES64\\${APP_NAME}"
InstallDirRegKey HKLM "${REG_APP_PATH}" "InstallDir"
RequestExecutionLevel admin

; 压缩：LZMA 字典 32MB，兼顾体积与解压速度（产物约 40-60MB）。
SetCompressor /SOLID lzma
SetCompressorDictSize 32

VIProductVersion "${VERSION}.0"
VIAddVersionKey /LANG=2052 "ProductName"     "${APP_NAME}"
VIAddVersionKey /LANG=2052 "CompanyName"     "${APP_PUBLISHER}"
VIAddVersionKey /LANG=2052 "FileDescription" "${APP_NAME} 安装程序"
VIAddVersionKey /LANG=2052 "FileVersion"     "${VERSION}"
VIAddVersionKey /LANG=2052 "ProductVersion"  "${VERSION}"
VIAddVersionKey /LANG=2052 "LegalCopyright"  "MIT License"

; ---------------------------------------------------------------- 界面 ----
!include "MUI2.nsh"
!include "FileFunc.nsh"

!define MUI_ABORTWARNING
; 未显式传 /DAPP_ICON 时用 runner 里的图标（相对 REPO_ROOT，绝对可靠）。
!ifndef APP_ICON
  !define APP_ICON "${REPO_ROOT}\windows\runner\resources\app_icon.ico"
!endif

!define MUI_ICON "${APP_ICON}"
!define MUI_UNICON "${APP_ICON}"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "${REPO_ROOT}\LICENSE"
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

; ---------------------------------------------------------------- 安装 ----
Section "Install"
  SetOutPath "$INSTDIR"

  ; 整个 Release 目录：exe + dll + data/（含 flutter_assets 与 AOT 库）。
  File /r "${SRCDIR}\\*.*"

  ; 开始菜单与桌面快捷方式。
  CreateDirectory "$SMPROGRAMS\\${APP_NAME}"
  CreateShortCut "$SMPROGRAMS\\${APP_NAME}\\${APP_NAME}.lnk" "$INSTDIR\\${APP_EXE}"
  CreateShortCut "$SMPROGRAMS\\${APP_NAME}\\卸载 ${APP_NAME}.lnk" "$INSTDIR\\uninstall.exe"
  CreateShortCut "$DESKTOP\\${APP_NAME}.lnk" "$INSTDIR\\${APP_EXE}"

  ; 卸载程序与注册表项。
  WriteUninstaller "$INSTDIR\\uninstall.exe"
  WriteRegStr HKLM "${REG_APP_PATH}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayName"     "${APP_NAME}"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayVersion"  "${VERSION}"
  WriteRegStr HKLM "${UNINST_KEY}" "Publisher"       "${APP_PUBLISHER}"
  WriteRegStr HKLM "${UNINST_KEY}" "URLInfoAbout"    "${APP_URL}"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon"     "$INSTDIR\\${APP_EXE}"
  WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\\uninstall.exe"'
  WriteRegStr HKLM "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\\uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1

  ; 让「应用和功能」显示真实占用空间。
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "${UNINST_KEY}" "EstimatedSize" "$0"
SectionEnd

; ---------------------------------------------------------------- 卸载 ----
Section "Uninstall"
  ; 先关掉正在运行的实例，否则删不掉 exe/dll。
  ExecWait 'taskkill /F /IM ${APP_EXE}'

  Delete "$DESKTOP\\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\\${APP_NAME}\\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\\${APP_NAME}\\卸载 ${APP_NAME}.lnk"
  RMDir  "$SMPROGRAMS\\${APP_NAME}"

  ; 删程序目录（RMDir /r 会把 data/ 与 dll 一起删掉）。
  RMDir /r "$INSTDIR"

  DeleteRegKey HKLM "${UNINST_KEY}"
  DeleteRegKey HKLM "${REG_APP_PATH}"

  ; 用户数据（连接配置、查询历史、备份）默认保留，避免重装后连接丢失。
  ; 需要彻底清空时手动删除：%APPDATA%\\com.rustmyadmin\\DBPilot
SectionEnd

Function .onInit
  ; 已经装过就提示升级，直接覆盖安装。
  ReadRegStr $0 HKLM "${REG_APP_PATH}" "InstallDir"
  ${If} $0 != ""
    StrCpy $INSTDIR $0
  ${EndIf}
FunctionEnd
