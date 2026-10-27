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
;    * 卸载时**询问**是否一并删除用户数据（%APPDATA%\com.rustmyadmin\DBPilot），
;      默认答案是"否"=保留，避免升级/重装把连接配置删掉；
;    * 静默卸载（/S，也就是「应用和功能」里的 QuietUninstallString）不弹窗、
;      且安全默认保留数据；真要连数据一起清掉，显式加 /DELETEUSERDATA：
;        "$INSTDIR\uninstall.exe" /S /DELETEUSERDATA
;    * 安装包本身不携带任何用户数据，只装程序文件。
;
;  真机验证记录（第 78 轮，Windows 10 19045 + NSIS 3.13）：
;    * 本脚本原先在真机上**根本编不过**：${GetShortPathName} 不是 NSIS 提供的宏，
;      makensis 直接 "Invalid command" 中止 —— 之前几轮只做了静态核对没发现；
;    * 静默安装时 /D=<目录> 只在启动参数**最后一个**、且不带引号时才生效，
;      这是 NSIS 本身的规则，不是本脚本的 bug（本次验证按此规则用 /D=）。
;
;  可以商榷的一点：用户数据目录取的是"当前用户"的 %APPDATA%。安装包本身
;  RequestExecutionLevel admin，卸载时如果弹了 UAC，uninstall.exe 进程的
;  %APPDATA% 有可能指向提权后的管理员账户。真出现这种情况时：
;    - 检测不到用户数据 → 不弹窗，不删任何东西（只是少一个提示）；
;    - 用户选"是" → 删的是管理员账户下的同名目录，普通用户的数据仍在。
;  两种结果都不会误删普通用户的数据。要彻底对准原安装者，需要先读它的 SID
;  再拼路径，超出本次需求范围，先不动。
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
!define UNINST_KEY      "Software\Microsoft\Windows\CurrentVersion\Uninstall\DBPilot"
!define REG_APP_PATH    "Software\DBPilot"

; 用户数据目录（与 Rust 侧 secure.rs / docs/USAGE.md 的路径一致）：
;   $APPDATA(= %APPDATA% = C:\Users\<用户>\AppData\Roaming)\com.rustmyadmin\DBPilot
; 父目录只作"空了就顺手删掉"用，所以单独定义。
!define USER_DATA_DIR   "$APPDATA\com.rustmyadmin\DBPilot"
!define USER_DATA_ROOT  "$APPDATA\com.rustmyadmin"

; MessageBox 的返回值。NSIS 的 WinMessages.nsh 里定义的是 IDOK/IDCANCEL 这一组，
; 没有 IDYES/IDNO；卸载流程按需求用 StrCmp 直接比对 6/7，这里显式给出常量。
!define IDYES           6
!define IDNO            7

Name "${APP_NAME} ${VERSION}"
OutFile "${OUTFILE}"
BrandingText "${APP_NAME} ${VERSION}"

; 安装目录：默认 Program Files，允许用户修改。
InstallDir "$PROGRAMFILES64\${APP_NAME}"
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
; StrFunc.nsh 的 StrLoc / StrCase 用于逐词解析卸载参数（见 Uninstall section），
; 顺序有讲究，踩过两次坑：
;   1) 必须写在 MUI2.nsh **之前** —— StrFunc 在 !include 的位置直接生成
;      Function，等在 MUI2 之后才注册时，makensis 会把它编译进"安装段"的
;      上下文，卸载段里调用就报
;      "Call must be used with function names starting with un."；
;   2) 注册语法是 ${Using:StrFunc} <名字>，而且安装/卸载两个变体要分别注册
;      （${Using:StrFunc} StrLoc 和 ${Using:StrFunc} UnStrLoc）；只写 ${StrLoc}
;      不会生成函数，报 "Invalid command: ${StrLoc}"。
!include "StrFunc.nsh"
; 只注册卸载侧变体：这两个 Str 函数只在 Uninstall 段里用，装侧函数生成了
; 也没人调，makensis 会报 warning 6010（install function not referenced）。
${Using:StrFunc} UnStrLoc
${Using:StrFunc} UnStrCase
; StrRep 用在 .onInit 里做路径反斜杠归一（安装段，注意不要用 Un 前缀）。
${Using:StrFunc} StrRep
!include "MUI2.nsh"
!include "FileFunc.nsh"

