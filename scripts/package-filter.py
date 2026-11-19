import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys

app = pathlib.Path(sys.argv[1]).resolve()
project = pathlib.Path(__file__).resolve().parent.parent
team = os.environ.get("GUARDIAN_TEAM_ID", "")
identity = os.environ.get("GUARDIAN_SIGN_IDENTITY", "")
if not re.fullmatch(r"[A-Z0-9]{10}", team) or not identity.startswith("Developer ID Application:"):
    raise SystemExit("Set GUARDIAN_TEAM_ID and GUARDIAN_SIGN_IDENTITY (Developer ID Application).")
group = team + ".dev.local.agent-account-guardian"
service = group + ".filter"
capability = "content-filter-provider-systemextension"
profiles = {}
for kind, identifier in [("APP", "dev.local.agent-account-guardian"), ("FILTER", "dev.local.agent-account-guardian.filter")]:
    path = pathlib.Path(os.environ.get("GUARDIAN_" + kind + "_PROFILE", ""))
    if not path.is_file():
        raise SystemExit("Set GUARDIAN_" + kind + "_PROFILE to its Developer ID provisioning profile.")
    decoded = subprocess.run(["security", "cms", "-D", "-i", str(path)], capture_output=True, check=True).stdout
    profile = plistlib.loads(decoded)
    entitlements = profile["Entitlements"]
    if team not in profile.get("TeamIdentifier", []) or entitlements.get("com.apple.application-identifier") != team + "." + identifier:
        raise SystemExit(kind + " provisioning profile has the wrong team or app identifier.")
    if capability not in entitlements.get("com.apple.developer.networking.networkextension", []):
        raise SystemExit(kind + " profile does not authorize the system content filter capability.")
    if group not in entitlements.get("com.apple.security.application-groups", []):
        raise SystemExit(kind + " profile does not authorize the shared Mach service app group.")
    if kind == "APP" and not entitlements.get("com.apple.developer.system-extension.install"):
        raise SystemExit("App profile does not authorize system extension installation.")
    profiles[kind] = path

extension = app / "Contents/Library/SystemExtensions/dev.local.agent-account-guardian.filter.systemextension"
(extension / "Contents/MacOS").mkdir(parents=True)
shutil.copy2(project / ".build/release/GuardianFilter", extension / "Contents/MacOS/GuardianFilter")
app_info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
info = plistlib.loads((project / "packaging/Filter-Info.plist").read_bytes())
for key in ["CFBundleShortVersionString", "CFBundleVersion"]:
    info[key] = app_info[key]
info["GuardianTeamID"] = team
info["NetworkExtension"]["NEMachServiceName"] = service
(extension / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
app_info["GuardianTeamID"] = team
app_info["GuardianFilterService"] = service
(app / "Contents/Info.plist").write_bytes(plistlib.dumps(app_info))

for kind, bundle in [("FILTER", extension), ("APP", app)]:
    identifier = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())["CFBundleIdentifier"]
    entitlements = {
        "com.apple.application-identifier": team + "." + identifier,
        "com.apple.developer.team-identifier": team,
        "com.apple.developer.networking.networkextension": [capability],
        "com.apple.security.application-groups": [group],
    }
    if kind == "APP":
        entitlements["com.apple.developer.system-extension.install"] = True
    else:
        entitlements["com.apple.security.app-sandbox"] = True
    entitlement_path = app.parent / (kind + ".entitlements")
    entitlement_path.write_bytes(plistlib.dumps(entitlements))
    shutil.copy2(profiles[kind], bundle / "Contents/embedded.provisionprofile")
    subprocess.run(["codesign", "--force", "--options", "runtime", "--timestamp", "--sign", identity,
                    "--entitlements", str(entitlement_path), str(bundle)], check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
