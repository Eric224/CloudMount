#!/usr/bin/env python3
"""Deterministic Xcode project; no external project generator; pinned Swift packages."""
from pathlib import Path
import hashlib,json,plistlib
root=Path(__file__).resolve().parent
release=json.loads((root.parent/'Release.json').read_text())
objects={}
def oid(name):return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
def add(label,isa,**kw):
 key=oid(label);objects[key]={'isa':isa,**kw};return key
def quote(value):return json.dumps(str(value),ensure_ascii=False)
def emit(value,indent=0):
 if isinstance(value,dict):return '{\n'+''.join('  '*(indent+1)+quote(k)+' = '+emit(v,indent+1)+';\n' for k,v in value.items())+'  '*indent+'}'
 if isinstance(value,list):return '(\n'+''.join('  '*(indent+1)+emit(v,indent+1)+',\n' for v in value)+'  '*indent+')'
 return quote(value)
common={'ARCHS':'arm64','ONLY_ACTIVE_ARCH':'YES','SDKROOT':'iphoneos','IPHONEOS_DEPLOYMENT_TARGET':'17.0','SWIFT_VERSION':'5.0','TARGETED_DEVICE_FAMILY':'1,2','DEVELOPMENT_TEAM':'Q7K9XTM528','CODE_SIGN_STYLE':'Automatic','SUPPORTED_PLATFORMS':'iphoneos iphonesimulator','SUPPORTS_MACCATALYST':'NO','SWIFT_STRICT_CONCURRENCY':'targeted','CLANG_ENABLE_MODULES':'YES','ENABLE_USER_SCRIPT_SANDBOXING':'YES','CURRENT_PROJECT_VERSION':release['build'],'MARKETING_VERSION':release['version'],'ENABLE_BITCODE':'NO'}
configIDs=[]
for cfg in ['Debug','Release']:
 b=dict(common);b.update({'SWIFT_OPTIMIZATION_LEVEL':'-Onone' if cfg=='Debug' else '-O','SWIFT_ACTIVE_COMPILATION_CONDITIONS':'DEBUG' if cfg=='Debug' else '', 'DEBUG_INFORMATION_FORMAT':'dwarf' if cfg=='Debug' else 'dwarf-with-dsym'})
 configIDs.append(add('project'+cfg,'XCBuildConfiguration',name=cfg,buildSettings=b))
