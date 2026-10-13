#!/usr/bin/env python3
"""Generate the small M0 Xcode project without an additional generator dependency."""
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
release = json.loads((ROOT / "release.json").read_text())
objects = {}


def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def obj(name, body):
    key = ident(name)
    objects[key] = body
    return key


def quote(value):
    return json.dumps(str(value))


source_builds = []
file_refs = []
for path in sorted((ROOT / "App").glob("*.swift")):
    relative = path.relative_to(ROOT)
    ref = obj(str(relative), f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(relative)}; sourceTree = SOURCE_ROOT;')
    file_refs.append(ref)
    source_builds.append(obj("build" + str(relative), f"isa = PBXBuildFile; fileRef = {ref};"))

framework_ref = obj("framework", 'isa = PBXFileReference; lastKnownFileType = wrapper.xcframework; path = .cache/dependencies/ghostty/macos/GhosttyKit.xcframework; sourceTree = SOURCE_ROOT;')
framework_builds = [obj("framework-build", f"isa = PBXBuildFile; fileRef = {framework_ref};")]
package = obj("package", 'isa = XCLocalSwiftPackageReference; relativePath = .;')
products = []
for name in ["SpookkyCore", "SpookkyRuntime", "SpookkyWorkspace", "SpookkyPersistence", "SpookkyGit", "SpookkyFiles", "SpookkySyntax"]:
    product = obj(name, f"isa = XCSwiftPackageProductDependency; productName = {name};")
    products.append(product)
    framework_builds.append(obj(name + "-build", f"isa = PBXBuildFile; productRef = {product};"))

sparkle = obj("sparkle-package", 'isa = XCRemoteSwiftPackageReference; repositoryURL = "https://github.com/sparkle-project/Sparkle"; requirement = {kind = exactVersion; version = 2.10.0;};')
sparkle_product = obj("sparkle-product", f"isa = XCSwiftPackageProductDependency; package = {sparkle}; productName = Sparkle;")
products.append(sparkle_product)
framework_builds.append(obj("sparkle-link", f"isa = PBXBuildFile; productRef = {sparkle_product};"))
resources = []
for name in ["ghostty", "terminfo", "licenses", "Assets.xcassets"]:
    path = "App/Assets.xcassets" if name == "Assets.xcassets" else ("Dependencies/licenses" if name == "licenses" else ".cache/dependencies/ghostty/zig-out/share/" + name)
    ref = obj("resource-" + name, f"isa = PBXFileReference; lastKnownFileType = {"folder.assetcatalog" if name == "Assets.xcassets" else "folder"}; path = {path}; sourceTree = SOURCE_ROOT;")
    file_refs.append(ref)
    resources.append(obj("resource-build-" + name, f"isa = PBXBuildFile; fileRef = {ref};"))

def phase(name, kind, files):
    return obj(name, f"isa = {kind}; buildActionMask = 2147483647; files = ({','.join(files)}); runOnlyForDeploymentPostprocessing = 0;")

