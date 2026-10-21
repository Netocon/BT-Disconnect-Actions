; Netocon. Revision date: 21/10/2026
; ---------------------------------------------------------------
; Bluetooth Disconnect Actions-> sends Mute or Play_Pause
; Ref: learn.microsoft.com/en-us/windows/win32/bluetooth/bluetooth-and-wm-devicechange-messages
; ---------------------------------------------------------------

#NoEnv
#SingleInstance Force
#Persistent
SetBatchLines, -1

DEBOUNCE_MS := 1500
SETTLE_MS   := 700         ; wait after a disconnect event, then confirm the radio is still active
POLL_MS     := 2000        ; radio presence check interval
TARGET_ADDR := ""          ; optional: 12 hex digits, e.g. "A1B2C3D4E5F6". Empty = any device.
GUID_HCI_EVENT := "{FC240062-1541-49BE-B463-84C4DCD7BF7F}"  ; GUID_BLUETOOTH_HCI_EVENT
lastFire := 0
hRadio := 0
hNotify := 0
radioActive := false

; DEV_BROADCAST_HANDLE layout (32/64-bit aware)
ofsHandle  := 8 + A_PtrSize
ofsNotify  := ofsHandle + A_PtrSize
ofsGuid    := ofsNotify + A_PtrSize
ofsNameOfs := ofsGuid + 16
ofsData    := ofsNameOfs + 4
structSize := (A_PtrSize = 8) ? 56 : 44

; Hidden window to receive WM_DEVICECHANGE
Gui, +hwndhGui
Gui, Show, Hide w1 h1

; ---------------------------------------------------------------
; Settings: bt_config.ini in %LocalAppData%
;   UseMute = 1 -> send Volume_Mute | 0 -> send Media_Stop
;   HideTray = 1 -> tray icon hidden
; The settings window opens only with the "/settings" argument or from the tray menu.
; ---------------------------------------------------------------
EnvGet, localAppData, LocalAppData
cfgFile := localAppData "\bt_disconnect_config.ini"
IniRead, UseMute,  %cfgFile%, Settings, UseMute,  1
IniRead, HideTray, %cfgFile%, Settings, HideTray, 0
UseMute  := (UseMute  = 1) ? 1 : 0
HideTray := (HideTray = 1) ? 1 : 0

Menu, Tray, NoStandard
Menu, Tray, Tip, BT Disconnect Actions
iconDll := A_WinDir ((A_Is64bitOS && A_PtrSize = 4) ? "\Sysnative" : "\System32") "\netshell.dll"
iconMun := A_WinDir "\SystemResources\netshell.dll.mun"
Menu, Tray, Icon, %iconDll%, -1612           ; resource ID via the regular DLL path
if (ErrorLevel)
    Menu, Tray, Icon, %iconDll%, 1612        ; icon index
if (ErrorLevel)
    Menu, Tray, Icon, %iconMun%, -1612       ; resource ID via the .mun file
if (ErrorLevel)
    Menu, Tray, Icon, %iconMun%, 1612

Menu, Tray, Add, Send Mute (off = Pause), ToggleMute
Menu, Tray, Add, Hide tray icon, ToggleHide
Menu, Tray, Add
Menu, Tray, Add, Settings window, ShowSettings
Menu, Tray, Default, Settings window
Menu, Tray, Add
Menu, Tray, Add, Exit, TrayExit
Menu, Tray, Click, 1

Gui, Settings:New, +AlwaysOnTop, BT Disconnect Actions Settings
Gui, Settings:Add, Text,, On Bluetooth disconnect:
Gui, Settings:Add, Checkbox, vUseMute gOnSettingChange Checked%UseMute%, Send Mute (unchecked = send Stop)
Gui, Settings:Add, Checkbox, vHideTray gOnSettingChange Checked%HideTray%, Hide tray icon
Gui, Settings:Add, Text, cGray, Launch the script with /settings to reopen this window if the tray icon is hidden.
Gosub, SyncUI                                ; apply tray checks + icon visibility
if (A_Args[1] = "/settings")
    Gui, Settings:Show, AutoSize

; ---------------------------------------------------------------
; Radio handling: attach when a radio exists, detach when it disappears,
; re-attach when it returns.
; ---------------------------------------------------------------
SetupRadio()
SetTimer, CheckRadio, %POLL_MS%
OnMessage(0x0219, "OnDeviceChange")    ; WM_DEVICECHANGE
OnExit, Cleanup
return