; FileFunc.nsh 提供的是**宏**，每个用到的都必须 !insertmacro 展开一次，
; 否则 makensis 报 "Invalid command: ${GetParameters}"（第 78 轮真机编译踩过）。
;   GetParameters —— 安装/卸载都要读命令行（/S、/DELETEUSERDATA、/D=）。
;   GetOptions    —— 取 /D= 后面的目录值，.onInit 与 un.onInit 都用。
!insertmacro GetParameters
!insertmacro GetOptions

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

; ---------------------------------------------------------- 卸载变量 ----
; NSIS 的自定义变量必须先 Var 声明（内置的只有 $0..$9/$R0..$R9 那一组）；
; 卸载段用到的 $un_* 全部集中在这里声明，装/卸两段共用一套名字，
; 卸载函数里再各自初始化。
Var un_deleteData   ; 1 = 一并删除用户数据
Var un_dataAsked    ; 1 = 已经弹过询问框（决定收尾要不要提示"已保留"）
Var un_short        ; %APPDATA% 的 8.3 短名，只用于存在性兜底判断
Var un_ap           ; 短名查询的输入中转（同一份缓冲区随后也当输出用）
Var un_params       ; 卸载命令行参数
Var un_silent       ; 1 = /S 静默卸载
Var un_flagDel      ; 1 = 命令行带了 /DELETEUSERDATA
Var un_exists       ; 用户数据目录存在性：1=存在 0=不存在
Var un_dataFailed   ; 1 = 想删但没删干净
Var un_instArg      ; un.onInit 里解出的 /D=<目录>

; ------------------------------------------------------------ 卸载文案 ----
; 打包器会按安装时选定的语言挑一份；两种语言都必须有值，缺一个会有编译警告/空白弹窗。
; 问句正文里已经带了程序名，正常情况下不单独用标题。
LangString UN_ASK_TITLE      ${LANG_SIMPCHINESE} "卸载 ${APP_NAME}"
LangString UN_ASK_TITLE      ${LANG_ENGLISH}     "Uninstall ${APP_NAME}"

; MB_YESNO 的两个按钮固定是"是/否"，没法改成"删除/保留"，
; 所以正文里必须把两个选项的后果各写一遍，避免用户把"否"误读成"取消卸载"。
; 另外 MessageBox 没有"标题"参数，只能传正文；下面那组 UN_*_TITLE 只作文案
; 统一定义保留，不往 MessageBox 里传。
LangString UN_ASK_TEXT       ${LANG_SIMPCHINESE} \
  "是否同时删除 ${APP_NAME} 的用户数据？$\r$\n$\r$\n\
   位置：${USER_DATA_DIR}$\r$\n$\r$\n\
   其中包含：$\r$\n\
   · 连接配置（含数据库密码）$\r$\n\
   · 查询历史$\r$\n\
   · 设置（语言、主题、备份目录等）$\r$\n\
   · backups 目录下的备份文件$\r$\n$\r$\n\
   选【是】：删除上述全部数据，无法恢复。$\r$\n\
   选【否】：保留这些数据，以后重新安装可以继续使用。$\r$\n$\r$\n\
   （卸载程序本身照常进行，与这里的选项无关。）"
LangString UN_ASK_TEXT       ${LANG_ENGLISH} \
  "Do you also want to delete ${APP_NAME} user data?$\r$\n$\r$\n\
   Location: ${USER_DATA_DIR}$\r$\n$\r$\n\
   This contains:$\r$\n\
   - Connection profiles (including database passwords)$\r$\n\
   - Query history$\r$\n\
   - Settings (language, theme, backup folder, ...)$\r$\n\
   - Backup files under the backups folder$\r$\n$\r$\n\
   Yes: delete all of the above. This cannot be undone.$\r$\n\
   No:  keep the data so a later reinstall can reuse it.$\r$\n$\r$\n\
   (The uninstall itself proceeds either way.)"

