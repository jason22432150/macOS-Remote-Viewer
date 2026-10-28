#!/usr/bin/env python3
"""產生 MacRemoteViewer.xcodeproj。IDs 固定以便 diff。

Debug／Release 關閉 SWIFT_ENABLE_BATCH_MODE：Xcode 分批編譯會讓 InputRouter
找不到同 module 的 mapping 型別（cannot find in scope）。
"""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "MacRemoteViewer.xcodeproj"

SWIFT = [
    "App/MacRemoteViewerApp.swift",
    "App/AppModel.swift",
    "App/ContentView.swift",
    "App/RemoteSessionView.swift",
    "App/SettingsView.swift",
    "Core/Connection/SessionError.swift",
    "Core/Connection/SessionState.swift",
    "Core/Connection/ConnectionProfile.swift",
    "Core/Connection/SpiceEngine.swift",
    "Core/Connection/GuestPointerMapping.swift",
    "Core/Connection/GuestResolutionPolicy.swift",
    "Core/Connection/SessionStatusText.swift",
    "Core/Settings/AppPreferences.swift",
    "Core/Settings/AppSettings.swift",
    "Core/Settings/L10n.swift",
    "Diagnostics/FileLogWriter.swift",
    "Core/Connection/KeyboardMapping.swift",
    "Core/Connection/MouseButtonMapping.swift",
    "Core/VVFile/HotKeyParser.swift",
    "Core/VVFile/VVParser.swift",
    "Core/VVFile/SourceFilePolicy.swift",
    "Core/VVFile/IncomingURLBuffer.swift",
    "Core/VVFile/WindowPresentationPolicy.swift",
    "Core/VVFile/VVFileImporter.swift",
    "Features/RemoteSession/SessionController.swift",
    "Diagnostics/DiagnosticsLog.swift",
    "Engine/StubSpiceEngine.swift",
    "Engine/CocoaSpicePasteboard.swift",
    "Engine/SpiceEngineAdapter.swift",
    "Platform/macOS/InputRouter.swift",
    "Platform/macOS/RemoteDisplayView.swift",
]
OBJC = [
    "Engine/CSConnection+PVEConfig.m",
]
HEADERS = [
    "Engine/MacRemoteViewer-Bridging-Header.h",
    "Engine/CSConnection+PVEConfig.h",
]

IDS = {
    "project": "A10000000000000000000001",
    "target": "A10000000000000000000002",
    "sources": "A10000000000000000000003",
    "frameworks": "A10000000000000000000004",
    "resources": "A10000000000000000000005",
    "config_list_project": "A10000000000000000000006",
    "config_list_target": "A10000000000000000000007",
    "debug_project": "A10000000000000000000008",
    "release_project": "A10000000000000000000009",
    "debug_target": "A1000000000000000000000A",
    "release_target": "A1000000000000000000000B",
    "main_group": "A1000000000000000000000C",
    "src_group": "A1000000000000000000000D",
    "products_group": "A10000000000000000000010",
    "product": "A10000000000000000000011",
    "package_cocoaspice": "A10000000000000000000012",
    "product_cocoaspice": "A10000000000000000000014",
    "framework_cocoaspice": "A10000000000000000000015",
    "xcconfig": "A10000000000000000000017",
    "entitlements": "A10000000000000000000018",
    "info": "A10000000000000000000019",
}


def file_id(path: str, kind: str) -> str:
    value = 0
    for ch in f"{kind}:{path}":
        value = (value * 131 + ord(ch)) & 0xFFFFFFFFFFFF
    ident = f"B{value:023X}"[-24:]
    if len(ident) != 24 or any(ch not in "0123456789ABCDEF" for ch in ident):
        raise SystemExit(f"PBX id 必須是 24 碼 hex：{ident}")
    return ident