SetupRadio() {
    global hRadio, hNotify, hGui, radioActive, ofsHandle, structSize
    if (radioActive)
        return true
    VarSetCapacity(params, 4, 0)
    NumPut(4, params, 0, "UInt")                 ; BLUETOOTH_FIND_RADIO_PARAMS.dwSize
    r := 0
    hFind := DllCall("bthprops.cpl\BluetoothFindFirstRadio", "Ptr", &params, "Ptr*", r, "Ptr")
    if (!hFind)
        return false
    DllCall("bthprops.cpl\BluetoothFindRadioClose", "Ptr", hFind)

    VarSetCapacity(filter, structSize, 0)
    NumPut(structSize, filter, 0, "UInt")
    NumPut(6, filter, 4, "UInt")                 ; DBT_DEVTYP_HANDLE
    NumPut(r, filter, ofsHandle, "Ptr")
    n := DllCall("RegisterDeviceNotificationW", "Ptr", hGui, "Ptr", &filter, "UInt", 0, "Ptr")
    if (!n) {
        DllCall("CloseHandle", "Ptr", r)
        return false
    }
    hRadio := r
    hNotify := n
    radioActive := true
    return true
}

TeardownRadio() {
    global hRadio, hNotify, radioActive
    if (hNotify)
        DllCall("UnregisterDeviceNotification", "Ptr", hNotify)
    if (hRadio)
        DllCall("CloseHandle", "Ptr", hRadio)
    hNotify := 0
    hRadio := 0
    radioActive := false
}

RadioAlive() {
    global hRadio
    if (!hRadio)
        return false
    VarSetCapacity(info, 520, 0)                 ; BLUETOOTH_RADIO_INFO
    NumPut(520, info, 0, "UInt")
    return (DllCall("bthprops.cpl\BluetoothGetRadioInfo", "Ptr", hRadio, "Ptr", &info, "UInt") = 0)
}

CheckRadio() {
    global radioActive
    if (radioActive) {
        if (!RadioAlive())
            TeardownRadio()
    } else
        SetupRadio()
}

OnDeviceChange(wParam, lParam, msg, hwnd) {
    global lastFire, DEBOUNCE_MS, SETTLE_MS, TARGET_ADDR, GUID_HCI_EVENT, ofsGuid, ofsData

    if (!lParam)
        return 1
    if (NumGet(lParam + 0, 4, "UInt") != 6)      ; DBT_DEVTYP_HANDLE
        return 1

    if (wParam = 0x8004) {                       ; DBT_DEVICEREMOVECOMPLETE -> radio gone
        SetTimer, CheckRadio, -200
        return 1
    }
    if (wParam != 0x8006)                        ; DBT_CUSTOMEVENT
        return 1

    ; Identify the event GUID
    VarSetCapacity(buf, 80, 0)
    DllCall("ole32\StringFromGUID2", "Ptr", lParam + ofsGuid, "Ptr", &buf, "Int", 39)
    guid := StrGet(&buf, "UTF-16")
    if (guid != GUID_HCI_EVENT)
        return 1

    ; BTH_HCI_EVENT_INFO: bthAddress(8 bytes) @0, connectionType(UChar) @8, connected(UChar) @9
    data := lParam + ofsData
    lo := NumGet(data + 0, 0, "UInt")
    hi := NumGet(data + 0, 4, "UInt") & 0xFFFF
    addr := Format("{:04X}{:08X}", hi, lo)
    connected := NumGet(data + 0, 9, "UChar")

    if (connected)                               ; connect event -> ignore
        return 1
    if (TARGET_ADDR != "" && addr != TARGET_ADDR)
        return 1
    if (A_TickCount - lastFire < DEBOUNCE_MS)    ; ACL + SCO events can fire back-to-back
        return 1

    lastFire := A_TickCount
    SetTimer, DoAction, -%SETTLE_MS%             ; confirm radio state before acting
    return 1
}

DoAction:
    ; Radio switched off -> every device disconnects; ignore those events.
    if (!radioActive || !RadioAlive()) {
        TeardownRadio()
        return
    }
    if (UseMute)
        Send, {Volume_Mute}
    else
        Send, {Media_Play_Pause}
return

ShowSettings:
    Gui, Settings:Show, AutoSize
return

OnSettingChange:
    Gui, Settings:Submit, NoHide
    Gosub, SaveSettings
return

ToggleMute:
    UseMute := !UseMute
    Gosub, SaveSettings
return

ToggleHide:
    HideTray := !HideTray
    Gosub, SaveSettings
return

SaveSettings:
    IniWrite, %UseMute%,  %cfgFile%, Settings, UseMute
    IniWrite, %HideTray%, %cfgFile%, Settings, HideTray
    Gosub, SyncUI
return

; Keep tray menu, settings window and tray icon consistent with the variables
SyncUI:
    GuiControl, Settings:, UseMute, %UseMute%
    GuiControl, Settings:, HideTray, %HideTray%
    if (UseMute)
        Menu, Tray, Check, Send Mute (off = Pause)
    else
        Menu, Tray, Uncheck, Send Mute (off = Pause)
    if (HideTray) {
        Menu, Tray, Check, Hide tray icon
        Menu, Tray, NoIcon
    } else {
        Menu, Tray, Uncheck, Hide tray icon
        Menu, Tray, Icon
    }
return

SettingsGuiClose:
SettingsGuiEscape:
    Gui, Settings:Hide
return

TrayExit:
    ExitApp
return

Cleanup:
    TeardownRadio()
    ExitApp
return
