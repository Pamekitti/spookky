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
for path in sorted((ROOT / "App").rglob("*.swift")):
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
helper_script = 'set -eu\ncd "$SRCROOT"\nhelper_configuration=release\nif [ "$CONFIGURATION" = Debug ]; then helper_configuration=debug; fi\n/usr/bin/swift build -c "$helper_configuration" --jobs 2 --product spookky-launch\n/usr/bin/swift build -c "$helper_configuration" --jobs 2 --product spookky-runtime-check\nfor helper in spookky-launch spookky-runtime-check; do\n  destination="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/$helper"\n  cp ".build/$helper_configuration/$helper" "$destination.next"\n  mv -f "$destination.next" "$destination"\ndone\ntest -x .cache/runtime/bin/tmux\ndestination="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/tmux"\ncp .cache/runtime/bin/tmux "$destination.next"\nmv -f "$destination.next" "$destination"\ncp -R .cache/runtime/share/terminfo/. "$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/terminfo/"\n'
helper_phase = obj("helper", f'isa = PBXShellScriptBuildPhase; alwaysOutOfDate = 1; buildActionMask = 2147483647; files = (); inputPaths = (); outputPaths = ("$(TARGET_BUILD_DIR)/$(EXECUTABLE_FOLDER_PATH)/spookky-launch"); runOnlyForDeploymentPostprocessing = 0; shellPath = /bin/sh; shellScript = {quote(helper_script)};')
app_ref = obj("app", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = "Spookky.app"; sourceTree = BUILT_PRODUCTS_DIR;')
products_group = obj("products-group", f'isa = PBXGroup; name = Products; children = ({app_ref}); sourceTree = "<group>";')
main_group = obj("main-group", f'isa = PBXGroup; children = ({",".join(file_refs + [framework_ref, products_group])}); sourceTree = "<group>";')

settings = {
    "MACOSX_DEPLOYMENT_TARGET": "14.0", "SDKROOT": "macosx", "ARCHS": "arm64",
    "SWIFT_VERSION": "5.0", "SWIFT_STRICT_CONCURRENCY": "minimal",
    "SPOOKKY_INSTANCE_ID": "standalone", "PRODUCT_NAME": "Spookky", "PRODUCT_BUNDLE_IDENTIFIER": "dev.spookky.m0",
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
# The harness compiles shared production components plus private diagnostic drivers.
def extra_sources(label, paths):
    builds = []
    for path in paths:
        relative = path.relative_to(ROOT)
        ref = obj(label + str(relative), f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {quote(relative)}; sourceTree = SOURCE_ROOT;')
        builds.append(obj(label + "build" + str(relative), f"isa = PBXBuildFile; fileRef = {ref};"))
    return phase(label + "sources", "PBXSourcesBuildPhase", builds)

def extra_configs(label, values):
    result = []
    for mode in ["Debug", "Release"]:
        current = dict(settings, **values)
        current["SWIFT_OPTIMIZATION_LEVEL"] = "-Onone" if mode == "Debug" else "-O"
        body = " ".join(f"{key} = {quote(value)};" for key, value in current.items())
        result.append(obj(label + mode, f"isa = XCBuildConfiguration; name = {mode}; buildSettings = {{{body}}};"))
    return obj(label + "configs", f"isa = XCConfigurationList; buildConfigurations = ({','.join(result)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")

harness_sources = extra_sources("harness", sorted(p for p in (ROOT / "App").rglob("*.swift") if p.name != "AppDelegate.swift") + sorted((ROOT / "Tests/NativeHarness").glob("*.swift")))
harness_configs = extra_configs("harness", dict(PRODUCT_NAME="SpookkyHarness", PRODUCT_MODULE_NAME="SpookkyHarness", PRODUCT_BUNDLE_IDENTIFIER="dev.spookky.harness.$(SPOOKKY_INSTANCE_ID)", SPOOKKY_DISPLAY_NAME="Spookky Harness", SWIFT_ACTIVE_COMPILATION_CONDITIONS="SPOOKKY_HARNESS", ENABLE_TESTABILITY="YES"))
harness_ref = obj("harness-app", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = "SpookkyHarness.app"; sourceTree = BUILT_PRODUCTS_DIR;')
harness_target = obj("harness-target", f'isa = PBXNativeTarget; name = SpookkyHarness; productName = SpookkyHarness; productReference = {harness_ref}; productType = "com.apple.product-type.application"; buildConfigurationList = {harness_configs}; buildPhases = ({harness_sources},{frameworks_phase},{resources_phase},{helper_phase}); buildRules = (); dependencies = (); packageProductDependencies = ({",".join(products)});')
test_sources = extra_sources("native-tests", sorted((ROOT / "Tests/SpookkyNativeTests").glob("*.swift")) + [ROOT / "Tests/Support/FixtureAssertions.swift"])
test_configs = extra_configs("native-tests", dict(PRODUCT_NAME="SpookkyNativeTests", PRODUCT_MODULE_NAME="SpookkyNativeTests", PRODUCT_BUNDLE_IDENTIFIER="dev.spookky.native-tests.$(SPOOKKY_INSTANCE_ID)", GENERATE_INFOPLIST_FILE="YES", INFOPLIST_FILE="", TEST_HOST="$(BUILT_PRODUCTS_DIR)/SpookkyHarness.app/Contents/MacOS/SpookkyHarness", BUNDLE_LOADER="$(TEST_HOST)", LD_RUNPATH_SEARCH_PATHS="$(inherited) @loader_path/../Frameworks @executable_path/../Frameworks"))
test_ref = obj("native-tests-bundle", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; path = "SpookkyNativeTests.xctest"; sourceTree = BUILT_PRODUCTS_DIR;')
dependency = obj("harness-dependency", f"isa = PBXTargetDependency; target = {harness_target};")
contract_ref = obj("native-contract", 'isa = PBXFileReference; lastKnownFileType = text.json; path = "Tests/Inventory/native-assertions.json"; sourceTree = SOURCE_ROOT;')
contract_build = obj("native-contract-build", f"isa = PBXBuildFile; fileRef = {contract_ref};")
test_resources = phase("native-test-resources", "PBXResourcesBuildPhase", [contract_build])
test_target = obj("native-tests-target", f'isa = PBXNativeTarget; name = SpookkyNativeTests; productName = SpookkyNativeTests; productReference = {test_ref}; productType = "com.apple.product-type.bundle.unit-test"; buildConfigurationList = {test_configs}; buildPhases = ({test_sources},{test_resources}); buildRules = (); dependencies = ({dependency});')
project = obj("project", f'isa = PBXProject; attributes = {{LastUpgradeCheck = 2700;}}; buildConfigurationList = {config_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en,Base); mainGroup = {main_group}; productRefGroup = {products_group}; projectDirPath = ""; projectRoot = ""; targets = ({target},{harness_target},{test_target}); packageReferences = ({package},{sparkle});')
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

reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{harness_target}" BuildableName="SpookkyHarness.app" BlueprintName="SpookkyHarness" ReferencedContainer="container:Spookky.xcodeproj"/>'
test_reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="SpookkyNativeTests.xctest" BlueprintName="SpookkyNativeTests" ReferencedContainer="container:Spookky.xcodeproj"/>'
(scheme_dir / "SpookkyHarness.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="NO" buildForArchiving="NO" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<TestAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO" parallelizable="NO">{test_reference}</TestableReference></Testables></TestAction>
<LaunchAction buildConfiguration="Release" launchStyle="0" useCustomWorkingDirectory="NO"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
</Scheme>
''')