sources_phase = phase("sources", "PBXSourcesBuildPhase", source_builds)
frameworks_phase = phase("frameworks", "PBXFrameworksBuildPhase", framework_builds)
resources_phase = phase("resources", "PBXResourcesBuildPhase", resources)
# Atomic replacement preserves executable inodes used by retained terminal processes.
helper_script = 'set -eu\ncd "$SRCROOT"\n/usr/bin/swift build -c release --product spookky-launch\n/usr/bin/swift build -c release --product spookky-runtime-check\nfor helper in spookky-launch spookky-runtime-check; do\n  destination="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/$helper"\n  cp ".build/release/$helper" "$destination.next"\n  mv -f "$destination.next" "$destination"\ndone\ntest -x .cache/runtime/bin/tmux\ndestination="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/tmux"\ncp .cache/runtime/bin/tmux "$destination.next"\nmv -f "$destination.next" "$destination"\ncp -R .cache/runtime/share/terminfo/. "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/terminfo/"\n'
helper_phase = obj("helper", f'isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = ("$(TARGET_BUILD_DIR)/$(EXECUTABLE_FOLDER_PATH)/spookky-launch"); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = {quote(helper_script)};')
app_ref = obj("app", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = "Spookky.app"; sourceTree = BUILT_PRODUCTS_DIR;')
products_group = obj("products-group", f'isa = PBXGroup; name = Products; children = ({app_ref}); sourceTree = "<group>";')
main_group = obj("main-group", f'isa = PBXGroup; children = ({",".join(file_refs + [framework_ref, products_group])}); sourceTree = "<group>";')

settings = {
    "MACOSX_DEPLOYMENT_TARGET": "14.0", "SDKROOT": "macosx", "ARCHS": "arm64",
    "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "minimal",
    "PRODUCT_NAME": "Spookky", "PRODUCT_BUNDLE_IDENTIFIER": "dev.spookky.m0",
    "GENERATE_INFOPLIST_FILE": "NO", "INFOPLIST_FILE": "App/Info.plist",
    "ALWAYS_SEARCH_USER_PATHS": "NO",
    "INFOPLIST_KEY_NSHumanReadableCopyright": "Copyright © 2026 Pamekitti", "INFOPLIST_KEY_NSHighResolutionCapable": "YES", "CODE_SIGN_STYLE": "Automatic",
    "CODE_SIGN_IDENTITY": "-", "ENABLE_APP_SANDBOX": "NO", "ENABLE_USER_SCRIPT_SANDBOXING": "NO",
    "OTHER_LDFLAGS": "$(inherited) -lc++ -framework Metal -framework QuartzCore -framework CoreText -framework CoreVideo -framework IOSurface -framework AppKit -framework Carbon",
    "MARKETING_VERSION": release["version"], "CURRENT_PROJECT_VERSION": str(release["build"]),
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/../Frameworks",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
    "SPOOKKY_UPDATE_FEED_URL": release["feedURL"],
    "SPOOKKY_UPDATE_PUBLIC_KEY": release["publicEDKey"],
    "SPOOKKY_RELEASE_CHANNEL": release["channel"],
    "SPOOKKY_DISPLAY_NAME": "Spookky Dev",
    "SPOOKKY_DEVELOPMENT_CHECKOUT": "$(SRCROOT)",
}
configs = []
for name in ["Debug", "Release", "Distribution"]:
    current = dict(settings)
    current["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if name == "Debug" else "-O"
    current["DEBUG_INFORMATION_FORMAT"] = "dwarf-with-dsym"
    if name == "Distribution":
        current["SPOOKKY_DISPLAY_NAME"] = "Spookky"
        current["SPOOKKY_DEVELOPMENT_CHECKOUT"] = ""
        current["PRODUCT_BUNDLE_IDENTIFIER"] = release["bundleID"]
        current["ENABLE_HARDENED_RUNTIME"] = "YES"
        current["CODE_SIGN_IDENTITY"] = "Developer ID Application"
        current["CODE_SIGN_STYLE"] = "Manual"
        current["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "SPOOKKY_DISTRIBUTION"
        current["OTHER_SWIFT_FLAGS"] = "$(inherited) -debug-prefix-map $(SRCROOT)=."

    body = " ".join(f"{key} = {quote(value)};" for key, value in current.items())
    configs.append(obj("config-" + name, f"isa = XCBuildConfiguration; name = {name}; buildSettings = {{{body}}};"))
config_list = obj("configs", f"isa = XCConfigurationList; buildConfigurations = ({','.join(configs)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
target = obj("target", f'isa = PBXNativeTarget; name = "Spookky"; productName = "Spookky"; productReference = {app_ref}; productType = "com.apple.product-type.application"; buildConfigurationList = {config_list}; buildPhases = ({sources_phase},{frameworks_phase},{resources_phase},{helper_phase}); buildRules = (); dependencies = (); packageProductDependencies = ({",".join(products)});')
project = obj("project", f'isa = PBXProject; attributes = {{LastUpgradeCheck = 2700;}}; buildConfigurationList = {config_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base); mainGroup = {main_group}; productRefGroup = {products_group}; projectDirPath = ""; projectRoot = ""; targets = ({target}); packageReferences = ({package},{sparkle});')
destination = ROOT / "Spookky.xcodeproj"
destination.mkdir(exist_ok=True)
content = '\n'.join(f"{key} = {{{body}}};" for key, body in objects.items())
(destination / "project.pbxproj").write_text(f"// !$*UTF8*$!\n{{archiveVersion = 1; classes = {{}}; objectVersion = 56; objects = {{\n{content}\n}}; rootObject = {project};}}\n")
print("Generated Spookky.xcodeproj")

scheme_dir = destination / "xcshareddata/xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
(scheme_dir / "Spookky.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2700" version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Spookky.app" BlueprintName="Spookky" ReferencedContainer="container:Spookky.xcodeproj"/></BuildActionEntry></BuildActionEntries></BuildAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0"><BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="Spookky.app" BlueprintName="Spookky" ReferencedContainer="container:Spookky.xcodeproj"/></BuildableProductRunnable></LaunchAction>
  <ArchiveAction buildConfiguration="Distribution" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