def main() -> None:
    if not (ROOT / "ThirdParty" / "CocoaSpice" / "Package.swift").exists():
        print(
            "warning: 缺少 ThirdParty/CocoaSpice，請先執行 BuildSupport/bootstrap-cocoaspice.sh",
            file=__import__("sys").stderr,
        )
    refs = []
    build_files = []
    source_entries = []
    group_children = []

    def add_ref(path: str, file_type: str) -> str:
        ident = file_id(path, "ref")
        name = Path(path).name
        refs.append(
            f'\t\t{ident} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = {file_type}; path = "{path}"; sourceTree = "<group>"; }};\n'
        )
        group_children.append(f'\t\t\t\t{ident} /* {name} */,\n')
        return ident

    def add_source(path: str, file_type: str) -> None:
        ref = add_ref(path, file_type)
        bf = file_id(path, "build")
        name = Path(path).name
        build_files.append(
            f'\t\t{bf} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};\n'
        )
        source_entries.append(f'\t\t\t\t{bf} /* {name} in Sources */,\n')

    for path in SWIFT:
        add_source(path, "sourcecode.swift")
    for path in OBJC:
        add_source(path, "sourcecode.c.objc")
    for path in HEADERS:
        add_ref(path, "sourcecode.c.h")

    info_ref = add_ref("App/Info.plist", "text.plist.xml")
    ent_ref = add_ref("App/MacRemoteViewer.entitlements", "text.plist.entitlements")

    refs.append(
        f'\t\t{IDS["xcconfig"]} /* Generated.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; name = Generated.xcconfig; path = BuildSupport/Generated.xcconfig; sourceTree = "<group>"; }};\n'
    )
    refs.append(
        f'\t\t{IDS["product"]} /* Mac Remote Viewer.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = "Mac Remote Viewer.app"; sourceTree = BUILT_PRODUCTS_DIR; }};\n'
    )

    cocoaspice_build = (
        f'\t\t{IDS["framework_cocoaspice"]} /* CocoaSpiceNoUsb in Frameworks */ = '
        f'{{isa = PBXBuildFile; productRef = {IDS["product_cocoaspice"]} /* CocoaSpiceNoUsb */; }};\n'
    )

    pbxproj = f'''// !$*UTF8*$!
{{
	archiveVersion = 1;
	classes = {{
	}};
	objectVersion = 60;
	objects = {{

/* Begin PBXBuildFile section */
{''.join(build_files)}{cocoaspice_build}/* End PBXBuildFile section */

/* Begin PBXFileReference section */
{''.join(refs)}/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{IDS["frameworks"]} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
				{IDS["framework_cocoaspice"]} /* CocoaSpiceNoUsb in Frameworks */,
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXGroup section */
		{IDS["main_group"]} = {{
			isa = PBXGroup;
			children = (
				{IDS["src_group"]} /* MacRemoteViewer */,
				{IDS["xcconfig"]} /* Generated.xcconfig */,
				{IDS["products_group"]} /* Products */,
			);
			sourceTree = "<group>";
		}};
		{IDS["src_group"]} /* MacRemoteViewer */ = {{
			isa = PBXGroup;
			children = (
{''.join(group_children)}			);
			path = MacRemoteViewer;
			sourceTree = "<group>";
		}};
		{IDS["products_group"]} /* Products */ = {{
			isa = PBXGroup;
			children = (
				{IDS["product"]} /* Mac Remote Viewer.app */,
			);
			name = Products;
			sourceTree = "<group>";
		}};
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{IDS["target"]} /* MacRemoteViewer */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {IDS["config_list_target"]} /* Build configuration list for PBXNativeTarget "MacRemoteViewer" */;
			buildPhases = (
				{IDS["sources"]} /* Sources */,
				{IDS["frameworks"]} /* Frameworks */,
				{IDS["resources"]} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = MacRemoteViewer;
			packageProductDependencies = (
				{IDS["product_cocoaspice"]} /* CocoaSpiceNoUsb */,
			);
			productName = "Mac Remote Viewer";
			productReference = {IDS["product"]} /* Mac Remote Viewer.app */;
			productType = "com.apple.product-type.application";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{IDS["project"]} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
				LastSwiftUpdateCheck = 2700;
				LastUpgradeCheck = 2700;
				TargetAttributes = {{
					{IDS["target"]} = {{
						CreatedOnToolsVersion = 27.1;
					}};
				}};
			}};
			buildConfigurationList = {IDS["config_list_project"]} /* Build configuration list for PBXProject "MacRemoteViewer" */;
			compatibilityVersion = "Xcode 15.0";
			developmentRegion = "zh-Hant";
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
				"zh-Hant",
			);
			mainGroup = {IDS["main_group"]};
			packageReferences = (
				{IDS["package_cocoaspice"]} /* XCLocalSwiftPackageReference "ThirdParty/CocoaSpice" */,
			);
			productRefGroup = {IDS["products_group"]} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{IDS["target"]} /* MacRemoteViewer */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{IDS["resources"]} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{IDS["sources"]} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{''.join(source_entries)}			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{IDS["debug_project"]} /* Debug */ = {{
			isa = XCBuildConfiguration;
			baseConfigurationReference = {IDS["xcconfig"]} /* Generated.xcconfig */;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				COPY_PHASE_STRIP = NO;
				DEBUG_INFORMATION_FORMAT = dwarf;
				ENABLE_TESTABILITY = YES;
				ONLY_ACTIVE_ARCH = YES;
				SDKROOT = macosx;
				SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)";
				SWIFT_ENABLE_BATCH_MODE = NO;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 6.0;
			}};
			name = Debug;
		}};
		{IDS["release_project"]} /* Release */ = {{
			isa = XCBuildConfiguration;
			baseConfigurationReference = {IDS["xcconfig"]} /* Generated.xcconfig */;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym";
				SDKROOT = macosx;
				SWIFT_COMPILATION_MODE = wholemodule;
				SWIFT_ENABLE_BATCH_MODE = NO;
				SWIFT_VERSION = 6.0;
			}};
			name = Release;
		}};
		{IDS["debug_target"]} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_ENTITLEMENTS = MacRemoteViewer/App/MacRemoteViewer.entitlements;
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = NO;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = MacRemoteViewer/App/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.macremoteviewer.app;
				PRODUCT_NAME = "Mac Remote Viewer";
				SWIFT_OBJC_BRIDGING_HEADER = "MacRemoteViewer/Engine/MacRemoteViewer-Bridging-Header.h";
				SWIFT_VERSION = 6.0;
			}};
			name = Debug;
		}};
		{IDS["release_target"]} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CODE_SIGN_ENTITLEMENTS = MacRemoteViewer/App/MacRemoteViewer.entitlements;
				CODE_SIGN_STYLE = Automatic;
				COMBINE_HIDPI_IMAGES = YES;
				CURRENT_PROJECT_VERSION = 1;
				ENABLE_HARDENED_RUNTIME = NO;
				GENERATE_INFOPLIST_FILE = NO;
				INFOPLIST_FILE = MacRemoteViewer/App/Info.plist;
				LD_RUNPATH_SEARCH_PATHS = (
					"$(inherited)",
					"@executable_path/../Frameworks",
				);
				MARKETING_VERSION = 0.1.0;
				PRODUCT_BUNDLE_IDENTIFIER = com.macremoteviewer.app;
				PRODUCT_NAME = "Mac Remote Viewer";
				SWIFT_OBJC_BRIDGING_HEADER = "MacRemoteViewer/Engine/MacRemoteViewer-Bridging-Header.h";
				SWIFT_VERSION = 6.0;
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{IDS["config_list_project"]} /* Build configuration list for PBXProject "MacRemoteViewer" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{IDS["debug_project"]} /* Debug */,
				{IDS["release_project"]} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		}};
		{IDS["config_list_target"]} /* Build configuration list for PBXNativeTarget "MacRemoteViewer" */ = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{IDS["debug_target"]} /* Debug */,
				{IDS["release_target"]} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Debug;
		}};
/* End XCConfigurationList section */

/* Begin XCLocalSwiftPackageReference section */
		{IDS["package_cocoaspice"]} /* XCLocalSwiftPackageReference "ThirdParty/CocoaSpice" */ = {{
			isa = XCLocalSwiftPackageReference;
			relativePath = ThirdParty/CocoaSpice;
		}};
/* End XCLocalSwiftPackageReference section */

/* Begin XCSwiftPackageProductDependency section */
		{IDS["product_cocoaspice"]} /* CocoaSpiceNoUsb */ = {{
			isa = XCSwiftPackageProductDependency;
			package = {IDS["package_cocoaspice"]} /* XCLocalSwiftPackageReference "ThirdParty/CocoaSpice" */;
			productName = CocoaSpiceNoUsb;
		}};
/* End XCSwiftPackageProductDependency section */

	}};
	rootObject = {IDS["project"]} /* Project object */;
}}
'''
    PROJECT.mkdir(parents=True, exist_ok=True)
    (PROJECT / "project.pbxproj").write_text(pbxproj)
    workspace = PROJECT / "project.xcworkspace"
    workspace.mkdir(parents=True, exist_ok=True)
    (workspace / "contents.xcworkspacedata").write_text(
        """<?xml version="1.0" encoding="UTF-8"?>
<Workspace
   version = "1.0">
   <FileRef
      location = "self:">
   </FileRef>
</Workspace>
"""
    )
    scheme_dir = PROJECT / "xcshareddata" / "xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    (scheme_dir / "MacRemoteViewer.xcscheme").write_text(
        f"""<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "2710"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{IDS['target']}"
               BuildableName = "Mac Remote Viewer.app"
               BlueprintName = "MacRemoteViewer"
               ReferencedContainer = "container:MacRemoteViewer.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{IDS['target']}"
            BuildableName = "Mac Remote Viewer.app"
            BlueprintName = "MacRemoteViewer"
            ReferencedContainer = "container:MacRemoteViewer.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{IDS['target']}"
            BuildableName = "Mac Remote Viewer.app"
            BlueprintName = "MacRemoteViewer"
            ReferencedContainer = "container:MacRemoteViewer.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
"""
    )
    print(f"wrote {PROJECT / 'project.pbxproj'}")


def _self_check_ids() -> None:
    for path in SWIFT + OBJC + HEADERS + ["App/Info.plist", "App/MacRemoteViewer.entitlements"]:
        for kind in ("ref", "build"):
            file_id(path, kind)


if __name__ == "__main__":
    _self_check_ids()
    main()
