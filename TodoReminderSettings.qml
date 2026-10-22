import QtQuick
import Quickshell
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root

    pluginId: "todoReminder"

    StyledText {
        width: parent.width
        text: "待办提醒设置"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "待办清单小组件：快速勾选、每日循环、定时提醒"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    Rectangle {
        width: parent.width
        height: settingsColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: settingsColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingS

            ToggleSetting {
                label: "到点提醒通知"
                description: "带有时间标记的任务到达时间时，通过系统通知提醒（优先使用 dms notify，回退 notify-send）"
                settingKey: "enableNotifications"
                defaultValue: true
            }
        }
    }

    StyledText {
        width: parent.width
        text: "任务数据保存在 " + (Quickshell.env("XDG_DATA_HOME") || (Quickshell.env("HOME") + "/.local/share")) + "/dms-todoReminder/todos.json"
        font.pixelSize: Theme.fontSizeSmall * 0.9
        color: Theme.surfaceVariantText
        opacity: 0.7
        wrapMode: Text.WordWrap
    }
}
