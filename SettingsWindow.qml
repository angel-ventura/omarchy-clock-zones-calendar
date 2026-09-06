// Derived from the Omarchy shell's built-in clock widget (omarchy.clock),
// Copyright (c) David Heinemeier Hansson, MIT licensed.
// https://github.com/basecamp/omarchy — see LICENSE and NOTICE.

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The settings window: everything this plugin used to need a text editor for.
//
// A real toplevel window rather than a view inside the clock popup. The popup
// is capped to the width of the month grid — around 420 logical pixels — which
// is not somewhere a searchable zone picker or a pasted iCal URL can live, and
// its dropdowns have nowhere to open downward on a short screen.
//
// It is a second entry point of the same plugin ("panel" alongside
// "bar-widget"), so it is a separate QML instance from the popup and shares no
// state with it. Both ends read the same two files instead:
//
//   shell.json      the widget's own inline entry, through the shell's
//                   updateEntryInline() — the same call persistSettings() in
//                   Panel.qml already makes
//   calendars.json  through fetch-events.py, never written from QML: the 0600
//                   atomic replace belongs in one place, and the file holds a
//                   bearer token
//
// Every control writes on change. There is no Save button because there is no
// draft — the popup picks changes up the next time it opens, which is the
// contract hand-editing the files always had.
Item {
  id: root

  // Injected by the shell's panel loader.
  property var shell: null
  property var manifest: null

  property bool closing: false

  readonly property string widgetId: "angelv.clock"

  // The widget's whole shell.json entry, held as one object. updateEntryInline
  // replaces the entry wholesale rather than merging, so writing a partial one
  // here would silently drop every key this window does not know about.
  property var entry: ({})

  // calendars.json, as read back from fetch-events.py.
  property var calendars: []

  property var zoneList: []

  // Whatever this system actually closes a window with. Asserting "Super+Q"
  // is wrong the moment somebody rebinds it, and this is a window precisely so
  // that the key works on it -- so it is worth getting right rather than
  // guessing. Empty until read, and the footer says "your close-window key"
  // until then.
  property string tab: "calendars"

  // Fixed when the overlay opens, not bound -- see the screen note on the
  // PanelWindow below.
  property var openedOn: null
  property int cardWidth: 760
  property int cardHeight: 700

  // Nothing is written while this is false.
  //
  // The shell's controls emit their change signal while their bindings settle,
  // not only when a person moves them -- opening the window once wrote
  // settings that nobody had chosen. A settings window
  // that edits the config by being looked at is worse than no settings window,
  // so writes are gated until the tree has stopped moving, and put() ignores a
  // value that already matches what is stored.
  property bool ready: false

  readonly property string pluginDir: {
    var url = String(Qt.resolvedUrl("."))
    var path = url.indexOf("file://") === 0 ? url.substring(7) : url
    return path.replace(/\/$/, "")
  }

  // Fitted to the screen it is about to open on, before it opens.
  function sizeWindow() {
    var screen = null
    if (Quickshell.screens && Quickshell.screens.length > 0) {
      // The focused screen where the shell can name one, so a second monitor
      // does not get the settings it did not ask for.
      screen = Quickshell.screens[0]
      for (var i = 0; i < Quickshell.screens.length; i++) {
        if (Quickshell.screens[i] && Quickshell.screens[i].focused) {
          screen = Quickshell.screens[i]
          break
        }
      }
    }
    root.openedOn = screen
    var sw = screen && screen.width > 0 ? screen.width : 1920
    var sh = screen && screen.height > 0 ? screen.height : 1080
    root.cardWidth = Math.max(520, Math.min(900, Math.round(sw * 0.42)))
    // 0.62 left the Calendars tab 14px short of fitting two feeds on a
    // 2048x1152 desktop -- a common enough size to be worth clearing outright
    // rather than making people scroll for the last control.
    root.cardHeight = Math.max(420, Math.min(880, Math.round(sh * 0.68)))
  }

  function open(payloadJson) {
    root.ready = false
    root.closing = false
    root.sizeWindow()
    root.loadEntry()
    root.loadCalendars()
    if (root.zoneList.length === 0) zoneListProc.running = true
    window.visible = true
    settleTimer.restart()
  }

  function close() {
    // hide() calls straight back into close(), so the re-entry has to stop
    // here rather than call hide() again: that cycle is unbounded and only
    // ended by exhausting the JS stack. The host catches the RangeError, so
    // the window still closed -- it just did it thousands of frames deep,
    // once per close.
    if (root.closing) return
    root.closing = true
    root.ready = false
    settleTimer.stop()
    window.visible = false
    try {
      // No window manager closes this one, so the host has to be told that the
      // panel is down or it will believe it is still open.
      if (root.shell && typeof root.shell.hide === "function")
        root.shell.hide(root.widgetId)
    } finally {
      root.closing = false
    }
  }

  Timer {
    id: settleTimer
    interval: 400
    onTriggered: root.ready = true
  }

  // ---- shell.json ---------------------------------------------------------

  function loadEntry() {
    var config = root.shell ? root.shell.shellConfig : null
    var found = null
    if (config && config.bar && config.bar.layout) {
      var sections = ["left", "center", "right"]
      for (var s = 0; s < sections.length && !found; s++) {
        var arr = config.bar.layout[sections[s]] || []
        for (var i = 0; i < arr.length; i++) {
          if (arr[i] && String(arr[i].id) === root.widgetId) { found = arr[i]; break }
        }
      }
    }
    // A deep copy: the shell's own config object must not be edited in place.
    root.entry = found ? JSON.parse(JSON.stringify(found)) : ({ id: root.widgetId })
  }

  function setting(name, fallback) {
    var value = root.entry ? root.entry[name] : undefined
    return (value === undefined || value === null) ? fallback : value
  }

  function isUnset(name) {
    var value = root.entry ? root.entry[name] : undefined
    return value === undefined || value === null
  }

  function put(name, value) {
    if (!root.ready) return
    // A control that re-emits its current value has nothing to say.
    var current = root.entry ? root.entry[name] : undefined
    if (JSON.stringify(current) === JSON.stringify(value)) return
    var next = JSON.parse(JSON.stringify(root.entry || {}))
    if (value === undefined) delete next[name]
    else next[name] = value
    next.id = root.widgetId
    root.entry = next
    if (root.shell && typeof root.shell.updateEntryInline === "function")
      root.shell.updateEntryInline(root.widgetId, next)
  }

  // ---- calendars.json -----------------------------------------------------

  function loadCalendars() {
    getConfigProc.buffer = ""
    getConfigProc.running = true
  }

  function saveCalendars(next) {
    if (!root.ready) return
    root.calendars = next
    saveConfigProc.running = true
  }

  function mutateCalendar(index, key, value) {
    var next = JSON.parse(JSON.stringify(root.calendars || []))
    if (index < 0 || index >= next.length) return
    next[index][key] = value
    root.saveCalendars(next)
  }

  function addCalendar() {
    var next = JSON.parse(JSON.stringify(root.calendars || []))
    next.push({ name: "New calendar", url: "", color: "#4A90E2", enabled: true })
    root.saveCalendars(next)
  }

  function removeCalendar(index) {
    var next = JSON.parse(JSON.stringify(root.calendars || []))
    if (index < 0 || index >= next.length) return
    next.splice(index, 1)
    root.saveCalendars(next)
  }

  // Clears the keys one tab owns, and nothing else. There is deliberately no
  // reset for the calendars: a feed URL is a secret that exists nowhere else
  // once this file is gone, and "reset" is not a word anyone reads carefully
  // enough to risk that on.
  readonly property var clockKeys: ["hour12", "weekStartDay"]
  readonly property var zoneKeys: ["zones", "homeName", "homeHour12"]
  readonly property var calendarKeys: ["syncIntervalMinutes", "notifyUpcomingEvents",
    "notifyMinutesBefore", "meetingHandler"]

  function resetCurrentTab() {
    if (root.tab === "clock") root.resetKeys(root.clockKeys)
    else if (root.tab === "zones") root.resetKeys(root.zoneKeys)
    else root.resetKeys(root.calendarKeys)
  }

  readonly property string resetHint: root.tab === "clock"
    ? "Reset the clock settings on this tab"
    : (root.tab === "zones" ? "Put the zone list back to the shipped default"
                            : "Reset the calendar settings on this tab — your feeds are kept")

  function resetKeys(keys) {
    if (!root.ready) return
    var next = JSON.parse(JSON.stringify(root.entry || {}))
    for (var i = 0; i < keys.length; i++) delete next[keys[i]]
    next.id = root.widgetId
    root.entry = next
    if (root.shell && typeof root.shell.updateEntryInline === "function")
      root.shell.updateEntryInline(root.widgetId, next)
  }

  // ---- zones --------------------------------------------------------------

  // A zone is stored either as a bare "Area/City" or as { tz, name } when it
  // carries a label. The popup reads both; this normalises only for editing.
  function zonesAsPairs() {
    var configured = root.setting("zones", null)
    // Unset does not mean "no zones": the popup falls back to a built-in list,
    // so this has to show the same thing or the window is describing a screen
    // that does not exist. Resetting the tab looks like it did nothing for
    // exactly this reason -- the shipped defaults are a reasonable four zones,
    // and one config's worth of zones can match them exactly.
    var zones = (configured && configured.length) ? configured : Model.normalizeZoneSetting(null)
    var out = []
    for (var i = 0; i < zones.length; i++) {
      var z = zones[i]
      if (typeof z === "string") out.push({ tz: z, name: "" })
      else out.push({ tz: String(z && z.tz ? z.tz : ""), name: String(z && z.name ? z.name : "") })
    }
    return out
  }

  function writeZones(list) {
    var out = []
    for (var i = 0; i < list.length; i++)
      out.push(list[i].name ? { tz: list[i].tz, name: list[i].name } : list[i].tz)
    root.put("zones", out)
  }

  function addZone(tz) {
    if (!tz) return
    var list = root.zonesAsPairs()
    for (var i = 0; i < list.length; i++) if (list[i].tz === tz) return
    list.push({ tz: tz, name: "" })
    root.writeZones(list)
  }

  function removeZone(index) {
    var list = root.zonesAsPairs()
    if (index < 0 || index >= list.length) return
    list.splice(index, 1)
    root.writeZones(list)
  }

  function renameZone(index, name) {
    var list = root.zonesAsPairs()
    if (index < 0 || index >= list.length) return
    list[index].name = String(name || "")
    root.writeZones(list)
  }

  // ---- processes ----------------------------------------------------------

  Process {
    id: getConfigProc
    property string buffer: ""
    command: ["python3", root.pluginDir + "/fetch-events.py", "--get-config"]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function (data) { getConfigProc.buffer += data }
    }
    onExited: function (code, status) {
      var parsed = []
      try {
        var value = JSON.parse(getConfigProc.buffer)
        if (Array.isArray(value)) parsed = value
      } catch (e) { /* an unreadable config leaves the list empty */ }
      root.calendars = parsed
    }
  }

  // The payload goes over stdin, never argv: a private iCal URL is a bearer
  // credential, and argv is readable by anything that can list /proc.
  Process {
    id: saveConfigProc
    command: ["python3", root.pluginDir + "/fetch-events.py", "--save-config"]
    stdinEnabled: true
    onStarted: {
      saveConfigProc.write(JSON.stringify(root.calendars) + "\n")
      saveConfigProc.stdinEnabled = false
    }
  }

  Process {
    id: zoneListProc
    property string buffer: ""
    command: ["timedatectl", "list-timezones"]
    stdout: SplitParser {
      splitMarker: ""
      onRead: function (data) { zoneListProc.buffer += data }
    }
    onExited: function (code, status) {
      var lines = zoneListProc.buffer.split("\n")
      var out = []
      for (var i = 0; i < lines.length; i++) {
        var line = lines[i].trim()
        if (line) out.push(line)
      }
      root.zoneList = out
    }
  }

  // ---- window -------------------------------------------------------------

  // A layer-shell overlay rather than a toplevel window.
  //
  // A real window cannot float itself: there is no Wayland request for it, and
  // Hyprland decides placement, so a toplevel tiles until somebody writes a
  // window rule. A plugin cannot ship one -- everybody installing this would
  // get a tiled settings panel until they read the README and edited their
  // Hyprland config. An overlay is centred over the desktop by construction,
  // needs no configuration at all, and is what every other settings surface on
  // this desktop already is.
  //
  // The cost is that this is not a window, so a close-window keybind acts on
  // whatever real window is behind it. Nothing here claims otherwise: Escape
  // and a click outside both close it, and the footer says exactly that.
  PanelWindow {
    id: window
    visible: false
    // A layer surface given no screen goes to the first one, which on two
    // monitors is not necessarily the one being looked at. Fixed at open time
    // rather than bound, so it cannot hop mid-read.
    screen: root.openedOn !== null ? root.openedOn : null
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "angelv-clock-settings"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    // Dimming what is behind says the settings are in front of it, and gives
    // the click-outside-to-close target somewhere to live.
    Rectangle {
      anchors.fill: parent
      color: Qt.rgba(0, 0, 0, 0.45)
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.close()
    }

    Rectangle {
      id: card
      // Centred by arithmetic rather than by anchors.centerIn, which will
      // happily land on a half pixel: an odd difference between the screen and
      // the card puts every hairline inside it across two physical pixels, and
      // on a fractional-scale display the one on the clip edge is dropped
      // rather than blurred. The feed boxes lost their left border to that.
      x: Math.round((parent.width - width) / 2)
      y: Math.round((parent.height - height) / 2)
      // Sized from the screen it opened on, so this is not a panel that only
      // fits the machine it was written on. Clamped at both ends: small enough
      // for a 768px laptop with a bar on it, and not so wide on a 4K panel
      // that a form of short rows is stretched across it. Screen dimensions
      // come back in logical pixels, so a 2560x1440 display at scale 1.25
      // reports 2048x1152 and gets a card sized for what its owner sees.
      width: root.cardWidth
      height: root.cardHeight
      color: Color.background
      radius: Style.cornerRadius
      border.width: Style.spacing.hairline
      border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.18)

      // The card is not the scrim: a click that lands on it stays on it.
      MouseArea { anchors.fill: parent }

    ConfirmDialog {
      id: resetDialog
      anchors.fill: parent
      // Declared before the content it covers, so it needs to say it belongs
      // on top. Without this the settings UI paints over the dialog and the
      // card reads as transparent -- the rows behind show straight through it.
      z: 100
      // Each message says what survives as well as what goes. The calendars
      // one matters most: the feed list is not settings, it is a credential
      // that exists nowhere else, so no button in here deletes it.
      message: root.tab === "clock"
        ? "Reset clock settings?\n\nAgenda times and week start go back to their "
          + "defaults. Your zones and calendars are not touched."
        : (root.tab === "zones"
          ? "Reset zone settings?\n\nYour zone list goes back to the one the plugin "
            + "ships with, not to empty, and your home label is cleared. Your calendars "
            + "are not touched."
          : "Reset calendar settings?\n\nSync interval, reminders and where links open go "
            + "back to their defaults. Your calendar feeds are kept — remove those one at a time.")
      confirmText: "Reset"
      // ConfirmDialog reports the choice and nothing else: `opened` is the
      // caller's to clear. Without these it stays on screen whichever button
      // is pressed, and looks frozen.
      onConfirmed: {
        resetDialog.opened = false
        root.resetCurrentTab()
      }
      onCanceled: resetDialog.opened = false
    }

    FocusScope {
      anchors.fill: parent
      anchors.margins: Style.space(16)
      focus: true

      Keys.onPressed: function (event) {
        // A dialog on screen gets the keyboard first -- Escape there means
        // "cancel this", not "close the window out from under it".
        if (resetDialog.opened) {
          if (resetDialog.handleKey(event)) event.accepted = true
          return
        }
        if (event.key === Qt.Key_Escape) {
          root.close()
          event.accepted = true
        }
      }

      Row {
        id: tabRow
        spacing: Style.space(6)

        Button {
          text: "Calendars"
          bordered: true
          selected: root.tab === "calendars"
          onClicked: root.tab = "calendars"
        }
        Button {
          text: "Zones"
          bordered: true
          selected: root.tab === "zones"
          onClicked: root.tab = "zones"
        }
        Button {
          text: "Clock"
          bordered: true
          selected: root.tab === "clock"
          onClicked: root.tab = "clock"
        }
      }

      // Right of the tabs, because it acts on whichever tab is showing. An
      // icon rather than a word so it cannot be mistaken for a normal action,
      // and a tooltip that names what it clears before you click it.
      Button {
        anchors.right: parent.right
        anchors.top: parent.top
        // A word, not a glyph. The obvious icon for this (nf-md-backup-restore,
        // U+F0455) draws as notdef here even though the font's cmap carries it
        // and its neighbours render -- and a plugin cannot assume anything
        // about the font on someone else's machine anyway. The tooltip says
        // which settings go.
        text: "Reset"
        tooltipText: root.resetHint
        bordered: true
        onClicked: resetDialog.opened = true
      }

      PanelSeparator {
        id: tabRule
        anchors.top: tabRow.bottom
        anchors.topMargin: Style.space(10)
        width: parent.width
        foreground: Color.foreground
      }

      // Names only what actually works here. This is an overlay, so a
      // close-window keybind would act on the window behind it -- mentioning
      // one would teach exactly the wrong reflex.
      // Scroll indicator. A tab taller than the window is normal -- the
      // Calendars tab already is with two feeds in it -- and without this the
      // last control simply looks cut off with nothing to say it can be
      // reached. Drawn rather than an attached ScrollBar, which never rendered
      // here whatever policy it was given.
      Rectangle {
        readonly property bool needed: scroll.contentHeight > scroll.height
        readonly property real trackHeight: scroll.height
        visible: needed
        width: Style.space(4)
        radius: width / 2
        anchors.right: scroll.right
        color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.3)
        height: needed
          ? Math.max(Style.space(24), trackHeight * (scroll.height / scroll.contentHeight))
          : 0
        y: needed
          ? scroll.y + (trackHeight - height)
            * Math.max(0, Math.min(1, scroll.contentY / (scroll.contentHeight - scroll.height)))
          : scroll.y
      }

      // A rule above the footer, so the scrolling area visibly ends rather
      // than the last control appearing to run out of room.
      PanelSeparator {
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.space(8)
        width: parent.width
        foreground: Color.foreground
      }

      Row {
        id: footer
        anchors.bottom: parent.bottom
        anchors.left: parent.left
        spacing: Style.space(8)

        Text {
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Esc or a click outside closes this · changes save as you make them"
          color: Qt.darker(Color.foreground, 1.9)
          font.pixelSize: Style.font.caption
        }
      }

      Flickable {
        id: scroll
        anchors.top: tabRule.bottom
        anchors.topMargin: Style.space(12)
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: footer.top
        anchors.bottomMargin: Style.space(12)
        contentWidth: width
        contentHeight: body.height
        clip: true
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: body
          // Inset from the clip on both sides: a border drawn exactly on a
          // Flickable's clip edge is a coin toss, and the right side already
          // gives up room to the scroll indicator anyway.
          x: Style.space(2)
          width: scroll.width - Style.space(12)
          spacing: Style.space(14)
          // The footer is a fixed strip below this. Without a tail the last
          // control in a tab ends hard against it and reads as cut off.
          bottomPadding: Style.space(10)

          // --------------------------------------------------- calendars ---
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.tab === "calendars"

            PanelSectionHeader {
              text: "FEEDS"
              foreground: Color.foreground
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Any .ics or webcal:// link — a Google \"secret address in iCal "
                + "format\", an Apple published calendar, Outlook, Proton, Nextcloud, or a "
                + "file on disk. Read-only — nothing here is written back to a calendar. "
                + "The file is kept 0600 because the URL is a password."
              color: Qt.darker(Color.foreground, 1.6)
              font.pixelSize: Style.font.bodySmall
            }

            Repeater {
              model: root.calendars

              Rectangle {
                id: calRow
                required property var modelData
                required property int index

                // The URL is a bearer credential: anyone holding it can read
                // the calendar, indefinitely, without signing in to anything.
                // So it stays masked until asked for, and a screenshot of this
                // window does not hand the calendar away. Found the hard way
                // while screenshotting this very row.
                property bool urlRevealed: false

                width: body.width
                height: calBody.implicitHeight + Style.space(20)
                radius: Style.cornerRadius
                color: "transparent"
                border.width: Style.spacing.hairline
                border.color: Qt.darker(Color.foreground, 2.4)

                Column {
                  id: calBody
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)

                  Row {
                    width: parent.width
                    spacing: Style.space(8)

                    TextField {
                      width: calBody.width * 0.34
                      text: String(calRow.modelData.name || "")
                      placeholderText: "Name"
                      onEditingFinished: root.mutateCalendar(calRow.index, "name", text)
                    }

                    TextField {
                      id: colorField
                      width: calBody.width * 0.22
                      text: String(calRow.modelData.color || "#4A90E2")
                      placeholderText: "#RRGGBB"
                      // Only a colour QML can parse is saved. An unparseable
                      // one reaches the popup as a chip and an event rule
                      // colour, where it is a warning per repaint rather than
                      // anything visible here -- so the field snaps back to
                      // the saved value instead of writing it.
                      onEditingFinished: {
                        if (/^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(text))
                          root.mutateCalendar(calRow.index, "color", text)
                        else
                          text = String(calRow.modelData.color || "#4A90E2")
                      }
                    }

                    // The swatch reads the field as it is typed, not the saved
                    // value, so a wrong code shows itself before it is
                    // committed. A code QML cannot parse would throw, so it is
                    // checked first and the swatch goes hollow instead --
                    // which is also the only signal that the code is bad.
                    Rectangle {
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(20)
                      height: Style.space(20)
                      radius: Style.cornerRadius > 0 ? width / 2 : 0
                      readonly property bool valid: /^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/.test(colorField.text)
                      color: valid ? colorField.text : "transparent"
                      border.width: Style.spacing.hairline
                      border.color: valid ? Qt.darker(Color.foreground, 2.4)
                        : Qt.darker(Color.foreground, 1.4)

                      Text {
                        anchors.centerIn: parent
                        visible: !parent.valid
                        text: "?"
                        color: Qt.darker(Color.foreground, 1.4)
                        font.pixelSize: Style.font.bodySmall
                      }
                    }

                    ToggleSwitch {
                      anchors.verticalCenter: parent.verticalCenter
                      checked: calRow.modelData.enabled !== false
                      onToggled: root.mutateCalendar(calRow.index, "enabled",
                        calRow.modelData.enabled === false)
                    }

                    Button {
                      anchors.verticalCenter: parent.verticalCenter
                      text: "Remove"
                      bordered: true
                      onClicked: root.removeCalendar(calRow.index)
                    }
                  }

                  Row {
                    width: parent.width
                    spacing: Style.space(8)

                    TextField {
                      width: calBody.width - revealButton.width - Style.space(8)
                      password: !calRow.urlRevealed
                      text: String(calRow.modelData.url || "")
                      placeholderText: "https://calendar.google.com/calendar/ical/…/basic.ics"
                      onEditingFinished: root.mutateCalendar(calRow.index, "url", text)
                    }

                    Button {
                      id: revealButton
                      anchors.verticalCenter: parent.verticalCenter
                      text: calRow.urlRevealed ? "Hide" : "Show"
                      bordered: true
                      onClicked: calRow.urlRevealed = !calRow.urlRevealed
                    }
                  }
                }
              }
            }

            Button {
              text: "Add calendar"
              bordered: true
              onClicked: root.addCalendar()
            }

            PanelSeparator {
              width: parent.width
              foreground: Color.foreground
            }

            PanelSectionHeader {
              text: "SYNC"
              foreground: Color.foreground
            }

            NumberField {
              label: "Minutes between syncs (0 is manual only)"
              value: root.setting("syncIntervalMinutes", 15)
              from: 0
              to: 720
              onModified: function (v) { root.put("syncIntervalMinutes", v) }
            }

            Row {
              spacing: Style.space(10)

              ToggleSwitch {
                id: notifyToggle
                anchors.verticalCenter: parent.verticalCenter
                checked: root.setting("notifyUpcomingEvents", true) !== false
                onToggled: root.put("notifyUpcomingEvents", !notifyToggle.checked)
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Remind me before an event starts"
                color: Color.foreground
                font.pixelSize: Style.font.body
              }
            }

            // Chips rather than a Dropdown, here and below. Ui/Dropdown pins
            // its popup at trigger.height and never flips up, so one low in a
            // panel simply draws its last options past the bottom edge where
            // they cannot be picked. Chips lay out inside the card instead.
            Text {
              text: "When to remind"
              color: Qt.darker(Color.foreground, 1.4)
              font.pixelSize: Style.font.bodySmall
            }

            ButtonGroup {
              value: String(root.setting("notifyMinutesBefore", "staged"))
              options: ["staged", "1", "5", "10", "15", "30", "60"]
              onChanged: function (v) { root.put("notifyMinutesBefore", v) }
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "\"staged\" nudges three times — 10, 5 and 1 minutes before. "
                + "A number nudges once, that many minutes before. Either way each "
                + "event notifies once per stage, and all-day events never do."
              color: Qt.darker(Color.foreground, 1.6)
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              text: "Open meetings and calendar links in"
              color: Qt.darker(Color.foreground, 1.4)
              font.pixelSize: Style.font.bodySmall
            }

            ButtonGroup {
              value: String(root.setting("meetingHandler", "webapp"))
              options: ["webapp", "browser"]
              onChanged: function (v) { root.put("meetingHandler", v) }
            }
          }

          // ------------------------------------------------------- zones ---
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.tab === "zones"

            PanelSectionHeader {
              text: "HOME"
              foreground: Color.foreground
            }

            Text {
              width: parent.width
              wrapMode: Text.WordWrap
              textFormat: Text.PlainText
              text: "Your own zone is detected automatically. Give it a label if you "
                + "want the row named something other than the zone itself."
              color: Qt.darker(Color.foreground, 1.6)
              font.pixelSize: Style.font.bodySmall
            }

            TextField {
              width: body.width * 0.55
              text: String(root.setting("homeName", ""))
              placeholderText: "Label (optional)"
              onEditingFinished: root.put("homeName", text)
            }

            Row {
              spacing: Style.space(10)

              ToggleSwitch {
                id: homeHour12Toggle
                anchors.verticalCenter: parent.verticalCenter
                checked: root.setting("homeHour12", false) === true
                onToggled: root.put("homeHour12", !homeHour12Toggle.checked)
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                text: "Show my own row in 12-hour time"
                color: Color.foreground
                font.pixelSize: Style.font.body
              }
            }

            PanelSeparator {
              width: parent.width
              foreground: Color.foreground
            }

            PanelSectionHeader {
              text: "ZONES"
              foreground: Color.foreground
            }

            // Above the list, not below it. SearchableDropdown pins its popup
            // at trigger.height and never flips up, so at the foot of a list
            // that grows with every zone added it would eventually open past
            // the bottom of the window.
            SearchableDropdown {
              width: body.width * 0.62
              label: "Add a zone"
              triggerLabel: "Choose a time zone…"
              value: ""
              options: root.zoneList
              placeholderText: "Search time zones…"
              emptyText: "No matching zone"
              onChanged: function (v) { root.addZone(v) }
            }

            Repeater {
              model: root.zonesAsPairs()

              Row {
                id: zoneRow
                required property var modelData
                required property int index

                width: body.width
                spacing: Style.space(8)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  width: body.width * 0.36
                  elide: Text.ElideRight
                  textFormat: Text.PlainText
                  text: zoneRow.modelData.tz
                  color: Color.foreground
                  font.pixelSize: Style.font.body
                }

                TextField {
                  width: body.width * 0.3
                  text: zoneRow.modelData.name
                  placeholderText: "Label (optional)"
                  onEditingFinished: root.renameZone(zoneRow.index, text)
                }

                Button {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Remove"
                  bordered: true
                  onClicked: root.removeZone(zoneRow.index)
                }
              }
            }
          }

          // ------------------------------------------------------- clock ---
          Column {
            width: parent.width
            spacing: Style.space(10)
            visible: root.tab === "clock"

            PanelSectionHeader {
              text: "CALENDAR"
              foreground: Color.foreground
            }

            Text {
              text: "Agenda times"
              color: Qt.darker(Color.foreground, 1.4)
              font.pixelSize: Style.font.bodySmall
            }

            ButtonGroup {
              value: root.isUnset("hour12") ? "follow locale"
                : (root.setting("hour12", false) === true ? "12-hour" : "24-hour")
              options: ["follow locale", "12-hour", "24-hour"]
              onChanged: function (v) {
                if (v === "follow locale") root.put("hour12", undefined)
                else root.put("hour12", v === "12-hour")
              }
            }

            // Unset means the locale decides, exactly as the popup reads it --
            // and for a US locale that is Sunday, not Monday. Offering only
            // Monday and Sunday would have shown the wrong one as current and
            // then written it.
            //
            // Stored as a weekday *name*, which is the form the popup's own
            // `w` toggle writes. coerceWeekStart() takes a number too, but two
            // spellings of one setting in one file is how they drift.
            Text {
              text: "Week starts on"
              color: Qt.darker(Color.foreground, 1.4)
              font.pixelSize: Style.font.bodySmall
            }

            ButtonGroup {
              value: {
                var raw = String(root.setting("weekStartDay", "")).toLowerCase()
                if (raw === "monday" || raw === "mon" || raw === "1") return "Monday"
                if (raw === "sunday" || raw === "sun" || raw === "0") return "Sunday"
                return "follow locale"
              }
              options: ["follow locale", "Monday", "Sunday"]
              onChanged: function (v) {
                if (v === "follow locale") root.put("weekStartDay", undefined)
                else root.put("weekStartDay", v.toLowerCase())
              }
            }


          }
        }
      }
    }
    }
  }
}