LangString UN_KEPT_TITLE     ${LANG_SIMPCHINESE} "卸载完成"
LangString UN_KEPT_TITLE     ${LANG_ENGLISH}     "Uninstall complete"

LangString UN_KEPT_TEXT      ${LANG_SIMPCHINESE} \
  "${APP_NAME} 已卸载，用户数据已保留：$\r$\n$\r$\n\
   ${USER_DATA_DIR}$\r$\n$\r$\n\
   需要彻底清理时，在文件资源管理器里删除上面这个文件夹即可。"
LangString UN_KEPT_TEXT      ${LANG_ENGLISH} \
  "${APP_NAME} has been uninstalled and your user data was kept:$\r$\n$\r$\n\
   ${USER_DATA_DIR}$\r$\n$\r$\n\
   To remove it completely, delete that folder in File Explorer."

LangString UN_DELETED_TITLE  ${LANG_SIMPCHINESE} "卸载完成"
LangString UN_DELETED_TITLE  ${LANG_ENGLISH}     "Uninstall complete"

LangString UN_DELETED_TEXT   ${LANG_SIMPCHINESE} \
  "${APP_NAME} 已卸载，用户数据已一并删除：$\r$\n$\r$\n\
   ${USER_DATA_DIR}$\r$\n$\r$\n\
   连接配置、查询历史、设置与备份文件均已删除。"
LangString UN_DELETED_TEXT   ${LANG_ENGLISH} \
  "${APP_NAME} has been uninstalled and your user data was deleted:$\r$\n$\r$\n\
   ${USER_DATA_DIR}$\r$\n$\r$\n\
   Connection profiles, query history, settings and backups are gone."

LangString UN_DATA_FAILED    ${LANG_SIMPCHINESE} \
  "以下文件夹没能完全删除，可能有文件被占用或权限不足：$\r$\n$\r$\n\
   ${USER_DATA_DIR}$\r$\n$\r$\n\
   请手动检查并删除。"
LangString UN_DATA_FAILED    ${LANG_ENGLISH} \
  "This folder could not be fully deleted (files in use or permission denied):$\r$\n$\r$\n\
   ${USER_DATA_DIR}$\r$\n$\r$\n\
   Please check and delete it manually."

; ---------------------------------------------------------------- 安装 ----
Section "Install"
  SetOutPath "$INSTDIR"

  ; 整个 Release 目录：exe + dll + data/（含 flutter_assets 与 AOT 库）。
  File /r "${SRCDIR}\*.*"

  ; 开始菜单与桌面快捷方式。
  CreateDirectory "$SMPROGRAMS\${APP_NAME}"
  CreateShortCut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"
  CreateShortCut "$SMPROGRAMS\${APP_NAME}\卸载 ${APP_NAME}.lnk" "$INSTDIR\uninstall.exe"
  CreateShortCut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${APP_EXE}"

  ; 卸载程序与注册表项。
  WriteUninstaller "$INSTDIR\uninstall.exe"

  ; NSIS 的安装包是 32 位的（输出日志里的 x86-unicode），默认注册表视图会被
  ; WOW64 重定向到 HKLM\Software\WOW6432Node。第 78 轮真机验证时发现：装完
  ; 去 HKLM\Software\<App> 查不到，只在 WOW6432Node 下 —— 用 reg query 核对、
  ; 或者以后做"检测是否已安装"的脚本，很容易被这一点误导。这里显式声明写入
  ; 64 位视图，装完在 HKLM\Software\<App> / Uninstall 下就能直接看到。
  ; 卸载段与 .onInit 也要用同一个视图，否则读/删的是另一棵树。
  SetRegView 64

  ; 先清掉**旧的 32 位视图**记录。
  ; v1.1.1 及更早的安装包没有 SetRegView，键落在 WOW6432Node 下；升级后如果
  ; 只写 64 位而留着 32 位那条，「应用和功能」两条记录里会有一条仍显示旧版本，
  ; 用户看到的就是"升级没成功"（第 79 轮真实案例：64 位显示 1.1.2、32 位显示
  ; 1.1.1，用户按后者判断）。
  SetRegView 32
  DeleteRegKey HKLM "${UNINST_KEY}"
  DeleteRegKey HKLM "${REG_APP_PATH}"
  SetRegView 64

  SetOutPath "$INSTDIR"
  WriteRegStr HKLM "${REG_APP_PATH}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayName"     "${APP_NAME}"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayVersion"  "${VERSION}"
  WriteRegStr HKLM "${UNINST_KEY}" "Publisher"       "${APP_PUBLISHER}"
  WriteRegStr HKLM "${UNINST_KEY}" "URLInfoAbout"    "${APP_URL}"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon"     "$INSTDIR\${APP_EXE}"
  WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1

  ; 让「应用和功能」显示真实占用空间。
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "${UNINST_KEY}" "EstimatedSize" "$0"
SectionEnd

