// Deterministic, dependency-free Xcode project generator. Runs on Windows or Mac.
// It only writes the project it owns, and never deletes source files.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const ios = path.join(root, 'ios');
const projectDir = path.join(ios, 'PocketWorld.xcodeproj');
const uid = value => crypto.createHash('sha1').update(value).digest('hex').slice(0, 24).toUpperCase();
const quote = value => JSON.stringify(String(value));
const objects = new Map();
const ref = id => ({ _ref: id });
function add(key, value) { const id = uid(key); if(objects.has(id)) throw new Error(`Duplicate ${key}`); objects.set(id, value); return id; }
function scan(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, {withFileTypes:true}).sort((a,b)=>a.name.localeCompare(b.name)).flatMap(e=>{
    const p = path.join(dir,e.name);
    if (e.name.endsWith('.xcassets')) return [p];
    return e.isDirectory() ? scan(p) : [p];
  });
}
const fileRefs = [], testRefs = [], appSources=[], testSources=[], resources=[], testResources=[];
for (const base of ['PocketWorld','PocketWorldTests']) {
  for (const filename of scan(path.join(ios,base))) {
    const rel = path.relative(ios,filename).replaceAll('\\','/');
    // Real camera trajectories are local opt-in test data, never repository resources.
    if (rel === 'PocketWorldTests/Fixtures/sample-capture-cameras.json') continue;
    const ext = path.extname(filename);
    if(!['.swift','.metal','.json','.xcassets','.xcprivacy','.txt'].includes(ext)) continue;
    const type = {'.swift':'sourcecode.swift','.metal':'sourcecode.metal','.json':'text.json','.xcassets':'folder.assetcatalog','.xcprivacy':'text.xml','.txt':'text'}[ext];
    const f = add(`file:${rel}`, {isa:'PBXFileReference',lastKnownFileType:type,path:rel,sourceTree:'SOURCE_ROOT'});
    const b = add(`build:${rel}`, {isa:'PBXBuildFile',fileRef:ref(f)});
    (base==='PocketWorldTests' ? testRefs : fileRefs).push(ref(f));
    // Test fixtures (.json) are bundled as test resources, not compiled.
    // Metal shaders compile into the app's default.metallib (Sources phase).
    const compiled = ext==='.swift' || ext==='.metal';
    (base==='PocketWorldTests' ? (ext==='.swift' ? testSources : testResources) : compiled ? appSources : resources).push(ref(b));
  }
}
if (!appSources.length) throw new Error('No app Swift files yet. Generate after sources are written.');
const packageID = add('package:MetalSplatter',{isa:'XCRemoteSwiftPackageReference',repositoryURL:'https://github.com/scier/MetalSplatter',requirement:{kind:'revision',revision:'71ff248e3016ac43c0a9271e322538421b28c360'}});
const packageProducts=[], frameworkBuilds=[];
for (const name of ['MetalSplatter','SplatIO']) {
  const p = add(`product:${name}`,{isa:'XCSwiftPackageProductDependency',package:ref(packageID),productName:name});
  packageProducts.push(ref(p));
  frameworkBuilds.push(ref(add(`framework:${name}`,{isa:'PBXBuildFile',productRef:ref(p)})));
}
const appProduct = add('appProduct',{isa:'PBXFileReference',explicitFileType:'wrapper.application',includeInIndex:0,path:'PocketWorld.app',sourceTree:'BUILT_PRODUCTS_DIR'});
const testsProduct = add('testsProduct',{isa:'PBXFileReference',explicitFileType:'wrapper.cfbundle',includeInIndex:0,path:'PocketWorldTests.xctest',sourceTree:'BUILT_PRODUCTS_DIR'});
const productsGroup = add('productsGroup',{isa:'PBXGroup',children:[ref(appProduct),ref(testsProduct)],name:'Products',sourceTree:'<group>'});
const sourceGroup = add('sourceGroup',{isa:'PBXGroup',children:fileRefs,name:'PocketWorld',sourceTree:'<group>'});
const testsGroup = add('testsGroup',{isa:'PBXGroup',children:testRefs,name:'PocketWorldTests',sourceTree:'<group>'});
const mainGroup = add('mainGroup',{isa:'PBXGroup',children:[ref(sourceGroup),ref(testsGroup),ref(productsGroup)],sourceTree:'<group>'});
function phase(key,isa,files) {return ref(add(key,{isa,buildActionMask:2147483647,files,runOnlyForDeploymentPostprocessing:0}));}
const appPhases=[phase('appSources','PBXSourcesBuildPhase',appSources),phase('appFrameworks','PBXFrameworksBuildPhase',frameworkBuilds),phase('appResources','PBXResourcesBuildPhase',resources)];
const testsPhases=[phase('testSources','PBXSourcesBuildPhase',testSources),phase('testFrameworks','PBXFrameworksBuildPhase',[]),phase('testResources','PBXResourcesBuildPhase',testResources)];
const projectSettings = {
  ALWAYS_SEARCH_USER_PATHS:'NO',CLANG_ENABLE_MODULES:'YES',CLANG_ENABLE_OBJC_ARC:'YES',
  CLANG_WARN_DOCUMENTATION_COMMENTS:'YES',CLANG_WARN_UNREACHABLE_CODE:'YES',
  COPY_PHASE_STRIP:'NO',ENABLE_STRICT_OBJC_MSGSEND:'YES',GCC_C_LANGUAGE_STANDARD:'gnu17',
  IPHONEOS_DEPLOYMENT_TARGET:'18.0',SDKROOT:'iphoneos',SWIFT_VERSION:'5.0',SWIFT_STRICT_CONCURRENCY:'minimal'
};
// Optional signing team (e.g. POCKETWORLD_DEVELOPMENT_TEAM=ABCDE12345), so regenerating keeps device signing.
const team = /^[A-Z0-9]{10}$/.test(process.env.POCKETWORLD_DEVELOPMENT_TEAM ?? '') ? {DEVELOPMENT_TEAM:process.env.POCKETWORLD_DEVELOPMENT_TEAM} : {};
const appSettings = {
  ...team,
  ASSETCATALOG_COMPILER_APPICON_NAME:'AppIcon',CODE_SIGN_STYLE:'Automatic',CURRENT_PROJECT_VERSION:'1',
  GENERATE_INFOPLIST_FILE:'NO',MARKETING_VERSION:'0.1.0',PRODUCT_BUNDLE_IDENTIFIER:'com.pocketworld.mvp',
  PRODUCT_NAME:'$(TARGET_NAME)',SUPPORTED_PLATFORMS:'iphoneos iphonesimulator',SUPPORTS_MACCATALYST:'NO',
  TARGETED_DEVICE_FAMILY:'1',LD_RUNPATH_SEARCH_PATHS:['$(inherited)','@executable_path/Frameworks'],
  ENABLE_PREVIEWS:'YES',SWIFT_EMIT_LOC_STRINGS:'NO'
};
function configs(prefix,settings,extra={}) {
  const ids = ['Debug','Release'].map(name=>add(`${prefix}:${name}`,{
    isa:'XCBuildConfiguration',name,
    buildSettings:{...settings,...(name==='Debug'?{
      DEBUG_INFORMATION_FORMAT:'dwarf',ENABLE_TESTABILITY:'YES',ONLY_ACTIVE_ARCH:'YES',GCC_OPTIMIZATION_LEVEL:'0',
      SWIFT_ACTIVE_COMPILATION_CONDITIONS:'DEBUG $(inherited)',SWIFT_OPTIMIZATION_LEVEL:'-Onone'
    }:{DEBUG_INFORMATION_FORMAT:'dwarf-with-dsym',SWIFT_COMPILATION_MODE:'wholemodule',SWIFT_OPTIMIZATION_LEVEL:'-O',VALIDATE_PRODUCT:'YES'}),...(extra[name]||{})}
  }));
  return ref(add(`${prefix}:list`,{isa:'XCConfigurationList',buildConfigurations:ids.map(ref),defaultConfigurationIsVisible:0,defaultConfigurationName:'Release'}));
}
const projectConfig=configs('project',projectSettings);
const appConfig=configs('app',appSettings,{Debug:{INFOPLIST_FILE:'Config/Info-Debug.plist'},Release:{INFOPLIST_FILE:'Config/Info.plist'}});
const testConfig=configs('tests',{
  ...team,CODE_SIGN_STYLE:'Automatic',GENERATE_INFOPLIST_FILE:'YES',PRODUCT_BUNDLE_IDENTIFIER:'com.pocketworld.mvp.tests',
  PRODUCT_NAME:'$(TARGET_NAME)',TARGETED_DEVICE_FAMILY:'1',BUNDLE_LOADER:'$(TEST_HOST)',
  TEST_HOST:'$(BUILT_PRODUCTS_DIR)/PocketWorld.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/PocketWorld',
  LD_RUNPATH_SEARCH_PATHS:['$(inherited)','@executable_path/Frameworks','@loader_path/Frameworks']
});
const appTarget = add('appTarget',{isa:'PBXNativeTarget',buildConfigurationList:appConfig,buildPhases:appPhases,buildRules:[],dependencies:[],name:'PocketWorld',packageProductDependencies:packageProducts,productName:'PocketWorld',productReference:ref(appProduct),productType:'com.apple.product-type.application'});
const proxy = add('targetProxy',{isa:'PBXContainerItemProxy',containerPortal:ref(uid('project')),proxyType:1,remoteGlobalIDString:ref(appTarget),remoteInfo:'PocketWorld'});
const targetDependency = add('targetDependency',{isa:'PBXTargetDependency',target:ref(appTarget),targetProxy:ref(proxy)});
const testsTarget=add('testsTarget',{isa:'PBXNativeTarget',buildConfigurationList:testConfig,buildPhases:testsPhases,buildRules:[],dependencies:[ref(targetDependency)],name:'PocketWorldTests',productName:'PocketWorldTests',productReference:ref(testsProduct),productType:'com.apple.product-type.bundle.unit-test'});
const project = add('project',{
  isa:'PBXProject',attributes:{BuildIndependentTargetsInParallel:'YES',LastUpgradeCheck:'1630',TargetAttributes:{[appTarget]:{CreatedOnToolsVersion:'16.3'},[testsTarget]:{CreatedOnToolsVersion:'16.3',TestTargetID:ref(appTarget)}}},
  buildConfigurationList:projectConfig,compatibilityVersion:'Xcode 15.0',developmentRegion:'zh-Hans',hasScannedForEncodings:0,
  knownRegions:['en','Base','zh-Hans'],mainGroup:ref(mainGroup),packageReferences:[ref(packageID)],productRefGroup:ref(productsGroup),
  projectDirPath:'',projectRoot:'',targets:[ref(appTarget),ref(testsTarget)]
});
function render(v, indent=0) {
  if(v?._objects) {
    const groups=new Map();
    for(const [id,value] of objects) { if(!groups.has(value.isa))groups.set(value.isa,[]);groups.get(value.isa).push([id,value]); }
    return '{\n'+[...groups].sort(([a],[b])=>a.localeCompare(b)).map(([isa,entries])=>
      `\n/* Begin ${isa} section */\n`+entries.map(([id,value])=>`\t\t${id} /* ${value.name || value.productName || value.isa} */ = ${render(value,2)};`).join('\n')+`\n/* End ${isa} section */`
    ).join('\n')+'\n\t}';
  }
  if(v?._ref) {if(!objects.has(v._ref))throw new Error(`Dangling reference ${v._ref}`);return v._ref;}
  if(Array.isArray(v)) return `(\n${v.map(x=>'\t'.repeat(indent+1)+render(x,indent+1)+',').join('\n')}\n${'\t'.repeat(indent)})`;
  if(v && typeof v==='object')return `{\n${Object.entries(v).map(([k,x])=>'\t'.repeat(indent+1)+(/^[A-Za-z0-9_]+$/.test(k)?k:quote(k))+' = '+render(x,indent+1)+';').join('\n')}\n${'\t'.repeat(indent)}}`;
  return typeof v==='number' ? String(v) : /^[A-Za-z_][A-Za-z0-9_./]*$/.test(v) ? v : quote(v);
}
const data={archiveVersion:1,classes:{},objectVersion:60,objects:{_objects:true},rootObject:ref(project)};
fs.mkdirSync(projectDir,{recursive:true});
fs.writeFileSync(path.join(projectDir,'project.pbxproj'),'// !$*UTF8*$!\n'+render(data)+'\n');
const workspaceDir=path.join(projectDir,'project.xcworkspace');
const resolvedDir=path.join(workspaceDir,'xcshareddata','swiftpm');fs.mkdirSync(resolvedDir,{recursive:true});
fs.writeFileSync(path.join(workspaceDir,'contents.xcworkspacedata'),'<?xml version="1.0" encoding="UTF-8"?>\n<Workspace version="1.0"><FileRef location="self:"></FileRef></Workspace>\n');
// Prepared from upstream tag hashes. Actual package resolution still must run on the Mac.
fs.writeFileSync(path.join(resolvedDir,'Package.resolved'),JSON.stringify({version:2,pins:[
  {identity:'metalsplatter',kind:'remoteSourceControl',location:'https://github.com/scier/MetalSplatter',state:{revision:'71ff248e3016ac43c0a9271e322538421b28c360'}},
  {identity:'spz-swift',kind:'remoteSourceControl',location:'https://github.com/scier/spz-swift.git',state:{revision:'e2410c91bceba2539c11157ad92e488ef6e16416',version:'2.1.0'}},
  {identity:'swift-argument-parser',kind:'remoteSourceControl',location:'https://github.com/apple/swift-argument-parser',state:{revision:'cdd0ef3755280949551dc26dee5de9ddeda89f54',version:'1.6.2'}}
]},null,2)+'\n');
const schemeDir=path.join(projectDir,'xcshareddata','xcschemes');fs.mkdirSync(schemeDir,{recursive:true});
const buildRef=(id,name)=>`<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="${id}" BuildableName="${name==='PocketWorld'?'PocketWorld.app':'PocketWorldTests.xctest'}" BlueprintName="${name}" ReferencedContainer="container:PocketWorld.xcodeproj"/>`;
fs.writeFileSync(path.join(schemeDir,'PocketWorld.xcscheme'),`<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="1630" version="1.3">
 <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries>
  <BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">${buildRef(appTarget,'PocketWorld')}</BuildActionEntry>
 </BuildActionEntries></BuildAction>
 <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">${buildRef(testsTarget,'PocketWorldTests')}</TestableReference></Testables></TestAction>
 <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">${buildRef(appTarget,'PocketWorld')}</BuildableProductRunnable></LaunchAction>
 <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">${buildRef(appTarget,'PocketWorld')}</BuildableProductRunnable></ProfileAction>
 <AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>`);
console.log(`Generated ios/PocketWorld.xcodeproj: ${appSources.length} Swift sources, ${testSources.length} test sources, ${resources.length} resources; pinned native renderer.`);
