import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Common
import qs.DCommon.Widgets
import qs.Modules.Plugins
import qs.Widgets

PluginComponent {
    id: root

    // --- 配置 ---
    readonly property bool notificationsEnabled: pluginData.enableNotifications ?? true

    // --- 存储 ---
    readonly property string storageDir: (Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")) + "/dms-todoReminder"
    readonly property string storageFile: storageDir + "/todos.json"

    // --- 状态 ---
    property var todos: []
    property string currentDate: dateKey()

    // --- 工具函数 ---
    function pad2(n) {
        return n < 10 ? ("0" + n) : String(n)
    }

    function dateKey(d) {
        const dt = d || new Date()
        return dt.getFullYear() + "-" + pad2(dt.getMonth() + 1) + "-" + pad2(dt.getDate())
    }

    function addDaysKey(days) {
        const d = new Date()
        d.setDate(d.getDate() + days)
        return dateKey(d)
    }

    function uid() {
        return Date.now().toString(36) + Math.random().toString(36).substring(2, 8)
    }

    function validDate(s) {
        if (!/^\d{4}-\d{2}-\d{2}$/.test(s))
            return false
        const d = new Date(s + "T00:00:00")
        return !isNaN(d.getTime()) && dateKey(d) === s
    }

    function validTime(s) {
        if (!/^\d{2}:\d{2}$/.test(s))
            return false
        const p = s.split(":")
        return (+p[0] < 24 && +p[1] < 60)
    }

    function isDoneToday(t) {
        return t.done && t.lastDoneDate === root.currentDate
    }

    function isOverdue(t) {
        return !t.repeat && !t.done && t.date !== "" && t.date < root.currentDate
    }

    // --- 今日列表 ---
    readonly property var todayTodos: {
        const list = root.todos.filter(function(t) {
            if (t.repeat)
                return true
            if (t.done)
                return t.lastDoneDate === root.currentDate
            return true
        })
        list.sort(function(a, b) {
            const da = root.isDoneToday(a)
            const db = root.isDoneToday(b)
            if (da !== db)
                return da ? 1 : -1
            if (a.time !== b.time) {
                if (a.time === "")
                    return 1
                if (b.time === "")
                    return -1
                return a.time < b.time ? -1 : 1
            }
            return a.createdAt < b.createdAt ? -1 : 1
        })
        return list
    }

    readonly property int activeCount: {
        let n = 0
        for (let i = 0; i < todayTodos.length; i++) {
            if (!isDoneToday(todayTodos[i]))
                n++
        }
        return n
    }

    readonly property int doneTodayCount: todayTodos.length - activeCount

    // --- 数据操作 ---
    function addTask(text, date, time, repeat) {
        text = String(text || "").trim()
        if (!text)
            return false
        if (time !== "" && !validTime(time))
            return false
        if (repeat)
            date = ""
        else if (time !== "" && date === "")
            date = currentDate
        if (date !== "" && !validDate(date))
            return false
        const list = todos.slice()
        list.push({
            id: uid(),
            text: text.substring(0, 500),
            date: date,
            time: time,
            repeat: Boolean(repeat),
            done: false,
            lastDoneDate: "",
            notifiedKey: "",
            createdAt: new Date().toISOString()
        })
        todos = list
        saveTodos()
        return true
    }

    function toggleTask(id) {
        const list = todos.slice()
        for (let i = 0; i < list.length; i++) {
            if (list[i].id === id) {
                const t = Object.assign({}, list[i])
                t.done = !t.done
                t.lastDoneDate = t.done ? currentDate : ""
                list[i] = t
                break
            }
        }
        todos = list
        saveTodos()
    }

    function removeTask(id) {
        todos = todos.filter(function(t) {
            return t.id !== id
        })
        saveTodos()
    }

    function clearCompletedToday() {
        todos = todos.filter(function(t) {
            return !isDoneToday(t)
        })
        saveTodos()
    }

    // 跨天处理：每日任务重置完成态，非循环已完成任务清理
    function applyRollover(today) {
        let changed = false
        const kept = []
        for (let i = 0; i < todos.length; i++) {
            const t = todos[i]
            if (t.repeat) {
                if (t.done && t.lastDoneDate !== today) {
                    const nt = Object.assign({}, t)
                    nt.done = false
                    kept.push(nt)
                    changed = true
                    continue
                }
            } else if (t.done && t.lastDoneDate !== today) {
                changed = true
                continue
            }
            kept.push(t)
        }
        if (changed)
            todos = kept
        return changed
    }

    // --- 到点提醒 ---
    function notify(title, body) {
        const safe = function(s) {
            return String(s).replace(/'/g, "'\\''").substring(0, 400)
        }
        notifyProcess.command = ["sh", "-c", 'if command -v dms >/dev/null 2>&1; then dms notify -u critical -t 0 \'' + safe(title) + '\' \'' + safe(body) + '\' --app "Todo Reminder" --icon "event_available"; elif command -v notify-send >/dev/null 2>&1; then notify-send -u critical -t 0 -a "Todo Reminder" -i event_available \'' + safe(title) + '\' \'' + safe(body) + '\'; fi']
        notifyProcess.running = true
    }

    function checkNotifications() {
        if (!notificationsEnabled)
            return
        const now = new Date()
        const nowKey = dateKey(now)
        let changed = false
        const list = todos.slice()
        for (let i = 0; i < list.length; i++) {
            const t = list[i]
            if (!t.time || t.done)
                continue
            const dueToday = t.repeat ? true : (t.date === nowKey)
            const key = (t.repeat ? nowKey : t.date) + " " + t.time
            if (!dueToday || t.notifiedKey === key)
                continue
            const scheduled = new Date(nowKey + "T" + t.time + ":00")
            if (now.getTime() < scheduled.getTime())
                continue
            t.notifiedKey = key
            changed = true
            // 错过超过 30 分钟只补标记，不再打扰
            if (now.getTime() - scheduled.getTime() <= 30 * 60 * 1000)
                notify("待办提醒", t.text + "（" + t.time + "）")
        }
        if (changed) {
            todos = list
            saveTodos()
        }
    }

    // --- 持久化 ---
    function saveTodos() {
        todoFile.setText(JSON.stringify({
            version: 1,
            todos: todos
        }, null, 2))
    }

    function reloadTodos() {
        Quickshell.execDetached(["mkdir", "-p", storageDir])
        todoFile.reload()
    }

    FileView {
        id: todoFile
        path: root.storageFile
        watchChanges: false
        blockWrites: false
        atomicWrites: true
        printErrors: false

        onLoaded: {
            let parsed = null
            try {
                parsed = JSON.parse(text())
            } catch (_) {
                parsed = null
            }
            const raw = parsed && Array.isArray(parsed.todos) ? parsed.todos : []
            const clean = []
            const seen = new Set()
            for (let i = 0; i < raw.length; i++) {
                const t = raw[i]
                if (!t || typeof t.text !== "string" || !t.text.trim())
                    continue
                let id = t.id || root.uid()
                while (seen.has(id))
                    id = root.uid()
                seen.add(id)
                clean.push({
                    id: id,
                    text: t.text.substring(0, 500),
                    date: (typeof t.date === "string" && root.validDate(t.date)) ? t.date : "",
                    time: (typeof t.time === "string" && root.validTime(t.time)) ? t.time : "",
                    repeat: Boolean(t.repeat),
                    done: Boolean(t.done),
                    lastDoneDate: (typeof t.lastDoneDate === "string" && root.validDate(t.lastDoneDate)) ? t.lastDoneDate : "",
                    notifiedKey: typeof t.notifiedKey === "string" ? t.notifiedKey : "",
                    createdAt: t.createdAt || new Date().toISOString()
                })
            }
            root.todos = clean
            root.currentDate = root.dateKey()
            if (root.applyRollover(root.currentDate))
                root.saveTodos()
        }
    }

    Component.onCompleted: reloadTodos()

    // --- 后台定时器：跨天重置 + 到点提醒 ---
    Timer {
        interval: 10000
        repeat: true
        running: true
        onTriggered: {
            const today = root.dateKey()
            if (today !== root.currentDate) {
                root.currentDate = today
                if (root.applyRollover(today))
                    root.saveTodos()
            }
            root.checkNotifications()
        }
    }

    Process {
        id: notifyProcess
        running: false
    }

    // --- 横条 Pill ---
    horizontalBarPill: Component {
        Row {
            spacing: Theme.spacingXS
            anchors.verticalCenter: parent ? parent.verticalCenter : undefined

            DIcon {
                name: root.activeCount > 0 ? "checklist" : "check_circle"
                size: root.iconSize
                color: root.activeCount > 0 ? Theme.primary : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }

            StyledText {
                text: String(root.activeCount)
                font.pixelSize: root.textSize
                font.weight: Font.Medium
                color: root.activeCount > 0 ? Theme.surfaceText : Theme.surfaceVariantText
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    // --- 竖条 Pill ---
    verticalBarPill: Component {
        Column {
            spacing: Theme.spacingXS
            anchors.horizontalCenter: parent ? parent.horizontalCenter : undefined

            DIcon {
                name: root.activeCount > 0 ? "checklist" : "check_circle"
                size: root.iconSize
                color: root.activeCount > 0 ? Theme.primary : Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }

            StyledText {
                text: String(root.activeCount)
                font.pixelSize: root.textSize
                font.weight: Font.Medium
                color: root.activeCount > 0 ? Theme.surfaceText : Theme.surfaceVariantText
                anchors.horizontalCenter: parent.horizontalCenter
            }
        }
    }

    popoutWidth: 380

    // --- 弹出面板 ---
    popoutContent: Component {
        PopoutComponent {
            id: popout

            // 弹窗打开/关闭时收起日期时间面板与添加选项
            onVisibleChanged: {
                if (!visible) {
                    composerOptions.visible = false
                    calendarPanel.visible = false
                    timePanel.visible = false
                }
            }

            Connections {
                target: root

                function onInteractionActiveChanged() {
                    if (root.interactionActive) {
                        composerOptions.visible = false
                        calendarPanel.visible = false
                        timePanel.visible = false
                    }
                }
            }

            width: parent ? parent.width : 0
            headerText: "待办清单"
            detailsText: root.todayTodos.length === 0 ? "今日暂无任务" : (root.activeCount + " 项待办 · " + root.doneTodayCount + " 已完成")

            Column {
                id: popoutColumn
                width: parent.width
                spacing: Theme.spacingM

                // --- 添加任务区 ---
                Column {
                    id: composerColumn
                    width: parent.width
                    spacing: Theme.spacingS
                    property string dateValue: ""
                    property string timeValue: ""

                    // 输入行
                    Item {
                        width: parent.width
                        height: 44

                        DTextField {
                            id: addInput
                            anchors.left: parent.left
                            anchors.right: optionsButton.left
                            anchors.rightMargin: Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            placeholderText: "添加任务，回车确认…"
                            maximumLength: 500
                            onAccepted: {
                                composerColumn.submitComposer()
                                forceActiveFocus()
                            }
                            Keys.onEscapePressed: text = ""
                        }

                        Rectangle {
                            id: optionsButton
                            width: 36
                            height: 36
                            radius: Theme.cornerRadius
                            anchors.right: addButton.left
                            anchors.rightMargin: Theme.spacingXS
                            anchors.verticalCenter: parent.verticalCenter
                            color: optionsArea.containsMouse ? Theme.surfaceContainerHighest : (composerOptions.visible ? Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.18) : Theme.surfaceContainerHigh)

                            DIcon {
                                anchors.centerIn: parent
                                name: composerOptions.visible ? "expand_less" : "tune"
                                size: 18
                                color: composerOptions.visible ? Theme.primary : Theme.surfaceVariantText
                            }

                            MouseArea {
                                id: optionsArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: composerOptions.visible = !composerOptions.visible
                            }
                        }

                        Rectangle {
                            id: addButton
                            width: 36
                            height: 36
                            radius: Theme.cornerRadius
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            color: addArea.containsMouse ? Theme.primary : Qt.rgba(Theme.primary.r, Theme.primary.g, Theme.primary.b, 0.2)

                            DIcon {
                                anchors.centerIn: parent
                                name: "add"
                                size: 20
                                color: addArea.containsMouse ? Theme.onPrimary : Theme.primary
                            }

                            MouseArea {
                                id: addArea
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: {
                                    composerColumn.submitComposer()
                                    addInput.forceActiveFocus()
                                }
                            }
                        }
                    }

                    function submitComposer() {
                        if (root.addTask(addInput.text, dateValue, timeValue, repeatCheck.checked))
                            addInput.text = ""
                    }

                    // 日期 / 时间 / 每日循环选项
                    Rectangle {
                        id: composerOptions
                        width: parent.width
                        height: optionsColumn.implicitHeight + (calendarPanel.visible ? calendarPanel.height + Theme.spacingS : 0) + (timePanel.visible ? timePanel.height + Theme.spacingS : 0) + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerLow
                        visible: false

                        Column {
                            id: optionsColumn
                            anchors.top: parent.top
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            // 日期行
                            Row {
                                spacing: Theme.spacingS

                                StyledText {
                                    text: "日期"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Rectangle {
                                    width: 120
                                    height: 32
                                    radius: Theme.cornerRadius
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: dateBtnArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                                    border.width: composerColumn.dateValue !== "" ? 1 : 0
                                    border.color: Theme.primary

                                    Row {
                                        anchors.centerIn: parent
                                        spacing: Theme.spacingXS

                                        DIcon {
                                            name: "calendar_month"
                                            size: 14
                                            color: composerColumn.dateValue !== "" ? Theme.primary : Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: composerColumn.dateValue !== "" ? composerColumn.dateValue : "选择日期"
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: composerColumn.dateValue !== "" ? Font.Medium : Font.Normal
                                            color: composerColumn.dateValue !== "" ? Theme.primary : Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }

                                    MouseArea {
                                        id: dateBtnArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            timePanel.visible = false
                                            calendarPanel.visible = !calendarPanel.visible
                                        }
                                    }
                                }

                                Repeater {
                                    model: [
                                        {
                                            label: "今天",
                                            key: 0
                                        },
                                        {
                                            label: "明天",
                                            key: 1
                                        }
                                    ]

                                    Rectangle {
                                        width: 44
                                        height: 32
                                        radius: Theme.cornerRadius
                                        anchors.verticalCenter: parent.verticalCenter
                                        color: dateChipArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                                        StyledText {
                                            anchors.centerIn: parent
                                            text: modelData.label
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceText
                                        }

                                        MouseArea {
                                            id: dateChipArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                composerColumn.dateValue = root.addDaysKey(modelData.key)
                                                calendarPanel.visible = false
                                                timePanel.visible = false
                                            }
                                        }
                                    }
                                }

                                Rectangle {
                                    width: 44
                                    height: 32
                                    radius: Theme.cornerRadius
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: dateClearArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                                        StyledText {
                                            anchors.centerIn: parent
                                            text: "清除"
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                        }

                                        MouseArea {
                                            id: dateClearArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: {
                                                composerColumn.dateValue = ""
                                                calendarPanel.visible = false
                                                timePanel.visible = false
                                            }
                                        }
                                }
                            }

                            // 时间行
                            Row {
                                spacing: Theme.spacingS

                                StyledText {
                                    text: "时间"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                Rectangle {
                                    width: 120
                                    height: 32
                                    radius: Theme.cornerRadius
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: timeBtnArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh
                                    border.width: composerColumn.timeValue !== "" ? 1 : 0
                                    border.color: Theme.primary

                                    Row {
                                        anchors.centerIn: parent
                                        spacing: Theme.spacingXS

                                        DIcon {
                                            name: "schedule"
                                            size: 14
                                            color: composerColumn.timeValue !== "" ? Theme.primary : Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: composerColumn.timeValue !== "" ? composerColumn.timeValue : "选择时间"
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: composerColumn.timeValue !== "" ? Font.Medium : Font.Normal
                                            color: composerColumn.timeValue !== "" ? Theme.primary : Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }

                                    MouseArea {
                                        id: timeBtnArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            if (!timePanel.visible) {
                                                const parts = composerColumn.timeValue !== "" ? composerColumn.timeValue.split(":") : [String(new Date().getHours()), String(new Date().getMinutes())]
                                                timePanel.h = parseInt(parts[0], 10)
                                                timePanel.m = parseInt(parts[1], 10)
                                            }
                                            calendarPanel.visible = false
                                            timePanel.visible = !timePanel.visible
                                        }
                                    }
                                }

                                Rectangle {
                                    width: 44
                                    height: 32
                                    radius: Theme.cornerRadius
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: timeClearArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: "清除"
                                        font.pixelSize: Theme.fontSizeSmall
                                        color: Theme.surfaceVariantText
                                    }

                                    MouseArea {
                                        id: timeClearArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: {
                                            composerColumn.timeValue = ""
                                            timePanel.visible = false
                                        }
                                    }
                                }

                                StyledText {
                                    text: "到点提醒"
                                    font.pixelSize: Theme.fontSizeSmall * 0.9
                                    color: Theme.surfaceVariantText
                                    opacity: 0.7
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }

                            // 每日循环
                            Row {
                                spacing: Theme.spacingS

                                Rectangle {
                                    id: repeatCheck
                                    property bool checked: false
                                    width: 22
                                    height: 22
                                    radius: 6
                                    anchors.verticalCenter: parent.verticalCenter
                                    color: checked ? Theme.primary : "transparent"
                                    border.width: 2
                                    border.color: checked ? Theme.primary : Theme.outlineVariant

                                    DIcon {
                                        anchors.centerIn: parent
                                        name: "check"
                                        size: 14
                                        color: Theme.onPrimary
                                        visible: repeatCheck.checked
                                    }

                                    MouseArea {
                                        anchors.fill: parent
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: repeatCheck.checked = !repeatCheck.checked
                                    }
                                }

                                StyledText {
                                    text: "每日循环该任务"
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceText
                                    anchors.verticalCenter: parent.verticalCenter
                                }

                                StyledText {
                                    text: "（次日自动恢复未完成，按时间每日提醒）"
                                    font.pixelSize: Theme.fontSizeSmall * 0.9
                                    color: Theme.surfaceVariantText
                                    opacity: 0.7
                                    anchors.verticalCenter: parent.verticalCenter
                                }
                            }
                        }

                        // 日历面板（点击"选择日期"展开）
                        Rectangle {
                            id: calendarPanel
                            property date displayDate: new Date()
                            property date selectedDate: new Date()
                            visible: false
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: optionsColumn.bottom
                            anchors.topMargin: Theme.spacingS
                            anchors.leftMargin: Theme.spacingM
                            anchors.rightMargin: Theme.spacingM
                            height: 240
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainer

                            function shiftMonth(delta) {
                                displayDate = new Date(displayDate.getFullYear(), displayDate.getMonth() + delta, 1)
                            }

                            Column {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingXS

                                Item {
                                    width: parent.width
                                    height: 28

                                    Rectangle {
                                        width: 28
                                        height: 28
                                        radius: Theme.cornerRadius
                                        anchors.left: parent.left
                                        color: prevMonthArea.containsMouse ? Theme.surfaceContainerHighest : "transparent"

                                        DIcon {
                                            anchors.centerIn: parent
                                            name: "chevron_left"
                                            size: 18
                                            color: Theme.surfaceVariantText
                                        }

                                        MouseArea {
                                            id: prevMonthArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: calendarPanel.shiftMonth(-1)
                                        }
                                    }

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: calendarPanel.displayDate.getFullYear() + " 年 " + (calendarPanel.displayDate.getMonth() + 1) + " 月"
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.weight: Font.Medium
                                        color: Theme.surfaceText
                                    }

                                    Rectangle {
                                        width: 28
                                        height: 28
                                        radius: Theme.cornerRadius
                                        anchors.right: parent.right
                                        color: nextMonthArea.containsMouse ? Theme.surfaceContainerHighest : "transparent"

                                        DIcon {
                                            anchors.centerIn: parent
                                            name: "chevron_right"
                                            size: 18
                                            color: Theme.surfaceVariantText
                                        }

                                        MouseArea {
                                            id: nextMonthArea
                                            anchors.fill: parent
                                            hoverEnabled: true
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: calendarPanel.shiftMonth(1)
                                        }
                                    }
                                }

                                DMonthGrid {
                                    id: pickGrid
                                    width: parent.width
                                    height: parent.height - 28 - Theme.spacingXS
                                    displayDate: calendarPanel.displayDate
                                    selectedDate: composerColumn.dateValue !== "" ? new Date(composerColumn.dateValue + "T00:00:00") : calendarPanel.selectedDate
                                    today: new Date()
                                    firstDayOfWeek: 1
                                    dayNames: ["一", "二", "三", "四", "五", "六", "日"]
                                    onDayClicked: date => {
                                        calendarPanel.selectedDate = date
                                        composerColumn.dateValue = root.dateKey(date)
                                        calendarPanel.visible = false
                                    }
                                }
                            }
                        }

                        // 时间面板（内嵌步进选择）
                        Rectangle {
                            id: timePanel
                            property int h: 9
                            property int m: 0
                            visible: false
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: optionsColumn.bottom
                            anchors.topMargin: Theme.spacingS
                            anchors.leftMargin: Theme.spacingM
                            anchors.rightMargin: Theme.spacingM
                            height: 150
                            radius: Theme.cornerRadius
                            color: Theme.surfaceContainer

                            function apply(nh, nm) {
                                h = nh
                                m = nm
                                composerColumn.timeValue = root.pad2(nh) + ":" + root.pad2(nm)
                            }

                            Column {
                                anchors.fill: parent
                                anchors.margins: Theme.spacingS
                                spacing: Theme.spacingS

                                Row {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    spacing: Theme.spacingS

                                    DNumberStepper {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: root.pad2(timePanel.h) + " 时"
                                        onIncrement: () => timePanel.apply((timePanel.h + 1) % 24, timePanel.m)
                                        onDecrement: () => timePanel.apply((timePanel.h + 23) % 24, timePanel.m)
                                    }

                                    StyledText {
                                        text: ":"
                                        font.pixelSize: Theme.fontSizeLarge
                                        color: Theme.surfaceText
                                        anchors.verticalCenter: parent.verticalCenter
                                    }

                                    DNumberStepper {
                                        anchors.verticalCenter: parent.verticalCenter
                                        text: root.pad2(timePanel.m) + " 分"
                                        onIncrement: () => timePanel.apply(timePanel.h, (timePanel.m + 5) % 60)
                                        onDecrement: () => timePanel.apply(timePanel.h, (timePanel.m + 55) % 60)
                                    }
                                }

                                // 常用时间快捷键
                                Row {
                                    anchors.horizontalCenter: parent.horizontalCenter
                                    spacing: Theme.spacingXS

                                    Repeater {
                                        model: [
                                            {
                                                label: "09:00",
                                                h: 9,
                                                m: 0
                                            },
                                            {
                                                label: "12:00",
                                                h: 12,
                                                m: 0
                                            },
                                            {
                                                label: "18:00",
                                                h: 18,
                                                m: 0
                                            },
                                            {
                                                label: "22:00",
                                                h: 22,
                                                m: 0
                                            }
                                        ]

                                        Rectangle {
                                            width: 52
                                            height: 28
                                            radius: Theme.cornerRadius
                                            anchors.verticalCenter: parent.verticalCenter
                                            color: presetArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                                            StyledText {
                                                anchors.centerIn: parent
                                                text: modelData.label
                                                font.pixelSize: Theme.fontSizeSmall
                                                color: Theme.surfaceText
                                            }

                                            MouseArea {
                                                id: presetArea
                                                anchors.fill: parent
                                                hoverEnabled: true
                                                cursorShape: Qt.PointingHandCursor
                                                onClicked: timePanel.apply(modelData.h, modelData.m)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                // --- 任务列表 ---
                Item {
                    id: listContainer
                    width: parent.width
                    height: root.todayTodos.length === 0 ? 60 : Math.min(340, Math.max(48, todoList.contentHeight + Theme.spacingXS))

                    StyledText {
                        anchors.centerIn: parent
                        visible: root.todayTodos.length === 0
                        text: "今日没有任务 ✨"
                        font.pixelSize: Theme.fontSizeMedium
                        color: Theme.surfaceVariantText
                    }

                    ListView {
                        id: todoList
                        anchors.fill: parent
                        spacing: Theme.spacingXS
                        clip: true
                        model: root.todayTodos

                        ScrollBar.vertical: ScrollBar {
                            id: todoScrollBar
                            policy: ScrollBar.AsNeeded
                            visible: todoList.contentHeight > todoList.height
                            width: 6
                            minimumSize: 0.1
                            contentItem: Rectangle {
                                radius: width / 2
                                color: Theme.primary
                                opacity: parent.pressed ? 0.9 : (parent.hovered ? 0.75 : 0.5)
                            }
                            background: Rectangle {
                                radius: width / 2
                                color: Theme.surfaceContainerHighest
                                opacity: 0.3
                            }
                        }

                        delegate: Rectangle {
                            id: taskItem
                            width: todoList.width - (todoScrollBar.visible ? (todoScrollBar.width + Theme.spacingS) : 0)
                            height: Math.max(44, taskColumn.implicitHeight + Theme.spacingS * 2)
                            radius: Theme.cornerRadius
                            color: doneToday ? Qt.rgba(Theme.surfaceContainerHigh.r, Theme.surfaceContainerHigh.g, Theme.surfaceContainerHigh.b, 0.55) : Theme.surfaceContainerHigh
                            readonly property var task: modelData
                            readonly property bool doneToday: root.isDoneToday(task)
                            readonly property bool overdue: root.isOverdue(task)

                            // 整行点击切换完成状态
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.toggleTask(taskItem.task.id)
                            }

                            Row {
                                anchors.fill: parent
                                anchors.leftMargin: Theme.spacingS
                                anchors.rightMargin: Theme.spacingXS
                                spacing: Theme.spacingS

                                // 勾选圆钮
                                Item {
                                    width: 26
                                    height: parent.height

                                    Rectangle {
                                        width: 22
                                        height: 22
                                        radius: 11
                                        anchors.centerIn: parent
                                        color: doneToday ? Theme.primary : "transparent"
                                        border.width: 2
                                        border.color: doneToday ? Theme.primary : Theme.outlineVariant

                                        DIcon {
                                            anchors.centerIn: parent
                                            name: "check"
                                            size: 15
                                            color: Theme.onPrimary
                                            visible: doneToday
                                        }
                                    }
                                }

                                // 文本与元信息
                                Column {
                                    id: taskColumn
                                    width: parent.width - 26 - 28 - Theme.spacingS * 2
                                    anchors.verticalCenter: parent.verticalCenter
                                    spacing: 2

                                    StyledText {
                                        width: parent.width
                                        text: taskItem.task.text
                                        font.pixelSize: Theme.fontSizeMedium
                                        font.strikeout: taskItem.doneToday
                                        font.weight: taskItem.doneToday ? Font.Normal : Font.Medium
                                        color: taskItem.doneToday ? Theme.surfaceVariantText : Theme.surfaceText
                                        elide: Text.ElideRight
                                        wrapMode: Text.WordWrap
                                    }

                                    Row {
                                        spacing: Theme.spacingXS
                                        visible: taskItem.task.repeat || taskItem.task.time !== "" || taskItem.task.date !== ""

                                        DIcon {
                                            name: "repeat"
                                            size: 13
                                            color: Theme.primary
                                            visible: taskItem.task.repeat
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: taskItem.task.time
                                            visible: taskItem.task.time !== ""
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                            color: taskItem.overdue ? Theme.error : (taskItem.doneToday ? Theme.surfaceVariantText : Theme.primary)
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: taskItem.task.date === root.currentDate ? "今天" : taskItem.task.date
                                            visible: !taskItem.task.repeat && taskItem.task.date !== "" && taskItem.task.date !== root.currentDate
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: "已逾期"
                                            visible: taskItem.overdue
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                            color: Theme.error
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                }

                                // 删除按钮
                                Item {
                                    width: 28
                                    height: parent.height

                                    Rectangle {
                                        width: 24
                                        height: 24
                                        radius: 12
                                        anchors.centerIn: parent
                                        color: deleteArea.containsMouse ? Theme.errorContainer : "transparent"

                                        DIcon {
                                            anchors.centerIn: parent
                                            name: "delete"
                                            size: 15
                                            color: deleteArea.containsMouse ? Theme.error : Theme.surfaceVariantText
                                        }
                                    }

                                    MouseArea {
                                        id: deleteArea
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: root.removeTask(taskItem.task.id)
                                    }
                                }
                            }

                        }
                    }
                }

                // --- 底部：清除已完成 ---
                Row {
                    width: parent.width
                    layoutDirection: Qt.RightToLeft
                    visible: root.doneTodayCount > 0

                    Rectangle {
                        width: 92
                        height: 30
                        radius: Theme.cornerRadius
                        color: clearArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                        StyledText {
                            anchors.centerIn: parent
                            text: "清除已完成"
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceVariantText
                        }

                        MouseArea {
                            id: clearArea
                            anchors.fill: parent
                            hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor
                            onClicked: root.clearCompletedToday()
                        }
                    }
                }
            }
        }
    }
}