; ---------------------------------------------------------------- 卸载 ----
; 关于"短名兜底"：%APPDATA% 一般已经是 C:\Users\<用户名>\AppData\Roaming，不带空格；
; 只有用户名里带空格、或路径被重定向时，才可能拿到 8.3 短形式。
; 早期版本这里写的是 ${GetShortPathName}，但那个宏**并不存在**（FileFunc.nsh 只导出
; GetSize / GetParameters / GetFileVersion 那一组），真机上 makensis 直接报
; "Invalid command: "${GetShortPathName}" 而编译失败 —— 第 78 轮真机编译时才发现并改掉。
; 现在改为直接调 kernel32::GetShortPathNameW 查一次。这里刻意**不判断调用成败**：
;   A) 查询成功 → $un_short 是短名，IfFileExists 的兜底分支能命中；
;   B) 查询失败（路径本来就短 / 卷没开 8.3）→ 不改 $un_short，此时它多半还是
;      un_ap 传进去的原值，兜底分支变成对同一个目录的重复检查，无害；
;   C) 万一内核把缓冲区改成了空串，兜底分支由 "$un_short != 空串" 的判断挡住，不会误判。
; 长名检查永远排在第一行，所以无论短名查询结果如何都不会"漏判"。
;
; 这一步放在 Section 开头做，而不是 un.onInit：un.onInit 在所有页面之前跑，
; 万一用户在那之前就取消，等于白算；放在这里也顺便保证"问"和"删"用的是
; 同一个路径基准（同一个变量，不会一半长名一半短名）。
;
; 用户数据目录是否存在：1=存在 0=不存在。
;   * 用 IfFileExists 的通配符形式（"目录里至少有一个文件"），比"目录
;     本身存在"更准：只剩一个空壳目录时不值得拿去问用户；
;   * 长名和短名各查一次，任一命中即算存在（用户目录名带空格时 %APPDATA%
;     可能返回 C:\Users\FOO~1\... 这种形式；短名只是兜底，删的时候仍按长名）；
;   * 宏内变量一律用 un_ 前缀，避免和外层 Section 的 $0/$1 撞车。
!macro DBPilot_UserDataExists RESULTVAR
  StrCpy ${RESULTVAR} 0
  IfFileExists "${USER_DATA_DIR}\*.*" 0 +2
    StrCpy ${RESULTVAR} 1
  ${If} ${RESULTVAR} == 0
  ${AndIf} $un_short != ""
    IfFileExists "$un_short\DBPilot\*.*" 0 +2
      StrCpy ${RESULTVAR} 1
  ${EndIf}
!macroend

