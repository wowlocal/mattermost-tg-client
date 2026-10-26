#!/usr/bin/env python3
"""DEVELOPMENT ONLY: allows notifications for an app on a SHUT DOWN iOS simulator, as "Allow" on the system
prompt would, for scripted runs without UI automation (`xcrun simctl privacy` has no notifications service).

  xcrun simctl shutdown <udid>
  tools/sim-allow-notifications.py <udid> [bundle id, default org.relaychat.Relay] [display name, default Relay]
  xcrun simctl boot <udid>

It adds the app's section to the simulator's BulletinBoard settings
(data/Library/BulletinBoard/VersionedSectionInfo.plist, an NSKeyedArchiver BBSectionInfo per app) with the
values iOS 26.5 stores after "Allow": authorized, banners, lock screen, Notification Center, sounds, badges,
communication notifications. A backup is kept next to it (.bak). Verified on iOS 26.5 simulators.
"""
import os
import plistlib
import shutil
import subprocess
import sys
from plistlib import UID


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    udid = sys.argv[1]
    bundle_id = sys.argv[2] if len(sys.argv) > 2 else "org.relaychat.Relay"
    name = sys.argv[3] if len(sys.argv) > 3 else "Relay"
    devices = subprocess.check_output(["xcrun", "simctl", "list", "devices"], text=True)
    line = next((l for l in devices.splitlines() if udid in l), None)
    if line is None:
        sys.exit("error: no simulator %s" % udid)
    if "(Shutdown)" not in line:
        sys.exit("error: shut the simulator down first (xcrun simctl shutdown %s)" % udid)
    path = os.path.expanduser("~/Library/Developer/CoreSimulator/Devices/%s/data/Library/BulletinBoard/VersionedSectionInfo.plist" % udid)
    if not os.path.exists(path):
        sys.exit("error: %s not found (boot the simulator once first)" % path)
    shutil.copy(path, path + ".bak")
    root = plistlib.load(open(path, "rb"))
    settings = {
        "userConfiguredTimeSensitiveSetting": False, "lockScreenSetting": 2, "carPlaySetting": 2, "bulletinGroupingSetting": 0,
        "remoteNotificationsSetting": 2, "muteAssertion": UID(0), "announcePriority": 0, "authorizationExpirationDate": UID(0),
        "directMessagesSettingKey": 2, "pushSettings": 63, "authorizationStatus": 2, "$class": UID(4),
        "userConfiguredDirectMessagesSetting": False, "showsInLockScreen": True, "criticalAlertSetting": 0,
        "notificationCenterSetting": 2, "prioritizationSetting": 2, "showsInNotificationCenter": True, "alertType": 1,
        "showsOnExternalDevices": True, "announceSetting": 2, "timeSensitiveSetting": 2, "scheduledDeliverySetting": 1,
        "contentPreviewSetting": 0, "summarizationSetting": 2, "showsCustomSettingsLink": False,
        "lastUserGrantedAuthorizationDate": UID(0),
    }
    info = {
        "suppressFromSettings": False, "suppressedSettings": 0, "isRestricted": False, "customSettingsBundle": UID(0),
        "isModificationAllowed": True, "sectionID": UID(2), "subsections": UID(0), "icon": UID(0), "displayName": UID(5),
        "$class": UID(7), "sectionInfoSettings": UID(3), "sectionCategory": 0, "subsectionPriority": 0,
        "managedSectionInfoSettings": UID(0), "version": UID(6), "isAppClip": False, "appName": UID(5), "sectionType": 0,
        "factorySectionID": UID(0), "dataProviderIDs": UID(0), "customSettingsDetailControllerClass": UID(0),
        "subsectionID": UID(0), "hideWeeApp": False, "pathToWeeAppPluginBundle": UID(0),
    }
    archive = {
        "$version": 100000, "$archiver": "NSKeyedArchiver", "$top": {"root": UID(1)},
        "$objects": [
            "$null", info, bundle_id, settings,
            {"$classname": "BBSectionInfoSettings", "$classes": ["BBSectionInfoSettings", "NSObject"]},
            name, 0,
            {"$classname": "BBSectionInfo", "$classes": ["BBSectionInfo", "NSObject"]},
        ],
    }
    root["sectionInfo"][bundle_id] = plistlib.dumps(archive, fmt=plistlib.FMT_BINARY)
    with open(path, "wb") as f:
        plistlib.dump(root, f, fmt=plistlib.FMT_BINARY)
    print("notifications allowed for %s on %s; boot the simulator" % (bundle_id, udid))


if __name__ == "__main__":
    main()
