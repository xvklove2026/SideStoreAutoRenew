# Project instructions

This is an external-build workspace for a SideStore auto-renew tweak and PreferenceLoader settings bundle. Preserve projectID, kind and buildSystem in apelin-project.json.

Local builds use apelin_project_build with apelin/build.sh; never run the packaging script locally through shell_run. The user explicitly requested a public GitHub repository and GitHub Actions builds, choosing SideStoreAutoRenew on their account. The cloud workflow may call the same script on macOS with Xcode SDK and packaging tools. Repository: https://github.com/xvklove2026/SideStoreAutoRenew. Cloud debs must be installed by the user with their package manager, not passed to apelin_package_install as local artifacts. Do not hard-code a resolved bootstrap path.

Status as of 2026-11-26: source exists but has never compiled or been installed. The attempted build stopped at missing SDKROOT. Toolchain and SDK registries are empty, and all catalog toolchains require FEAT_LRCPC absent on this device. No compiler diagnostics for the Objective-C sources have been obtained. Do not claim the runtime behavior works.

Static checks: sh -n apelin/build.sh passed. Preferences/Root.plist, Info.plist and Entry.plist were parsed with icli fs plist. This device's plutil does not accept macOS -lint or -p flags; do not count those invocations as passing checks.

Sources/SRATweak.m runs in SpringBoard and SideStore, using Darwin notification state to send a timestamp and coarse response status. Sources/SRACommon.h owns the preference domain and schedule calculation. Preferences/SRARootListController.m and Root.plist implement time and weekday settings. Vendor contains only minimal MIT-derived Preferences declarations and a link stub, not a toolchain.

The package identifier local.apelin.sidestore.autorenew is provisional; obtain the user's choice before first installation and update every occurrence consistently if changed. Do not commit or push unless the user asks.

Read README.md for outstanding compatibility checks. In particular, the installed SideStore commit was not resolved on the official repository, so develop-branch code is only a reference. Refresh intent class names, selectors and response enum values need verification against the installed binary. A success response does not verify refreshed signing expiry. Test settings persistence, scheduling, lock deferral, duplicate suppression and real signing expiry before calling the task complete.