Section "Uninstall"
  ; 先关掉正在运行的实例，否则删不掉 exe/dll。
  ExecWait 'taskkill /F /IM ${APP_EXE}'

  ; ---------------------------------------------- 先问数据，再删程序 ----
  ; 顺序很重要：
  ;   1) taskkill 之后问 —— 应用还在跑的时候删数据会留下半截文件；
  ;   2) 删快捷方式/程序目录之前问 —— 万一用户在 MUI_UNPAGE_CONFIRM
  ;      之后反悔，此时还来得及 Alt+F4 中止（中止时数据和程序都完好）。
  ; 默认按钮是"否"（MB_DEFBUTTON2）：一路回车 = 保留数据。
  StrCpy $un_deleteData 0   ; 默认：不删
  StrCpy $un_dataAsked  0   ; 0 = 没问过（静默或本来没数据），1 = 问过
  StrCpy $un_short      ""
  StrCpy $un_ap         ""
  StrCpy $un_params     ""
  StrCpy $un_silent     0
  StrCpy $un_flagDel    0
  StrCpy $un_exists     0
  StrCpy $un_dataFailed 0

  ; 先备好 8.3 短名兜底（拿不到也不影响：宏里有 $un_short != "" 的保护）。
  ; 直接用 kernel32 的 GetShortPathNameW，而不是 ${GetShortPathName}
  ; （那个宏不存在，见上面说明）。输入输出复用 $un_ap 这块缓冲区：
  ; 传进去时它是长名，调用成功后 NT 会就地改写成短名。
  ; 注意千万别写成 kernel32::GetShortPathNameW "$un_ap" "$un_short"：
  ; 那样 $un_short 会被当成输出缓冲区，任何情况下都会被 NT 写短名或写空串。
  StrCpy $un_ap "$APPDATA"
  System::Call 'kernel32::GetShortPathNameW(w "$un_ap", w "$un_ap", i ${NSIS_MAX_STRLEN}) i .r0'
  ${If} $0 > 0
    StrCpy $un_short "$un_ap"
  ${EndIf}

  ; 静默卸载（/S）不能弹窗，所以安全默认保留；只有显式 /DELETEUSERDATA 才删。
  ; 参数**逐词**比对，并且忽略大小写（Windows 命令行习惯）。
  ; 第 78 轮真机验证时踩到的坑：旧写法把整串参数前后补空格，再跟
  ; " /S /DELETEUSERDATA " 这种**完整字面量**比较 —— 只要多带任何一个参数
  ; （/NCRC、/D=...、或者顺序不同）就整体不匹配，
  ; "/S /DELETEUSERDATA /D=..." 会被当成"没带 /DELETEUSERDATA"，数据不删。
  ;   现在拆词逐个比：$0 是当前词，$1 是拆词用的中转，$2 是剩余部分。
  ;
  ; 注意不能写成 StrStr($un_params, "/S") 这种子串判断，否则 /SOMETHING 也会
  ; 被当成静默；这里按词比，天然没有这个问题。
  ${GetParameters} $un_params
  StrCpy $0 "$un_params "
  un_param_loop:
    ; 跳过前导空格（$1 = 暂存首字符；Goto 的偏移 +2 = 跳到下一条非 Goto 指令）
    StrCpy $1 $0 1
    StrCmp $1 " " 0 un_param_loop_ready
      StrCpy $0 $0 "" 1
      Goto un_param_loop
    un_param_loop_ready:
    ; 没有更多词了。
    ; 跳空格那一步必须 Goto 回 un_param_loop，不能写成 "Goto +2"：
    ; 末尾只剩空格时，=="跳过空格后直接往下走"== 会把空串当成一个词送进
    ; UnStrLoc / StrCmp。当前结果恰好无害（空词匹配不到任何开关），但以后谁在
    ; 词分支里加了 "未知参数 → 报错/中止"，这条就会立刻变成误判，故按字面改成循环。
    StrCmp $0 "" un_param_loop_done
    ; 取下一个空格位置；没有空格说明是最后一个词，用剩余长度
    ; （这条在卸载段里，必须用 Un 变体；$un_ap 当返回中转）
    ${UnStrLoc} $un_ap "$0" " " ">"
    StrCpy $2 $un_ap
    StrCmp $2 "" 0 +2
      StrLen $2 "$0"
    StrCpy $1 $0 $2                   ; $1 = 当前词
    StrCpy $0 $0 "" $2                ; $0 = 剩余部分
    ${UnStrCase} $1 "$1" ""          ; 统一小写再比（Windows 参数不分大小写）
    StrCmp $1 "/s" 0 +2
      StrCpy $un_silent 1
    StrCmp $1 "/deleteuserdata" 0 +2
      StrCpy $un_flagDel 1
    ; 其它词（/NCRC、/D=<目录> 之类）一律忽略；/D= 由 un.onInit 解析。
    ; 吃掉词后的分隔空格再继续下一轮（Goto +2 跳过循环入口的跳转，
    ; 直接落到 un_param_loop；用显式标签读写起来不容易错位）
    StrCpy $0 $0 "" 1
    Goto un_param_loop
  un_param_loop_done:

  ${If} $un_silent == 1
    ${If} $un_flagDel == 1
      StrCpy $un_deleteData 1
    ${EndIf}
  ${Else}
    ; 先判断目录是否存在：不存在就不问，免得拿一个空问题打扰用户。
    !insertmacro DBPilot_UserDataExists $un_exists

    ${If} $un_exists == 1
      MessageBox MB_YESNO|MB_ICONQUESTION|MB_DEFBUTTON2 "$(UN_ASK_TEXT)" /SD IDNO IDNO un_data_no IDYES un_data_yes

      un_data_yes:
        StrCpy $un_deleteData 1
        StrCpy $un_dataAsked  1
        Goto un_data_done

      un_data_no:
        StrCpy $un_deleteData 0
        StrCpy $un_dataAsked  1
        Goto un_data_done

      un_data_done:
    ${EndIf}
  ${EndIf}

  Delete "$DESKTOP\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
  Delete "$SMPROGRAMS\${APP_NAME}\卸载 ${APP_NAME}.lnk"
  RMDir  "$SMPROGRAMS\${APP_NAME}"

  ; 删程序目录（RMDir /r 会把 data/ 与 dll 一起删掉）。
  RMDir /r "$INSTDIR"

  ; 两个注册表视图都要删。
  ; v1.1.1 及更早的版本没有 SetRegView，键落在 WOW6432Node 下；新版写在 64 位视图。
  ; 只删一边会留下一条"幽灵卸载项"，「应用和功能」里仍显示旧版本（第 79 轮真实
  ; 案例：64 位 1.1.2 / 32 位 1.1.1 并存，用户按 32 位那条判断成"没更新"）。
  SetRegView 64
  DeleteRegKey HKLM "${UNINST_KEY}"
  DeleteRegKey HKLM "${REG_APP_PATH}"
  SetRegView 32
  DeleteRegKey HKLM "${UNINST_KEY}"
  DeleteRegKey HKLM "${REG_APP_PATH}"
  SetRegView 64

  ; ------------------------------------------------ 按上面答案处理数据 ----
  ; 程序注册表键照旧删（上面已删），用户数据是否删除只由 $un_deleteData 决定。
  ${If} $un_deleteData == 1
    ; 只删 DBPilot 自己的数据目录，不动 com.rustmyadmin 下别的东西。
    RMDir /r "${USER_DATA_DIR}"
    ; 父目录不带 /r：只有它已经空了才删，不碰任何别的内容。
    RMDir "${USER_DATA_ROOT}"

    ; 校验：还在就说明没删干净（文件被占用 / 权限不足），如实告诉用户。
    !insertmacro DBPilot_UserDataExists $un_exists
    ${If} $un_exists == 1
      StrCpy $un_dataFailed 1
    ${EndIf}
  ${EndIf}

  ; ------------------------------------------------------ 收个尾再说一声 ----
  ; 静默卸载一个提示都不弹（脚本/CI 里不该冒出模态窗口）。
  ${If} $un_silent != 1
    ${If} $un_deleteData == 1
      ${If} $un_dataFailed == 1
        MessageBox MB_OK|MB_ICONEXCLAMATION "$(UN_DATA_FAILED)"
      ${Else}
        MessageBox MB_OK|MB_ICONINFORMATION "$(UN_DELETED_TEXT)"
      ${EndIf}
    ${ElseIf} $un_dataAsked == 1
      ; 只在真的问过（数据存在且用户选了"否"）时提示保留位置；
      ; 本来就没有数据目录时再说"已保留"只会让人困惑。
      MessageBox MB_OK|MB_ICONINFORMATION "$(UN_KEPT_TEXT)"
    ${EndIf}
  ${EndIf}
