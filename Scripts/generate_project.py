#!/usr/bin/env python3
"""Generate the dependency-free Xcode app project; source files remain ordinary Swift."""
import hashlib, json
from pathlib import Path
root = Path(__file__).resolve().parents[1]
project = root / 'AutoDroid.xcodeproj'
project.mkdir(exist_ok=True)
def uid(s): return hashlib.sha1(s.encode()).hexdigest()[:24].upper()
def q(s): return json.dumps(s)
objects = {}
def obj(name, body):
    objects[uid(name)] = body
    return uid(name)
sources = sorted(root.glob('Sources/Core/*.swift')) + sorted(root.glob('App/*.swift'))
resources = [root/'Resources/selftest.json', root/'Resources/Assets.xcassets']
refs, builds, resource_builds = [], [], []
for f in sources + resources:
    rel = str(f.relative_to(root)); ref = obj(rel, f'isa = PBXFileReference; path = {q(rel)}; sourceTree = "<group>"; lastKnownFileType = '+ ('sourcecode.swift' if f.suffix == '.swift' else 'folder.assetcatalog' if f.suffix == '.xcassets' else 'text.json' if f.suffix == '.json' else 'text.plist.xml') + ';')
    refs.append(ref)
    b = obj('build:'+rel, f'isa = PBXBuildFile; fileRef = {ref};')
    (builds if f in sources else resource_builds).append(b)
product = obj('product', 'isa = PBXFileReference; explicitFileType = wrapper.application; path = AutoDroid.app; sourceTree = BUILT_PRODUCTS_DIR;')
products = obj('products', f'isa = PBXGroup; children = ({product},); name = Products; sourceTree = "<group>";')
group = obj('group', f'isa = PBXGroup; children = ({",".join(refs+[products])},); sourceTree = "<group>";')
source_phase = obj('sources', f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)},); runOnlyForDeploymentPostprocessing = 0;')
resource_phase = obj('resources', f'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(resource_builds)},); runOnlyForDeploymentPostprocessing = 0;')
framework_phase = obj('frameworks', 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
configs, target_configs = [], []
for mode in ['Debug', 'Release']:
    settings = {'SDKROOT':'iphoneos', 'IPHONEOS_DEPLOYMENT_TARGET':'17.0', 'CLANG_ENABLE_MODULES':'YES', 'SWIFT_VERSION':'5.0', 'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if mode=='Debug' else '-O', 'DEBUG_INFORMATION_FORMAT':'dwarf', 'ENABLE_USER_SCRIPT_SANDBOXING':'YES'}
    if mode=='Debug': settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS']='DEBUG'
    configs.append(obj('config:'+mode, 'isa = XCBuildConfiguration; name = '+mode+'; buildSettings = {'+' '.join(f'{k} = {q(v)};' for k,v in settings.items())+'};'))
    settings = {'PRODUCT_NAME':'AutoDroid', 'PRODUCT_BUNDLE_IDENTIFIER':'com.liuzhenyu.autodroid.ios', 'INFOPLIST_FILE':'Resources/Info.plist', 'CODE_SIGN_STYLE':'Automatic', 'DEVELOPMENT_TEAM':'2YQY9YF8B8', 'TARGETED_DEVICE_FAMILY':'1,2', 'SUPPORTED_PLATFORMS':'iphoneos iphonesimulator', 'ASSETCATALOG_COMPILER_APPICON_NAME':'AppIcon', 'GENERATE_INFOPLIST_FILE':'NO', 'SWIFT_EMIT_LOC_STRINGS':'YES'}
    target_configs.append(obj('targetconfig:'+mode, 'isa = XCBuildConfiguration; name = '+mode+'; buildSettings = {'+' '.join(f'{k} = {q(v)};' for k,v in settings.items())+'};'))
config_list = obj('configs', f'isa = XCConfigurationList; buildConfigurations = ({",".join(configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target_config_list = obj('targetconfigs', f'isa = XCConfigurationList; buildConfigurations = ({",".join(target_configs)},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
target = obj('target', f'isa = PBXNativeTarget; name = AutoDroid; productName = AutoDroid; productType = "com.apple.product-type.application"; productReference = {product}; buildConfigurationList = {target_config_list}; buildPhases = ({source_phase},{framework_phase},{resource_phase},); buildRules = (); dependencies = ();')
p = obj('project', f'isa = PBXProject; attributes = {{LastUpgradeCheck = 1600; TargetAttributes = {{{target} = {{ProvisioningStyle = Automatic;}};}};}}; buildConfigurationList = {config_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; knownRegions = (en, Base, "zh-Hans"); mainGroup = {group}; productRefGroup = {products}; projectDirPath = ""; projectRoot = ""; targets = ({target},);')
(project/'project.pbxproj').write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n'+ '\n'.join(f'{k} = {{{v}}};' for k,v in objects.items()) +f'\n}}; rootObject = {p}; }}\n')
scheme = project/'xcshareddata/xcschemes'; scheme.mkdir(parents=True,exist_ok=True)
ref = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="AutoDroid.app" BlueprintName="AutoDroid" ReferencedContainer="container:AutoDroid.xcodeproj"/>'
(scheme/'AutoDroid.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref}</BuildActionEntry></BuildActionEntries></BuildAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
print(project)
