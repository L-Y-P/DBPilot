-- ============================================================================
--  tools/perf/ui_automation/lib.applescript
--  DBPilot macOS UI 自动化基础库（AppleScript + System Events）。
--
--  为什么用 AppleScript 而不是纯 CUA：
--    * CUA 能驱动大部分控件，但 Flutter 自绘的文本输入框（SQL 编辑器）
--      收不到后台投递的按键；
--    * AppleScript 走系统级 HID 事件，是唯一能真正往 Flutter 输入框打字的路径；
--    * 滚动帧率不在本文件采集，用应用内的 FrameTiming 采样
--      （DBPILOT_FRAME_TRACE=1，见 docs/UI_AUTOMATION_TESTING.md）。
--
--  注意：不要用 `load script` 加载本文件（/tmp 是符号链接会让路径解析失败）。
--  正确用法是把它拼进一个完整脚本再 osascript 执行 —— 见 run_ui_perf.sh。
-- ============================================================================

-- 激活 DBPilot 并返回它的窗口原点 {x, y}。
on activateApp()
    tell application "System Events"
        tell process "DBPilot"
            set frontmost to true
            delay 0.3
            set p to position of window 1
        end tell
    end tell
    return p
end activateApp

-- 按 label 点击一个 AXButton（Flutter 的按钮大多暴露了 label）。
on clickButton(labelText)
    tell application "System Events"
        tell process "DBPilot"
            set frontmost to true
            try
                click button labelText of window 1
                return true
            on error
                return false
            end try
        end tell
    end tell
end clickButton

-- 读取窗口内所有静态文本（用于断言/计时）。
on staticTexts()
    tell application "System Events"
        tell process "DBPilot"
            set out to {}
            try
                repeat with t in (every static text of window 1)
                    set end of out to (value of t as text)
                end repeat
            end try
            return out
        end tell
    end tell
end staticTexts

-- 等待某个静态文本出现（返回 true/false）。
on waitForText(needle, timeoutSec)
    set deadline to (current date) + timeoutSec
    repeat
        set texts to my staticTexts()
        repeat with t in texts
            if (t as text) contains needle then return true
        end repeat
        if (current date) > deadline then return false
        delay 0.2
    end repeat
end waitForText

-- 在 SQL 编辑器里写入 SQL。
--
-- 已知限制（实测）：直接 keystroke 会被 macOS 输入法污染
-- （空格丢失、插入中文字符），所以改用剪贴板粘贴。
on setSqlEditor(sqlText)
    set the clipboard to sqlText
    tell application "System Events"
        tell process "DBPilot"
            set frontmost to true
            delay 0.2
            try
                set focused of text field 1 of group 1 of group 1 of group 1 of group 2 of group 1 of window 1 to true
            end try
            delay 0.2
            keystroke "a" using command down
            delay 0.1
            keystroke "v" using command down
            delay 0.3
        end tell
    end tell
end setSqlEditor

-- 执行当前 SQL（点「执行」按钮）。
on runSql()
    return my clickButton("执行")
end runSql

-- 进程 PID。
on appPid()
    try
        return do shell script "pgrep -f 'DBPilot.app/Contents/MacOS/DBPilot' | head -1"
    on error
        return ""
    end try
end appPid

-- 进程 RSS（KB）。
on rssKb(pidText)
    try
        return (do shell script "ps -o rss= -p " & pidText) as integer
    on error
        return 0
    end try
end rssKb