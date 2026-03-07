import Quickshell
import QtQuick
import qs.Common
import qs.Modules.Plugins
import qs.Widgets

PluginSettings {
    id: root
    pluginId: "musicLyrics"

    StyledText {
        width: parent.width
        text: "Music Lyrics Settings"
        font.pixelSize: Theme.fontSizeLarge
        font.weight: Font.Bold
        color: Theme.surfaceText
    }

    StyledText {
        width: parent.width
        text: "Configure lyrics sources and behavior"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StyledRect {
        width: parent.width
        height: durationsColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: durationsColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "Cache"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            ToggleSetting {
                settingKey: "cachingEnabled"
                label: "Local Cache"
                description: "Save downloaded lyrics locally to speed up loading times and reduce network requests."
                defaultValue: true
            }

            StringSetting {
                settingKey: "lyricsDirectory"
                label: "Lyrics Directory"
                description: "Directory used to store cached lyrics files."
                placeholder: "$HOME/.cache/musicLyrics"
                defaultValue: "$HOME/.cache/musicLyrics"
            }
        }
    }

    StyledRect {
        width: parent.width
        height: interactionColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: interactionColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "Interaction"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            SelectionSetting {
                settingKey: "statusPaneButton"
                label: "Lyrics Status"
                description: "Mouse button for the default status pane."
                defaultValue: "left"
                options: [
                    { label: "Disabled", value: "disabled" },
                    { label: "Left click", value: "left" },
                    { label: "Right click", value: "right" },
                    { label: "Middle click", value: "middle" }
                ]
            }

            SelectionSetting {
                settingKey: "lyricsPaneButton"
                label: "Lyrics"
                description: "Mouse button for the lyrics pane."
                defaultValue: "right"
                options: [
                    { label: "Disabled", value: "disabled" },
                    { label: "Left click", value: "left" },
                    { label: "Right click", value: "right" },
                    { label: "Middle click", value: "middle" }
                ]
            }
        }
    }

    StyledRect {
        width: parent.width
        height: behaviorColumn.implicitHeight + Theme.spacingL * 2
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: behaviorColumn
            anchors.fill: parent
            anchors.margins: Theme.spacingL
            spacing: Theme.spacingM

            StyledText {
                text: "Navidrome"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Medium
                color: Theme.surfaceText
            }

            StringSetting {
                settingKey: "navidromeUrl"
                label: "Server URL"
                description: "The full address of your instance."
                placeholder: "https://music.example.com:4533"
                defaultValue: ""
            }

            StringSetting {
                settingKey: "navidromeUser"
                label: "Username"
                placeholder: "username"
                defaultValue: ""
            }

            StringSetting {
                settingKey: "navidromePassword"
                label: "Password"
                placeholder: "password"
                defaultValue: ""
            }
        }
    }
}