projectConfigs=add('projectConfigs','XCConfigurationList',buildConfigurations=configIDs,defaultConfigurationIsVisible='0',defaultConfigurationName='Release')
package=add('package','XCLocalSwiftPackageReference',relativePath='..')
products=[];fileRefs=[];targets=[]
targetSpecs=[('CloudMountMobile','App','com.codex.cloudmount.mobile','com.apple.product-type.application'),('CloudMountProvider','Provider','com.codex.cloudmount.mobile.provider','com.apple.product-type.app-extension'),('CloudMountProviderUI','ProviderUI','com.codex.cloudmount.mobile.providerui','com.apple.product-type.app-extension'),('CloudMountMobileTests','Tests','com.codex.cloudmount.mobile.tests','com.apple.product-type.bundle.unit-test'),('CloudMountMobileUITests','UITests','com.codex.cloudmount.mobile.uitests','com.apple.product-type.bundle.ui-testing')]
for target,folder,bundle,kind in targetSpecs:
 suffix='.app' if folder=='App' else '.appex' if 'Provider' in folder else '.xctest'
 product=add(target+'product','PBXFileReference',explicitFileType='wrapper.application' if suffix=='.app' else 'wrapper.app-extension' if suffix=='.appex' else 'wrapper.cfbundle',path=target+suffix,sourceTree='BUILT_PRODUCTS_DIR');products.append(product)
 paths=list((root/folder).glob('*.swift'))
 if folder not in ['UITests']:
  paths+=list((root/'Shared').glob('*.swift'))
 if folder=='Tests':paths+=list((root/'Provider').glob('*.swift'))
 builds=[]
 for path in sorted(set(paths)):
  rel=str(path.relative_to(root));fid=add('file'+rel,'PBXFileReference',lastKnownFileType='sourcecode.swift',path=rel,sourceTree='SOURCE_ROOT')
  if fid not in fileRefs:fileRefs.append(fid)
  builds.append(add(target+rel,'PBXBuildFile',fileRef=fid))
 sources=add(target+'sources','PBXSourcesBuildPhase',buildActionMask='2147483647',files=builds,runOnlyForDeploymentPostprocessing='0')
 pd=add(target+'core','XCSwiftPackageProductDependency',productName='CloudMountMobileRuntime')
 frameworks=add(target+'frameworks','PBXFrameworksBuildPhase',buildActionMask='2147483647',files=[] if folder=='UITests' else [add(target+'linkcore','PBXBuildFile',productRef=pd)],runOnlyForDeploymentPostprocessing='0')
 resourceBuilds=[]
 if folder in ['App','Provider','ProviderUI']:
  for resource in sorted(list((root/'Resources').glob('*.lproj')) + ([root/'Resources/Licenses'] if folder=='App' else [])):
   rel=str(resource.relative_to(root));fid=add('resource'+rel,'PBXFileReference',lastKnownFileType='folder',path=rel,sourceTree='SOURCE_ROOT');
   if fid not in fileRefs:fileRefs.append(fid)
   resourceBuilds.append(add(target+rel,'PBXBuildFile',fileRef=fid))
 if folder=='App':
  fid=add('assets','PBXFileReference',lastKnownFileType='folder.assetcatalog',path='Resources/Assets.xcassets',sourceTree='SOURCE_ROOT');fileRefs.append(fid)
  resourceBuilds.append(add('assetsBuild','PBXBuildFile',fileRef=fid))
 phases=[sources,frameworks,add(target+'resources','PBXResourcesBuildPhase',buildActionMask='2147483647',files=resourceBuilds,runOnlyForDeploymentPostprocessing='0')]
 deps=[]
 if folder=='App':
  runtimeEmbed=add('embedMobileRuntime','PBXBuildFile',productRef=pd,settings={'ATTRIBUTES':['CodeSignOnCopy','RemoveHeadersOnCopy']})
  phases.append(add('embedRuntimePhase','PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='',dstSubfolderSpec='10',files=[runtimeEmbed],name='Embed Shared Runtime',runOnlyForDeploymentPostprocessing='0'))
  embedded=[]
  for extension in ['CloudMountProvider','CloudMountProviderUI']:
   embedded.append(add('embed'+extension,'PBXBuildFile',fileRef=oid(extension+'product'),settings={'ATTRIBUTES':['RemoveHeadersOnCopy']}))
   proxy=add('proxy'+extension,'PBXContainerItemProxy',containerPortal=oid('project'),proxyType='1',remoteGlobalIDString=oid(extension),remoteInfo=extension)
   deps.append(add('dependency'+extension,'PBXTargetDependency',target=oid(extension),targetProxy=proxy))
  phases.append(add('embeds','PBXCopyFilesBuildPhase',buildActionMask='2147483647',dstPath='',dstSubfolderSpec='13',files=embedded,name='Embed App Extensions',runOnlyForDeploymentPostprocessing='0'))
 if folder in ['Tests','UITests']:
  proxy=add(target+'proxy','PBXContainerItemProxy',containerPortal=oid('project'),proxyType='1',remoteGlobalIDString=oid('CloudMountMobile'),remoteInfo='CloudMountMobile')
  deps.append(add(target+'dependency','PBXTargetDependency',target=oid('CloudMountMobile'),targetProxy=proxy))
 configs=[]
 for cfg in ['Debug','Release']:
  settings={'PRODUCT_BUNDLE_IDENTIFIER':bundle,'PRODUCT_NAME':target,'INFOPLIST_FILE':folder+'/Info.plist','LD_RUNPATH_SEARCH_PATHS':['$(inherited)','@executable_path/Frameworks','@executable_path/../../Frameworks'],'GENERATE_INFOPLIST_FILE':'NO','CODE_SIGN_ENTITLEMENTS':folder+'/CloudMount.entitlements' if folder not in ['Tests','UITests'] else 'App/CloudMount.entitlements'}
  if folder in ['Tests','UITests']:settings.pop('CODE_SIGN_ENTITLEMENTS',None)
  if folder=='App':settings['ASSETCATALOG_COMPILER_APPICON_NAME']='AppIcon'
  if 'Provider' in folder:settings.update({'APPLICATION_EXTENSION_API_ONLY':'YES','SKIP_INSTALL':'YES'})
  if folder=='Tests':settings.update({'TEST_HOST':'$(BUILT_PRODUCTS_DIR)/CloudMountMobile.app/CloudMountMobile','BUNDLE_LOADER':'$(TEST_HOST)'})
  if folder=='UITests':settings.update({'TEST_TARGET_NAME':'CloudMountMobile'})
  configs.append(add(target+cfg,'XCBuildConfiguration',name=cfg,buildSettings=settings))
 cl=add(target+'configs','XCConfigurationList',buildConfigurations=configs,defaultConfigurationIsVisible='0',defaultConfigurationName='Release')
 targets.append(add(target,'PBXNativeTarget',buildConfigurationList=cl,buildPhases=phases,buildRules=[],dependencies=deps,name=target,productName=target,productReference=product,productType=kind,packageProductDependencies=[] if folder=='UITests' else [pd]))
prodGroup=add('products','PBXGroup',children=products,name='Products',sourceTree='<group>')
group=add('mainGroup','PBXGroup',children=fileRefs+[prodGroup],sourceTree='<group>')
project=add('project','PBXProject',attributes={'LastUpgradeCheck':'2700','TargetAttributes':{oid('CloudMountMobileTests'):{'TestTargetID':oid('CloudMountMobile')},oid('CloudMountMobileUITests'):{'TestTargetID':oid('CloudMountMobile')}}},buildConfigurationList=projectConfigs,compatibilityVersion='Xcode 14.0',developmentRegion='en',hasScannedForEncodings='0',knownRegions=['en','zh-Hant','zh-Hans'],mainGroup=group,productRefGroup=prodGroup,projectDirPath='',projectRoot='',targets=targets,packageReferences=[package])
proj=root/'CloudMountMobile.xcodeproj';proj.mkdir(exist_ok=True)
(proj/'project.pbxproj').write_text('// !$*UTF8*$!\n'+emit({'archiveVersion':'1','classes':{},'objectVersion':'56','objects':objects,'rootObject':project})+'\n')
schemes=proj/'xcshareddata/xcschemes';schemes.mkdir(parents=True,exist_ok=True)
def ref(name):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{oid(name)}" BuildableName="{name}.app" BlueprintName="{name}" ReferencedContainer="container:CloudMountMobile.xcodeproj"/>'
(schemes/'CloudMountMobile.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2700" version="1.7"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{ref('CloudMountMobile')}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO" parallelizable="NO">{ref('CloudMountMobileTests')}</TestableReference><TestableReference skipped="NO" parallelizable="NO">{ref('CloudMountMobileUITests')}</TestableReference></Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{ref('CloudMountMobile')}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"/><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
for target,folder,bundle,kind in targetSpecs:
 info={'CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','zh-Hant','zh-Hans'],'CFBundleDisplayName':'CloudMount','CFBundleExecutable':'$(EXECUTABLE_NAME)','CFBundleIdentifier':'$(PRODUCT_BUNDLE_IDENTIFIER)','CFBundleName':'$(PRODUCT_NAME)','CFBundlePackageType':'APPL' if folder=='App' else 'XPC!' if 'Provider' in folder else 'BNDL','CFBundleShortVersionString':release['version'],'CFBundleVersion':release['build'],'CloudMountDeveloper':release['developer'],'CloudMountEmail':release['email'],'CloudMountKeychainGroup':'Q7K9XTM528.com.codex.cloudmount.mobile.shared','NSLocalNetworkUsageDescription':'CloudMount connects to the NAS or storage server you choose on your local network.'}
 if folder=='App':info.update({'LSRequiresIPhoneOS':True,'UILaunchScreen':{},'UISupportedInterfaceOrientations':['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],'UISupportedInterfaceOrientations~ipad':['UIInterfaceOrientationPortrait','UIInterfaceOrientationPortraitUpsideDown','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],'CFBundleURLTypes':[{'CFBundleURLSchemes':['cloudmount']}],'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}})
 if folder=='Provider':info['NSExtension']={'NSExtensionPointIdentifier':'com.apple.fileprovider-nonui','NSExtensionPrincipalClass':'$(PRODUCT_MODULE_NAME).FileProviderExtension','NSExtensionFileProviderDocumentGroup':'group.com.codex.cloudmount.mobile','NSExtensionFileProviderSupportsEnumeration':True,'NSExtensionFileProviderSupportsFPFS':True,'NSExtensionFileProviderDownloadPipelineDepth':2,'NSExtensionFileProviderUploadPipelineDepth':1}
 if folder=='ProviderUI':info['NSExtension']={'NSExtensionPointIdentifier':'com.apple.fileprovider-actionsui','NSExtensionPrincipalClass':'$(PRODUCT_MODULE_NAME).ActionViewController','NSExtensionFileProviderActions':[{'NSExtensionFileProviderActionIdentifier':'com.codex.cloudmount.lock','NSExtensionFileProviderActionName':'Lock vault','NSExtensionFileProviderActionActivationRule':'SUBQUERY(fileproviderItems, $item, $item.userInfo.isVault == TRUE).@count > 0'},{'NSExtensionFileProviderActionIdentifier':'com.codex.cloudmount.unlock','NSExtensionFileProviderActionName':'Unlock vault','NSExtensionFileProviderActionActivationRule':'SUBQUERY(fileproviderItems, $item, $item.userInfo.isVault == TRUE).@count > 0'}],'NSExtensionFileProviderUIExtensionDocumentGroup':'group.com.codex.cloudmount.mobile'}
 (root/folder/'Info.plist').write_bytes(plistlib.dumps(info))
 if folder not in ['Tests','UITests']:
  (root/folder/'CloudMount.entitlements').write_bytes(plistlib.dumps({'com.apple.security.application-groups':['group.com.codex.cloudmount.mobile'],'keychain-access-groups':['Q7K9XTM528.com.codex.cloudmount.mobile.shared']}))
print(proj)