SectionEnd

Function un.onInit
  ; 卸载时要判断用户数据在哪，%APPDATA% 得指向**发起卸载的用户**。
  ; 本安装包 RequestExecutionLevel admin，卸载程序会走 UAC 提权；
  ; 这里显式绑到当前用户，避免误判成管理员账户对应的目录。
  SetShellVarContext current
  SetRegView 64

  ; 卸载程序也要认 /D=<目录>：自动更新、脚本、测试都靠它把 uninstall.exe 指向
  ; 真正的安装目录；不认的话会退回去删默认位置（Program Files 下的同名目录），
  ; 那是另一次安装，属于误删。做法与 .onInit 一样：GetParameters + GetOptions。
  ; GetOptions 找不到匹配项时不改动输出变量，所以没带 /D= 时 $INSTDIR 保持原值。
  ${GetParameters} $un_params
  ${GetOptions} $un_params "/D=" $un_instArg
  ${IfNot} ${Errors}
    StrCpy $INSTDIR $un_instArg
  ${EndIf}
FunctionEnd

Function .onInit
  SetRegView 64

  ; ================================================== /D= 的真正语义 ====
  ; 第 80 轮在真机上**实测**出来的事实（别凭印象改这里）：
  ;
  ;   * 进入 .onInit 时，$INSTDIR **已经**是命令行 /D= 给的值；
  ;   * 但 ${GetParameters} / $CMDLINE 里**看不到** /D=（NSIS 在调到
  ;     .onInit 之前就把它从命令行里摘掉了）；
  ;   * .onInit 里对 $INSTDIR 的赋值会**覆盖** /D=，之后不会再被改回来。
  ;
  ; 所以三件事必须一起做才对：
  ;   1) 不能无条件 StrCpy $INSTDIR <注册表值> —— 那会把 /D= 废掉。
  ;      这正是 v1.1.1 及更早版本的 bug：自动更新传了 /D= 照样被写回
  ;      Program Files，装到别处的机器升级后出现两套程序。
  ;   2) 也不能用 ${GetOptions} $CMDLINE "/D=" 来判断 —— 拿不到，
  ;      永远走"没传 /D"的分支。
  ;   3) 正确的判断方式是拿 **$INSTDIR 的当前值**和 InstallDir 的默认值比：
  ;      相同说明用户没指定目录，才回退到注册表里的旧安装位置。
  ;
  ; 注意 InstallDir 指令给的是带引号展开后的默认值，这里用同一个表达式
  ; 重新拼一次与之比较，避免手抄路径抄错。
  StrCmp $INSTDIR "$PROGRAMFILES64\${APP_NAME}" 0 on_init_done

  ; 没传 /D=（$INSTDIR 还是默认值）：已装过就覆盖装到原位置，
  ; 这样升级不会装出第二套。
  ReadRegStr $1 HKLM "${REG_APP_PATH}" "InstallDir"
  StrCmp $1 "" 0 on_init_use_reg
  Goto on_init_norm
  on_init_use_reg:
  StrCpy $INSTDIR $1

  ; ------------------------------------------------ 路径里的重复反斜杠 ----
  ; v1.1.1 写进注册表的值是 `C:\Program Files\\DBPilot`（双反斜杠）。
  ; Win32 路径 API 会把连续反斜杠折叠掉，所以文件照样能装能跑，但注册表和
  ; 快捷方式里的字面值一直是脏的，读回来再写回去还会**继续累积**。
  ; 这里读回后立刻折叠一次，把历史脏值纠正掉。
  ; （含 /D= 的分支也走这里：用户手写的路径同样可能有重复反斜杠。）
  on_init_norm:
  ${StrRep} $INSTDIR "$INSTDIR" "\\\\\\\\" "\\\\"
  ${StrRep} $INSTDIR "$INSTDIR" "\\\\\\" "\\\\"
  ${StrRep} $INSTDIR "$INSTDIR" "\\\\" "\\"
  ; 去尾反斜杠（空串不处理）。
  StrCpy $3 $INSTDIR 1 -1
  StrCmp $3 "\\" 0 on_init_done
  StrCmp $INSTDIR "" on_init_done
  StrCpy $INSTDIR $INSTDIR -1

  on_init_done:
FunctionEnd
