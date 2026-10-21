import Cocoa
import SwiftUI
import UniformTypeIdentifiers

let ink = Color(red:0.06,green:0.06,blue:0.07)
let accent = Color(red:0.98,green:0.29,blue:0.23)
let paper = Color(red:0.95,green:0.945,blue:0.93)
let rule = Color.black.opacity(0.18)
let roles = ["Full logo", "Symbol", "Wordmark"]
let creatorWebsite:URL? = {
 guard let file=Bundle.main.url(forResource:"branding",withExtension:"json"),let data=try? Data(contentsOf:file),let values=(try? JSONSerialization.jsonObject(with:data)) as? [String:String],let address=values["website"], !address.isEmpty else{return nil}
 return URL(string:address)
}()
struct Board: Decodable, Identifiable { var index:Int; var name:String; var thumbnail:String; var id:Int {index} }
struct Inspection: Decodable { var source:String; var layouts:[Board]; var warnings:[String] }
struct Artwork { var source:String; var index:Int; var thumbnail:String; var boardName:String }
struct ExportFile: Decodable, Identifiable {
 var id:String; var layout:Int; var role:String; var variant:String; var mode:String; var format:String; var size:Int?; var path:String; var thumbnail:String; var group:String?; var label:String?
 var title:String { group ?? variant.replacingOccurrences(of:"-",with:" ").capitalized }
 var detail:String { label ?? mode.uppercased() + (size.map {" · \($0) px wide"} ?? " · vector") }
}
struct BrandColour: Decodable, Identifiable { var hex:String; var rgb:[Int]; var cmyk:[Int]; var items:[String]; var id:String {hex} }
struct Prepared: Decodable { var prepared:String; var files:[ExportFile]; var warnings:[String]; var checks:[String]?; var colours:[BrandColour]? }
struct ICCProfile: Decodable, Hashable { var name:String; var path:String }
struct ProfileList: Decodable { var profiles:[ICCProfile] }
struct Reopened: Decodable {
 struct Item: Decodable { var role:String; var source:String; var index:Int; var thumbnail:String; var boardName:String; var missing:Bool }
 var items:[Item]; var warnings:[String]
}
// Everything on the options page plus the filename pattern; saved as presets and with recent projects.
struct Settings: Codable { var formats:[String]; var intent:String; var variants:[String]; var sizes:[Int]; var padding:Int; var custom:String; var outline:Bool; var extras:[String]; var profile:String; var template:String }
struct Preset: Codable, Identifiable { var name:String; var settings:Settings; var id:String {name} }
struct GuideOptions: Codable { var colours=true; var usage=true; var pdf=true; var minDigital=0; var minPrint=0; var notes=""; var pantone:[String:String]=[:] }
struct RecentItem: Codable { var role:String; var source:String; var index:Int }
struct RecentProject: Codable, Identifiable { var id:UUID; var brand:String; var output:String; var date:Date; var baseRoles:[String]; var extraRoles:[String]; var items:[RecentItem]; var settings:Settings; var guide:GuideOptions }
struct AppUpdate { var version:String; var url:URL }
enum Store {
 static let folder:URL = {let base=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Logo Parcel",isDirectory:true);try? FileManager.default.createDirectory(at:base,withIntermediateDirectories:true);return base}()
 static func load<T:Decodable>(_ name:String,as type:T.Type)->T? {
  guard let data=try? Data(contentsOf:folder.appendingPathComponent(name)) else{return nil}
  let d=JSONDecoder();d.dateDecodingStrategy = .iso8601;return try? d.decode(T.self,from:data)
 }
 static func save<T:Encodable>(_ value:T,_ name:String){
  let e=JSONEncoder();e.dateEncodingStrategy = .iso8601;e.outputFormatting = .prettyPrinted
  if let data=try? e.encode(value){try? data.write(to:folder.appendingPathComponent(name),options:.atomic)}
 }
}
func slug(_ value:String)->String { let s=value.replacingOccurrences(of:"[^a-zA-Z0-9_-]+",with:"-",options:.regularExpression).trimmingCharacters(in:CharacterSet(charactersIn:"-")); return s.isEmpty ? "Logo" : String(s.prefix(90)) }
struct Delivered: Decodable { var folder:String; var zip:String; var count:Int; var warnings:[String] }
struct ProgressReport: Decodable { var message:String; var completed:Int; var total:Int }
struct EngineError: Decodable {var error:String}

final class Model: ObservableObject {
 @Published var step=0
 @Published var baseRoles=roles
 @Published var extraRoles:[String]=[]
 @Published var stars:Int?=nil
 var primaryRole:String {baseRoles[0]}
 var canContinueArtwork:Bool {artwork[primaryRole] != nil}
 struct RepositoryStats:Decodable {let stargazers_count:Int}
 static func starCount(_ data:Data,status:Int)->Int? {
  guard status==200,let stats=try? JSONDecoder().decode(RepositoryStats.self,from:data),stats.stargazers_count>=0 else{return nil}
  return stats.stargazers_count
 }
 @MainActor func refreshStars() async {
  var request=URLRequest(url:URL(string:"https://api.github.com/repos/stellienft/logo-parcel")!)
  request.timeoutInterval=8
  request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
  request.setValue("LogoParcel",forHTTPHeaderField:"User-Agent")
  let session=URLSession(configuration:.ephemeral)
  defer {session.invalidateAndCancel()}
  do {let (data,response)=try await session.data(for:request);stars=Self.starCount(data,status:(response as? HTTPURLResponse)?.statusCode ?? 0)} catch {stars=nil}
 }
 @Published var update:AppUpdate?=nil
 struct Release:Decodable {let tag_name:String; let html_url:String; let draft:Bool}
 static func versionParts(_ tag:String)->[Int] {
  let core=tag.trimmingCharacters(in:CharacterSet(charactersIn:"vV")).split(separator:"-").first.map(String.init) ?? ""
  return core.split(separator:".").map{Int($0) ?? 0}
 }
 static func newer(_ a:[Int],than b:[Int])->Bool {
  for i in 0..<max(a.count,b.count) {let x=i<a.count ? a[i] : 0, y=i<b.count ? b[i] : 0; if x != y {return x>y}}
  return false
 }
 static func latest(_ data:Data,current:String)->AppUpdate? {
  guard let releases=try? JSONDecoder().decode([Release].self,from:data).filter({!$0.draft}),
        let best=releases.max(by:{newer(versionParts($1.tag_name),than:versionParts($0.tag_name))}),
        newer(versionParts(best.tag_name),than:versionParts(current)),
        let url=URL(string:best.html_url),url.host=="github.com" else{return nil}
  return AppUpdate(version:best.tag_name.trimmingCharacters(in:CharacterSet(charactersIn:"vV")),url:url)
 }
 @MainActor func checkForUpdate() async {
  guard let current=Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else{return}
  var request=URLRequest(url:URL(string:"https://api.github.com/repos/stellienft/logo-parcel/releases?per_page=10")!)
  request.timeoutInterval=8
  request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
  request.setValue("LogoParcel",forHTTPHeaderField:"User-Agent")
  let session=URLSession(configuration:.ephemeral)
  defer {session.invalidateAndCancel()}
  guard let reply=try? await session.data(for:request),(reply.1 as? HTTPURLResponse)?.statusCode==200 else{return}
  update=Self.latest(reply.0,current:current)
 }
 @Published var showRoleEditor=false
 @Published var editingRole:String?=nil
 @Published var roleDraft=""
 var allRoles:[String] {baseRoles+extraRoles}
 var cleanRole:String {roleDraft.trimmingCharacters(in:.whitespacesAndNewlines)}
 func roleKey(_ value:String)->String {value.replacingOccurrences(of:"[^a-zA-Z0-9_-]+",with:"-",options:.regularExpression).trimmingCharacters(in:CharacterSet(charactersIn:"-")).lowercased()}
 var roleError:String? {
   if cleanRole.isEmpty {return "Give this item a name."}
   if cleanRole.count>50 {return "Keep the name under 50 characters."}
   if cleanRole.range(of:"[a-zA-Z0-9]",options:.regularExpression)==nil {return "Include at least one letter or number."}
   if roleKey(cleanRole)==roleKey("All artwork") || allRoles.contains(where:{$0 != editingRole && roleKey($0)==roleKey(cleanRole)}) {return "That name is already in use. Choose a different name."}
   return nil
 }
 func editRole(_ role:String?=nil){editingRole=role;roleDraft=role ?? "";showRoleEditor=true}
 func saveRole(){
   guard roleError==nil else{return}
   if let old=editingRole {
     if let i=baseRoles.firstIndex(of:old) {baseRoles[i]=cleanRole}
     else if let i=extraRoles.firstIndex(of:old) {extraRoles[i]=cleanRole}
     else {return}
     if let image=artwork.removeValue(forKey:old){artwork[cleanRole]=image}
   } else {extraRoles.append(cleanRole)}
   files=[];included=[];prepared="";roleFilter="All artwork"
   showRoleEditor=false
 }
 func removeRole(_ role:String){guard extraRoles.contains(role) else{return};extraRoles.removeAll{$0==role};artwork.removeValue(forKey:role)}
 @Published var artwork:[String:Artwork]=[:]
 @Published var formats:Set<String>=["svg","png","pdf","ai","eps","jpg"]
 @Published var intent="both"
 @Published var variants:Set<String>=["full-colour","black","white"]
 @Published var sizes:Set<Int>=[1024]
 @Published var padding=10
 @Published var custom="#7355DD"
 @Published var outline=true
 @Published var advanced=false
 @Published var brand=""
 @Published var output=""
 @Published var busy=false
 @Published var busyMessage=""
 @Published var fraction=0.0
 @Published var error:String?=nil
 @Published var pending:Inspection?=nil
 @Published var pendingRole=""
 @Published var chosenBoard=0
 @Published var importWarnings:[String]=[]
 @Published var files:[ExportFile]=[]
 @Published var included:Set<String>=[]
 @Published var warnings:[String]=[]
 @Published var prepared=""
 @Published var roleFilter="All artwork"
 @Published var modeFilter="All files"
 @Published var enlarged:ExportFile?=nil
 @Published var delivered:Delivered?=nil
 static let defaultTemplate="{brand}-{item}-{colour}-{mode}-{size}"
 static let tokens=["brand","item","colour","mode","size","format"]
 static let artworkTypes=["vectorcraft","svg","pdf","eps","ai"]
 @Published var extras:Set<String>=[]
 @Published var profile=""
 @Published var installedProfiles:[ICCProfile]=[]
 var profilesLoaded=false
 @Published var template=Model.defaultTemplate
 @Published var guideOptions=GuideOptions()
 @Published var colours:[BrandColour]=[]
 @Published var checks:[String]=[]
 @Published var presets:[Preset]=Store.load("presets.json",as:[Preset].self) ?? []
 @Published var recents:[RecentProject]=Store.load("recent.json",as:[RecentProject].self) ?? []
 @Published var showPresetName=false
 @Published var presetDraft=""
 @Published var dropTarget:String?=nil
 let resources=Bundle.main.resourceURL!
 let cache=FileManager.default.temporaryDirectory.appendingPathComponent("LogoParcel-\(UUID().uuidString)")
 var progressTimer:Timer?
 var modes:[String] { intent=="both" ? ["rgb","cmyk"] : [intent] }
 var effectiveFormats:[String] { ["svg","png","jpg","pdf","eps","ai"].filter{formats.contains($0) && !(intent=="cmyk" && ["svg","png"].contains($0))} }
 var rasterChosen:Bool {effectiveFormats.contains("png") || effectiveFormats.contains("jpg")}
 var canPreview:Bool {!effectiveFormats.isEmpty && !variants.isEmpty && (!rasterChosen || !sizes.isEmpty) && (!variants.contains("custom") || custom.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil)}
 var validName:Bool { !brand.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && brand.count<=80 && brand.range(of:"[a-zA-Z0-9]",options:.regularExpression) != nil }
 var safeName:String { let value=brand.replacingOccurrences(of:"[^a-zA-Z0-9_-]+",with:"-",options:.regularExpression).trimmingCharacters(in:CharacterSet(charactersIn:"-")); return value.isEmpty ? "Your-Brand" : value }
 var visible:[ExportFile] {files.filter{(roleFilter=="All artwork" || $0.role==roleFilter) && (modeFilter=="All files" || $0.mode==modeFilter)}}
 var selectedRoles:[String] { allRoles.filter{artwork[$0] != nil} }
 var count:Int { let n=effectiveFormats.reduce(0){sum,format in sum + modes.filter{!($0=="cmyk" && ["svg","png"].contains(format))}.count * (["png","jpg"].contains(format) ? sizes.count : 1)};return n*selectedRoles.count*variants.count+selectedRoles.count*extraCount }
 var extraCount:Int {(extras.contains("favicon") ? 6 : 0)+(extras.contains("social") ? 5 : 0)+(extras.contains("email") ? 1 : 0)}
 var settings:Settings {
  get {Settings(formats:["svg","png","jpg","pdf","eps","ai"].filter{formats.contains($0)},intent:intent,variants:["full-colour","black","white","grayscale","inverted","custom"].filter{variants.contains($0)},sizes:sizes.sorted(),padding:padding,custom:custom,outline:outline,extras:["favicon","social","email"].filter{extras.contains($0)},profile:profile,template:template)}
  set {formats=Set(newValue.formats);intent=newValue.intent;variants=Set(newValue.variants);sizes=Set(newValue.sizes);padding=newValue.padding;custom=newValue.custom;outline=newValue.outline;extras=Set(newValue.extras);template=newValue.template
   if newValue.profile.isEmpty || FileManager.default.fileExists(atPath:newValue.profile) {profile=newValue.profile;listProfile(newValue.profile)}
   else {profile="";error="The saved print profile can no longer be found, so the generic CMYK profile is selected."}}
 }
 func savePreset(){
  let name=presetDraft.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !name.isEmpty else{return}
  presets.removeAll{$0.name.lowercased()==name.lowercased()}
  presets.append(Preset(name:String(name.prefix(60)),settings:settings))
  presets.sort{$0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending}
  Store.save(presets,"presets.json");showPresetName=false
 }
 func applyPreset(_ preset:Preset){settings=preset.settings}
 func deletePreset(_ preset:Preset){presets.removeAll{$0.name==preset.name};Store.save(presets,"presets.json")}
 var templateError:String? {
  let t=template.trimmingCharacters(in:.whitespaces)
  if t.count>120 {return "Keep the pattern under 120 characters."}
  let regex=try! NSRegularExpression(pattern:"\\{([^}]*)\\}")
  for match in regex.matches(in:t,range:NSRange(t.startIndex...,in:t)) {
   if let r=Range(match.range(at:1),in:t), !Model.tokens.contains(String(t[r])) {return "Unknown part {\(t[r])}. Use {brand}, {item}, {colour}, {mode}, {size} or {format}."}
  }
  return nil
 }
 var templateExample:String {
  let t=template.trimmingCharacters(in:.whitespaces)
  var name=t.isEmpty ? Model.defaultTemplate : t
  for (key,value) in ["brand":safeName,"item":slug(primaryRole),"colour":"full-colour","mode":"rgb","size":"1024px","format":"png"] {name=name.replacingOccurrences(of:"{\(key)}",with:value)}
  name=name.replacingOccurrences(of:"[^a-zA-Z0-9_.-]+",with:"-",options:.regularExpression).replacingOccurrences(of:"([-_.])[-_.]+",with:"$1",options:.regularExpression).trimmingCharacters(in:CharacterSet(charactersIn:"-_."))
  return name+".png"
 }
 func pantone(_ hex:String)->Binding<String>{Binding(get:{self.guideOptions.pantone[hex] ?? ""},set:{self.guideOptions.pantone[hex]=$0.isEmpty ? nil : String($0.prefix(40))})}
 func loadProfiles(){
  guard !profilesLoaded else{return}
  profilesLoaded=true
  perform("profiles",config:[:],message:"",silent:true){(result:ProfileList) in
   let chosen=self.installedProfiles.filter{p in !result.profiles.contains{$0.path==p.path}}
   self.installedProfiles=result.profiles+chosen
  }
 }
 func listProfile(_ path:String){if !path.isEmpty && !installedProfiles.contains(where:{$0.path==path}) {installedProfiles.append(ICCProfile(name:URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent,path:path))}}
 func chooseProfile(){
  let p=NSOpenPanel();p.title="Choose your printer’s CMYK profile";p.prompt="Use profile";p.canChooseDirectories=false;p.allowedFileTypes=["icc","icm"]
  if p.runModal()==NSApplication.ModalResponse.OK,let url=p.url {listProfile(url.path);profile=url.path}
 }
 func remember(){
  let items=selectedRoles.compactMap{role->RecentItem? in guard let a=artwork[role] else{return nil};return RecentItem(role:role,source:a.source,index:a.index)}
  let name=brand.trimmingCharacters(in:.whitespacesAndNewlines)
  recents.removeAll{$0.brand.lowercased()==name.lowercased() && $0.output==output}
  recents.insert(RecentProject(id:UUID(),brand:name,output:output,date:Date(),baseRoles:baseRoles,extraRoles:extraRoles,items:items,settings:settings,guide:guideOptions),at:0)
  recents=Array(recents.prefix(8));Store.save(recents,"recent.json")
 }
 func forget(_ project:RecentProject){recents.removeAll{$0.id==project.id};Store.save(recents,"recent.json")}
 func reopen(_ project:RecentProject){
  let dir=cache.appendingPathComponent(UUID().uuidString)
  let items:[[String:Any]]=project.items.map{["role":$0.role,"source":$0.source,"index":$0.index]}
  perform("reopen",config:["cache":dir.path,"items":items],message:"Reopening \(project.brand)…"){(result:Reopened) in
   self.startAgain()
   self.baseRoles=project.baseRoles;self.extraRoles=project.extraRoles;self.guideOptions=project.guide;self.brand=project.brand
   if FileManager.default.fileExists(atPath:project.output) {self.output=project.output}
   for item in result.items where !item.missing {self.artwork[item.role]=Artwork(source:item.source,index:item.index,thumbnail:item.thumbnail,boardName:item.boardName)}
   self.importWarnings=result.warnings
   self.settings=project.settings
   let missing=result.items.filter{$0.missing}.map{$0.role}
   if !missing.isEmpty {self.error="This artwork has moved or changed since the last package: \(missing.joined(separator:", ")). Choose it again before continuing."}
  }
 }
 func drop(_ providers:[NSItemProvider],on role:String)->Bool {
  guard !busy,let provider=providers.first(where:{$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)}) else{return false}
  _ = provider.loadObject(ofClass:URL.self){url,_ in
   DispatchQueue.main.async {
    guard let url=url,url.isFileURL else{return}
    guard Model.artworkTypes.contains(url.pathExtension.lowercased()) else{self.error="Drop an SVG, VectorCraft, PDF, EPS or AI file.";return}
    self.load(url,for:role)
   }
  }
  return true
 }
 init(){try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)}
 func toggle<T:Hashable>(_ key:ReferenceWritableKeyPath<Model,Set<T>>,_ value:T)->Binding<Bool>{Binding(get:{self[keyPath:key].contains(value)},set:{if $0 {self[keyPath:key].insert(value)} else {self[keyPath:key].remove(value)}})}
 func perform<T:Decodable>(_ cmd:String,config:[String:Any],message:String,silent:Bool=false,done:@escaping(T)->Void) {
   let job=cache.appendingPathComponent(UUID().uuidString);let configURL=job.appendingPathComponent("config.json");let progressURL=job.appendingPathComponent("progress.json")
   do {
     try FileManager.default.createDirectory(at:job,withIntermediateDirectories:true)
     var d=config;d["progress"]=progressURL.path
     try JSONSerialization.data(withJSONObject:d).write(to:configURL)
   } catch {if !silent {self.error=error.localizedDescription};return}
   if !silent {
    busy=true;busyMessage=message;fraction=0
    progressTimer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){[weak self] _ in
      if let data=try? Data(contentsOf:progressURL), let p=try? JSONDecoder().decode(ProgressReport.self,from:data) {self?.busyMessage=p.message; self?.fraction=Double(p.completed)/Double(max(p.total,1))}
    }
   }
   DispatchQueue.global(qos:.userInitiated).async {
     do {
       let p=Process();p.executableURL=self.resources.appendingPathComponent("python/bin/python3");p.arguments=["-E","-s","-B",self.resources.appendingPathComponent("packager.py").path,cmd,configURL.path]
       let stdout=Pipe();p.standardOutput=stdout
       let errURL=job.appendingPathComponent("engine.log");FileManager.default.createFile(atPath:errURL.path,contents:nil)
       let err=try FileHandle(forWritingTo:errURL);defer {try? err.close()};p.standardError=err
       try p.run();let data=stdout.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
       if let e=try? JSONDecoder().decode(EngineError.self,from:data){throw NSError(domain:"LogoParcel",code:1,userInfo:[NSLocalizedDescriptionKey:e.error])}
       guard p.terminationStatus==0 else {throw NSError(domain:"LogoParcel",code:2,userInfo:[NSLocalizedDescriptionKey:"The export engine stopped. Your original artwork is safe. Try a simpler SVG or VectorCraft file."])}
       let value=try JSONDecoder().decode(T.self,from:data)
       DispatchQueue.main.async {if !silent {self.progressTimer?.invalidate();self.busy=false};done(value)}
     } catch {DispatchQueue.main.async {if !silent {self.progressTimer?.invalidate();self.busy=false;self.error=String(error.localizedDescription.prefix(1800))}}}
   }
 }
 func add(_ role:String){
   let p=NSOpenPanel();p.title="Choose your \(role.lowercased())";p.prompt="Choose artwork";p.canChooseDirectories=false;p.allowsMultipleSelection=false;p.allowedFileTypes=Model.artworkTypes
   guard p.runModal()==NSApplication.ModalResponse.OK,let url=p.url else{return}
   load(url,for:role)
 }
 func load(_ url:URL,for role:String){
   let dir=cache.appendingPathComponent(UUID().uuidString)
   perform("inspect-previews",config:["source":url.path,"cache":dir.path],message:"Reading your \(role.lowercased())…") { (result:Inspection) in
     if result.layouts.isEmpty {self.error="There are no artboards in this file.";return}
     if result.layouts.count==1 {self.assign(role,result,result.layouts[0])}
     else {self.pendingRole=role;self.chosenBoard=result.layouts[0].index;self.pending=result}
   }
 }
 func assign(_ role:String,_ result:Inspection,_ board:Board){artwork[role]=Artwork(source:result.source,index:board.index,thumbnail:board.thumbnail,boardName:board.name);importWarnings+=result.warnings;pending=nil}
 func buildPreview(){
   let layouts=selectedRoles.compactMap{role->[String:Any]? in guard let a=artwork[role] else{return nil};return ["source":a.source,"index":a.index,"name":role]}
   let dir=cache.appendingPathComponent(UUID().uuidString)
   let config:[String:Any]=["layouts":layouts,"brand":"Logo","formats":effectiveFormats,"variants":["full-colour","black","white","grayscale","inverted","custom"].filter{variants.contains($0)},"modes":modes,"sizes":sizes.isEmpty ? [1024] : sizes.sorted(),"padding":padding,"custom":custom,"outline":outline,"extras":settings.extras,"profile":intent=="rgb" ? "" : profile,"cache":dir.path]
   perform("prepare",config:config,message:"Preparing your preview…") {(result:Prepared) in self.prepared=result.prepared;self.files=result.files;self.included=Set(result.files.map{$0.id});self.warnings=result.warnings;self.checks=result.checks ?? [];self.colours=result.colours ?? [];self.guideOptions.pantone=self.guideOptions.pantone.filter{hex,_ in self.colours.contains{$0.hex==hex}};self.roleFilter="All artwork";self.modeFilter="All files";self.step=2}
 }
 func chooseOutput(){let p=NSOpenPanel();p.title="Where should your logo package be saved?";p.prompt="Save here";p.canChooseFiles=false;p.canChooseDirectories=true;p.canCreateDirectories=true;if p.runModal()==NSApplication.ModalResponse.OK,let url=p.url{output=url.path}}
 func export(){
   let g=guideOptions
   let guide:[String:Any]=["colours":g.colours,"usage":g.usage,"pdf":g.pdf,"minDigital":g.minDigital,"minPrint":g.minPrint,"notes":g.notes,"pantone":g.pantone]
   perform("deliver",config:["prepared":prepared,"include":Array(included),"brand":brand.trimmingCharacters(in:.whitespacesAndNewlines),"output":output,"template":template,"guide":guide],message:"Saving your package…"){(result:Delivered) in self.delivered=result;self.remember();self.step=4}
 }
 func startAgain(){baseRoles=roles;extraRoles=[];artwork=[:];files=[];included=[];prepared="";delivered=nil;brand="";output="";importWarnings=[];warnings=[];checks=[];colours=[];guideOptions=GuideOptions();step=0}
}

struct CraftButton:ButtonStyle {
 var primary=false
 @Environment(\.isEnabled) private var enabled
 func makeBody(configuration:Configuration)->some View {
  configuration.label.textCase(.uppercase).font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.1)
   .padding(.horizontal,16).padding(.vertical,12)
   .foregroundColor(primary ? Color.white : ink)
   .background(primary ? ink : Color.clear)
   .overlay(Rectangle().stroke(primary ? ink : rule,lineWidth:1))
   .opacity(enabled ? (configuration.isPressed ? 0.65 : 1) : 0.28)
 }
}
struct CraftPanel:ViewModifier {
 func body(content:Self.Content)->some View {content.background(paper).overlay(Rectangle().stroke(rule,lineWidth:1))}
}
extension View {func craftPanel()->some View {modifier(CraftPanel())}}
struct ArtImage:View {
 var path:String;var dark=false
 var body:some View {
   ZStack {
    (dark ? Color(red:0.12,green:0.12,blue:0.13) : Color.white)
    if let image=NSImage(contentsOfFile:path) { Image(nsImage:image).resizable().aspectRatio(contentMode:.fit).padding(18) }
    else {Image(systemName:"photo").font(.title).foregroundColor(.secondary)}
   }.clipped()
 }
}
struct SectionTitle:View {var title:String;var subtitle:String;var body:some View {VStack(alignment:.leading,spacing:8){Text(title).font(.system(size:30,weight:.bold)).tracking(-0.7);Text(subtitle).font(.system(size:14)).foregroundColor(.secondary)}}}
struct Content:View {
 @StateObject var m=Model()
 var body:some View {
  VStack(spacing:0){
   header
   Divider()
   ScrollView {VStack(alignment:.leading,spacing:24){
    switch m.step {case 0: artworkPage;case 1: optionsPage;case 2: previewPage;case 3: savePage;default:successPage}
   }.padding(30).frame(maxWidth:.infinity,alignment:.leading)}
   Divider();footer
   creatorCredit
  }.frame(width:1040,height:820).background(paper).foregroundColor(ink).tint(accent).buttonStyle(CraftButton()).preferredColorScheme(.light)
  .overlay {if m.busy {ZStack {Color.black.opacity(0.12);VStack(spacing:15){ProgressView().controlSize(.large);Text(m.busyMessage).font(.headline);ProgressView(value:m.fraction).frame(width:300);Text("Your original artwork stays untouched.").foregroundColor(.secondary).font(.system(size:11,design:.monospaced))}.padding(35).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))}.allowsHitTesting(true)}}
  .alert("Let’s fix that",isPresented:Binding(get:{m.error != nil},set:{if !$0{m.error=nil}})){Button("OK",role:.cancel){m.error=nil}}message:{Text(m.error ?? "")}
  .sheet(isPresented:Binding(get:{m.pending != nil},set:{if !$0{m.pending=nil}})){boardPicker}
  .sheet(isPresented:$m.showRoleEditor){roleEditor}
  .task {await m.refreshStars();await m.checkForUpdate()}
  .sheet(item:$m.enlarged){file in VStack(alignment:.leading,spacing:16){HStack{Text("\(file.role) · \(file.title)").font(.title2);Spacer();Button("Done"){m.enlarged=nil}};ArtImage(path:file.thumbnail,dark:file.variant=="white").frame(height:440);Text("\(file.format.uppercased()) · \(file.detail)").foregroundColor(.secondary);Text("Screen preview. CMYK colours can look different in print.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}.padding(25).frame(width:700)}
 }
 var creatorCredit:some View {
  HStack(spacing:7){
   Text("CREATED BY").foregroundColor(.secondary)
   if let url=creatorWebsite {Link("STELLIO CREATIVE LABS ↗",destination:url).foregroundColor(ink)}
   else {Text("STELLIO CREATIVE LABS").foregroundColor(ink)}
   Spacer()
  }.font(.system(size:9,weight:.medium,design:.monospaced)).tracking(1).padding(.horizontal,30).padding(.bottom,13)
 }
 var header:some View {
  VStack(spacing:0){
   HStack(spacing:20){
    (Text("Logo").foregroundColor(ink)+Text("Parcel").foregroundColor(accent)).font(.system(size:27,weight:.heavy)).tracking(-1)
    Rectangle().fill(rule).frame(width:1,height:30)
    Text("LOGO PACKAGING").font(.system(size:10,weight:.semibold,design:.monospaced)).tracking(2).foregroundColor(.secondary)
    Spacer()
    if let update=m.update {
     Link(destination:update.url){Text("UPDATE \(update.version) ↗").font(.system(size:11,weight:.bold,design:.monospaced)).tracking(1).padding(.horizontal,9).padding(.vertical,5).background(accent).foregroundColor(ink)}
      .help("A newer Logo Parcel release is available on GitHub.")
    }
    Link(destination:URL(string:"https://github.com/stellienft/logo-parcel")!){
     HStack(spacing:7){Text("GITHUB");Image(systemName:"star");Text(m.stars.map{String($0)} ?? "—")}
      .font(.system(size:11,weight:.semibold,design:.monospaced)).foregroundColor(ink)
    }.help(m.stars == nil ? "Open Logo Parcel on GitHub. Star count unavailable offline or when GitHub is busy." : "GitHub stars, checked when this window opens. Click to visit the repository.")
   }.padding(.horizontal,30).padding(.vertical,22)
   Rectangle().fill(rule).frame(height:1)
   HStack(spacing:0){
    ForEach(Array(["ARTWORK","OPTIONS","PREVIEW","SAVE"].enumerated()),id:\.offset){i,label in
     HStack(spacing:12){
      Text(String(format:"%02d",i+1)).font(.system(size:11,weight:.bold,design:.monospaced)).tracking(1).frame(width:32,height:24).background(m.step==i ? accent : Color.black.opacity(0.06))
      Text(label).font(.system(size:11,weight:m.step==i ? .bold : .regular,design:.monospaced)).tracking(1.5).foregroundColor(m.step==i ? ink : .secondary)
      Spacer()
      if m.step>i {Image(systemName:"checkmark").font(.system(size:10,weight:.bold)).foregroundColor(accent)}
     }.padding(.horizontal,20).padding(.vertical,15).frame(maxWidth:.infinity).overlay(Rectangle().stroke(rule,lineWidth:0.5))
    }
   }
  }
 }
 var artworkPage:some View {
  VStack(alignment:.leading,spacing:24){
   SectionTitle(title:"Start with your finished artwork",subtitle:"Start with your full logo, then add any symbols, wordmarks or lockup variations you need.")
   LazyVGrid(columns:[GridItem(.flexible(),spacing:0,alignment:.top),GridItem(.flexible(),spacing:0,alignment:.top),GridItem(.flexible(),spacing:0,alignment:.top)],spacing:16){ForEach(m.allRoles,id:\.self){role in artworkCard(role)}}
   HStack{Button {m.editRole()}label:{Label("Add variation",systemImage:"plus")}.buttonStyle(CraftButton(primary:true));Text("Horizontal, vertical, with slogan, without slogan—or your own label.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}
   Label("Use SVG, VectorCraft, PDF, EPS or AI files. Drag a file onto a card or click its button. If a file has several artboards, you’ll choose one.",systemImage:"info.circle").font(.callout).foregroundColor(.secondary)
   HStack(alignment:.top,spacing:14){Image(systemName:"lightbulb").foregroundColor(accent);VStack(alignment:.leading,spacing:7){Text("Working in VectorCraft?").font(.headline);Text("Save your finished logo first. Add each component as its own file or artboard. A symbol is the icon on its own; a wordmark is the name on its own.").foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)}}.padding(20).frame(maxWidth:.infinity,alignment:.leading).craftPanel()
   if !m.importWarnings.isEmpty {DisclosureGroup("Artwork import notes (\(m.importWarnings.count))"){Text(m.importWarnings.joined(separator:"\n")).font(.system(size:11,design:.monospaced)).textSelection(.enabled)}}
   if m.artwork.isEmpty && !m.recents.isEmpty {recentList}
  }
 }
 var recentList:some View {
  VStack(alignment:.leading,spacing:0){
   Text("RECENT PACKAGES").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.5).padding(.bottom,12)
   ForEach(m.recents){project in
    HStack(spacing:14){
     Image(systemName:"clock.arrow.circlepath").foregroundColor(accent)
     VStack(alignment:.leading,spacing:3){Text(project.brand).font(.headline);Text("\(project.items.count) artwork items · \(project.date.formatted(date:.abbreviated,time:.shortened))").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}
     Spacer()
     Button("Reopen"){m.reopen(project)}
     Button {m.forget(project)} label:{Image(systemName:"xmark").foregroundColor(.secondary).frame(width:24,height:24).contentShape(Rectangle())}.buttonStyle(.plain).help("Remove from recent packages").accessibilityLabel("Remove \(project.brand) from recent packages")
    }.padding(.vertical,10)
    Divider()
   }
   Text("Reopening reloads the artwork, options and client guide settings so you can update a package after a logo change.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary).padding(.top,10)
  }.padding(20).frame(maxWidth:.infinity,alignment:.leading).craftPanel()
 }
 func artworkCard(_ role:String)->some View {
  VStack(alignment:.leading,spacing:13){
   HStack{Text(String(format:"%02d",(m.allRoles.firstIndex(of:role) ?? 0)+1)).font(.system(size:10,weight:.bold,design:.monospaced)).tracking(1).padding(.horizontal,7).padding(.vertical,5).background(accent);Spacer();Text(role==m.primaryRole ? "REQUIRED" : "OPTIONAL").font(.system(size:10,design:.monospaced)).tracking(1.5).foregroundColor(.secondary)}
   Divider()
   HStack(alignment:.firstTextBaseline,spacing:8){
    Text(role).font(.system(size:22,weight:.bold)).tracking(-0.5).lineLimit(2).frame(maxWidth:.infinity,minHeight:28,alignment:.leading)
    Button {m.editRole(role)} label:{Image(systemName:"pencil").font(.system(size:14,weight:.medium)).foregroundColor(.secondary).frame(width:28,height:28).contentShape(Rectangle())}
     .buttonStyle(.plain).help("Rename this item").accessibilityLabel("Rename \(role)")
   }
   if let a=m.artwork[role] {
    ArtImage(path:a.thumbnail).frame(height:155)
    Text(URL(fileURLWithPath:a.source).lastPathComponent).font(.system(size:11,design:.monospaced)).lineLimit(1).truncationMode(.middle)
    Text(a.boardName).font(.system(size:11,design:.monospaced)).foregroundColor(.secondary).lineLimit(1)
    HStack{Button("Replace…"){m.add(role)};Spacer();Button("Remove"){m.artwork.removeValue(forKey:role)}.foregroundColor(.secondary)}
   } else {
    VStack(spacing:12){Image(systemName:role==m.baseRoles[1] ? "sparkle" : role==m.baseRoles[2] ? "textformat" : "square.on.square").font(.system(size:30)).foregroundColor(accent.opacity(0.6));Text(role==m.primaryRole ? "Your complete logo" : role==m.baseRoles[1] ? "Your standalone icon" : role==m.baseRoles[2] ? "Your brand name" : "Your approved variation").foregroundColor(.secondary)}.frame(maxWidth:.infinity).frame(height:155).background(Color.black.opacity(0.025),in:Rectangle())
    Text(role==m.primaryRole ? "Needed to start your package" : "Leave empty if you don’t have one").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary).frame(height:30,alignment:.top)
    Button(m.baseRoles.contains(role) ? "Add \(role.lowercased())…" : "Choose artwork…"){m.add(role)}.buttonStyle(CraftButton()).frame(maxWidth:.infinity,alignment:.leading)
   }
   if m.extraRoles.contains(role) {Divider();Button("Remove item"){m.removeRole(role)}}
  }.padding(18).frame(maxWidth:.infinity,alignment:.topLeading).craftPanel()
  .overlay(Rectangle().stroke(accent,lineWidth:2).opacity(m.dropTarget==role ? 1 : 0).allowsHitTesting(false))
  .onDrop(of:[UTType.fileURL],isTargeted:Binding(get:{m.dropTarget==role},set:{targeted in if targeted {m.dropTarget=role} else if m.dropTarget==role {m.dropTarget=nil}})){providers in m.drop(providers,on:role)}
 }
 var optionsPage:some View {
  VStack(alignment:.leading,spacing:23){
   SectionTitle(title:"What do you need to deliver?",subtitle:"Choose where the logos will be used. We’ll handle the compatible colour modes.")
   presetBar
   HStack(spacing:0){ForEach(["rgb","cmyk","both"],id:\.self){mode in
    Button{m.intent=mode}label:{VStack(alignment:.leading,spacing:8){Text(mode=="rgb" ? "DIGITAL ONLY" : mode=="cmyk" ? "PRINT ONLY" : "DIGITAL + PRINT").font(.system(size:11,weight:.bold,design:.monospaced)).tracking(1.3);Text(mode=="rgb" ? "RGB · screens & websites" : mode=="cmyk" ? "CMYK · print files" : "Both RGB and CMYK").font(.system(size:12))}.frame(maxWidth:.infinity,alignment:.leading).padding(18).foregroundColor(m.intent==mode ? .white : ink).background(m.intent==mode ? ink : Color.clear).overlay(Rectangle().stroke(rule,lineWidth:1).allowsHitTesting(false)).contentShape(Rectangle())}.buttonStyle(.plain)
   }}
   VStack(alignment:.leading,spacing:12){HStack{Text("FILE FORMATS").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.5);Spacer();Button("Select all"){m.formats=["svg","png","jpg","pdf","eps","ai"]};Button("Clear"){m.formats=[]}}
    LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())],spacing:12){
     ForEach(["svg","png","jpg","pdf","eps","ai"],id:\.self){f in formatCard(f)}
    }
    if m.intent=="cmyk" {Text("PNG and SVG are digital formats, so they’re excluded from print-only packages.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}
    if m.formats.contains("ai") {Text("AI exports are PDF-compatible files from VectorCraft. Full Illustrator-native editing data is not included.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}
   }
   VStack(alignment:.leading,spacing:12){Text("COLOUR VERSIONS").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.5);HStack(spacing:30){ForEach(["full-colour","black","white"],id:\.self){v in Toggle(v.replacingOccurrences(of:"-",with:" ").capitalized,isOn:m.toggle(\.variants,v))}};Text("Black and white versions recolour every filled shape. Check any white cutout shapes in the preview.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}.padding(18).frame(maxWidth:.infinity,alignment:.leading).craftPanel()
   VStack(alignment:.leading,spacing:12){Text("WEB & SOCIAL SETS").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.5)
    HStack(alignment:.top,spacing:30){ForEach(Array([("favicon","Favicons","favicon.ico, 16 and 32 px, Apple touch icon, Android 192 and 512 px"),("social","Social media","Profile avatar and LinkedIn, X, Facebook and YouTube covers"),("email","Email signature","600 px wide transparent PNG")].enumerated()),id:\.offset){_,option in
     Toggle(isOn:m.toggle(\.extras,option.0)){VStack(alignment:.leading,spacing:3){Text(option.1).font(.headline);Text(option.2).font(.system(size:11,design:.monospaced)).foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)}}.frame(maxWidth:.infinity,alignment:.leading)
    }}
    Text("Full-colour RGB PNGs for each artwork item, ready to upload. A symbol makes the clearest favicon.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)
   }.padding(18).frame(maxWidth:.infinity,alignment:.leading).craftPanel()
   DisclosureGroup("More options",isExpanded:$m.advanced){VStack(alignment:.leading,spacing:16){
    if m.rasterChosen {HStack{Text("Image widths").frame(width:120,alignment:.leading);ForEach([512,1024,2048,4096],id:\.self){n in Toggle("\(n) px",isOn:m.toggle(\.sizes,n))}}}
    HStack{Text("Clear space").frame(width:120,alignment:.leading);Picker("Padding",selection:$m.padding){Text("None").tag(0);Text("Small · 5%").tag(5);Text("Standard · 10%").tag(10);Text("Generous · 20%").tag(20)}.labelsHidden().frame(width:210);Text("On each side of the artwork").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}
    HStack(spacing:25){Toggle("Grayscale",isOn:m.toggle(\.variants,"grayscale"));Toggle("Inverted",isOn:m.toggle(\.variants,"inverted"));Toggle("Custom solid colour",isOn:m.toggle(\.variants,"custom"));if m.variants.contains("custom"){TextField("#7355DD",text:$m.custom).textFieldStyle(.roundedBorder).frame(width:110)}}
    Toggle("Outline text in SVG files",isOn:$m.outline)
    if m.intent != "rgb" {
     HStack{Text("Print profile").frame(width:120,alignment:.leading);Picker("Print profile",selection:$m.profile){Text("VectorCraft generic CMYK (SWOP-like)").tag("");ForEach(m.installedProfiles,id:\.path){p in Text(p.name).tag(p.path)}}.labelsHidden().frame(width:330);Button("Choose ICC file…",action:m.chooseProfile)}
     Text("CMYK files and brand colour values are converted with this profile. Ask your printer which one they need, for example Coated FOGRA39 or GRACoL.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)
    }
   }.padding(.top,14)}
   if !m.canPreview {Label(m.effectiveFormats.isEmpty ? "Choose at least one available format." : m.variants.isEmpty ? "Choose at least one colour version." : m.rasterChosen && m.sizes.isEmpty ? "Choose at least one image width in More options." : "Enter a custom colour such as #7355DD.",systemImage:"exclamationmark.circle").foregroundColor(.orange)}
  }
  .onAppear{m.loadProfiles()}
  .alert("Save these settings as a preset",isPresented:$m.showPresetName){
   TextField("e.g. Standard client pack",text:$m.presetDraft)
   Button("Cancel",role:.cancel){}
   Button("Save",action:m.savePreset)
  }message:{Text("Formats, colour versions, sizes, web sets, print profile and filename pattern are saved. A preset with the same name is replaced.")}
 }
 var presetBar:some View {
  HStack(spacing:12){
   Text("PRESETS").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.5).foregroundColor(.secondary)
   Menu(m.presets.isEmpty ? "No saved presets" : "Apply a preset"){ForEach(m.presets){preset in Button(preset.name){m.applyPreset(preset)}}}.frame(width:200).disabled(m.presets.isEmpty)
   Button("Save as preset…"){m.presetDraft="";m.showPresetName=true}
   if !m.presets.isEmpty {Menu("Delete…"){ForEach(m.presets){preset in Button(preset.name){m.deletePreset(preset)}}}.frame(width:100)}
   Spacer()
  }
 }
 func formatCard(_ f:String)->some View {
  let disabled=m.intent=="cmyk" && ["svg","png"].contains(f)
  let descriptions=["svg":"Scalable artwork for websites","png":"Transparent images for screens","jpg":"Images with a solid background","pdf":"Sharing and printing","eps":"Legacy print workflows","ai":"PDF-compatible Illustrator file"]
  return HStack(alignment:.top,spacing:10){Toggle("",isOn:disabled ? .constant(false) : m.toggle(\.formats,f)).labelsHidden();VStack(alignment:.leading,spacing:4){Text(f.uppercased()).font(.headline);Text(descriptions[f] ?? "").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}}.padding(14).frame(maxWidth:.infinity,minHeight:50,alignment:.leading).craftPanel().opacity(disabled ? 0.45 : 1).disabled(disabled)
 }
 var previewPage:some View {
  VStack(alignment:.leading,spacing:20){
   SectionTitle(title:"Check your logo files",subtitle:"These previews come from the generated exports. Uncheck any files you don’t need; click a preview to inspect it.")
   HStack{Picker("Artwork",selection:$m.roleFilter){Text("All artwork").tag("All artwork");ForEach(m.selectedRoles,id:\.self){Text($0).tag($0)}}.frame(width:230);Picker("Colour mode",selection:$m.modeFilter){Text("All files").tag("All files");Text("RGB").tag("rgb");Text("CMYK").tag("cmyk")}.frame(width:210);Spacer();Button("Select all"){m.included=Set(m.files.map{$0.id})};Button("Select none"){m.included=[]}}
   Text("\(m.included.count) of \(m.files.count) files selected · White artwork is shown on a dark preview background.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)
   if !m.checks.isEmpty {
    VStack(alignment:.leading,spacing:8){
     Label("Check before you deliver",systemImage:"exclamationmark.triangle.fill").font(.headline).foregroundColor(.orange)
     ForEach(m.checks,id:\.self){check in Text("• "+check).font(.callout).fixedSize(horizontal:false,vertical:true)}
     Text("Fix these in your artwork and rebuild the preview, or deliver as is. They are also saved in export-report.json.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)
    }.padding(18).frame(maxWidth:.infinity,alignment:.leading).craftPanel().overlay(Rectangle().stroke(Color.orange.opacity(0.6),lineWidth:1))
   }
   if !m.warnings.isEmpty {DisclosureGroup("Review \(m.warnings.count) export notes"){Text(m.warnings.joined(separator:"\n")).font(.system(size:11,design:.monospaced)).textSelection(.enabled)}}
   LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())],spacing:16){ForEach(m.visible){file in
    VStack(alignment:.leading,spacing:10){
     Button {m.enlarged=file} label:{ArtImage(path:file.thumbnail,dark:file.variant=="white").frame(height:125)}.buttonStyle(.plain)
     HStack{Toggle(file.role,isOn:m.toggle(\.included,file.id)).font(.headline);Spacer();Text(file.format.uppercased()).font(.system(size:10,weight:.bold)).padding(.horizontal,7).padding(.vertical,4).background(accent.opacity(0.15),in:Rectangle())}
     Text(file.title+" · "+file.detail).font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)
    }.padding(13).craftPanel().overlay(Rectangle().stroke(m.included.contains(file.id) ? accent.opacity(0.35) : Color.clear))
   }}
   if m.visible.isEmpty {Text("No files match this filter. Choose All artwork and All files.").foregroundColor(.secondary)}
   Text("CMYK previews are displayed on your screen in RGB; confirm the print profile with your printer.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)
  }
 }
 var savePage:some View {
  VStack(alignment:.leading,spacing:25){
   SectionTitle(title:"Name it. Choose a folder. Done.",subtitle:"Your \(m.included.count) selected logo files will be saved as an organised folder and a ZIP.")
   VStack(alignment:.leading,spacing:12){Text("PACKAGE NAME").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.5);TextField("e.g. Acme",text:$m.brand).textFieldStyle(.roundedBorder).font(.title3).frame(maxWidth:540);Text("Folder: \(m.safeName)-Logo-Package").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary);if !m.brand.isEmpty && !m.validName{Text("Use a name under 80 characters with at least one letter or number.").foregroundColor(.orange).font(.system(size:11,design:.monospaced))}}
   VStack(alignment:.leading,spacing:10){Text("FILE NAMES").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.5)
    HStack{TextField(Model.defaultTemplate,text:$m.template).textFieldStyle(.roundedBorder).font(.system(size:13,design:.monospaced)).frame(maxWidth:540);Button("Reset"){m.template=Model.defaultTemplate}.disabled(m.template==Model.defaultTemplate)}
    Text("Parts: {brand} {item} {colour} {mode} {size} {format}. Folders stay organised by artwork, mode and colour; favicons keep their standard web names.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)
    if let problem=m.templateError {Text(problem).foregroundColor(.orange).font(.system(size:11,design:.monospaced))}
    else {Text("Example: \(m.templateExample)").font(.system(size:11,design:.monospaced))}
   }
   clientGuide
   VStack(alignment:.leading,spacing:12){Text("SAVE LOCATION").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.5);HStack{Image(systemName:"folder").foregroundColor(accent);Text(m.output.isEmpty ? "Choose where your package should go" : m.output).foregroundColor(m.output.isEmpty ? .secondary : ink).lineLimit(2).textSelection(.enabled);Spacer();Button(m.output.isEmpty ? "Choose folder…" : "Change…",action:m.chooseOutput)}}.padding(20).craftPanel()
   VStack(alignment:.leading,spacing:15){Label("\(m.included.count) reviewed logo files",systemImage:"checkmark.circle.fill");Label("Organised by artwork, RGB / CMYK and colour version",systemImage:"folder.badge.gearshape");Label("ZIP archive and a client guide included",systemImage:"shippingbox");Label("Existing packages are kept; new ones get a numbered name",systemImage:"doc.on.doc")}.font(.callout).foregroundColor(.secondary)
   if !m.validName || m.output.isEmpty {Text(m.validName ? "Choose a save folder to continue." : "Enter a package name to continue.").foregroundColor(.secondary).font(.callout)}
  }
 }
 var clientGuide:some View {
  VStack(alignment:.leading,spacing:14){
   Text("CLIENT GUIDE").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.5)
   Toggle("Brand colours: HEX, RGB and CMYK values, with ASE, CSS and JSON swatch files",isOn:$m.guideOptions.colours).disabled(m.colours.isEmpty)
   if m.guideOptions.colours && !m.colours.isEmpty {
    VStack(alignment:.leading,spacing:8){ForEach(m.colours){colour in
     HStack(spacing:12){
      Rectangle().fill(Color(red:Double(colour.rgb[0])/255,green:Double(colour.rgb[1])/255,blue:Double(colour.rgb[2])/255)).frame(width:26,height:26).overlay(Rectangle().stroke(rule,lineWidth:1))
      Text(colour.hex).font(.system(size:12,design:.monospaced)).frame(width:80,alignment:.leading)
      Text("CMYK "+colour.cmyk.map{String($0)}.joined(separator:" ")).font(.system(size:11,design:.monospaced)).foregroundColor(.secondary).frame(width:150,alignment:.leading)
      TextField("Pantone reference (optional)",text:m.pantone(colour.hex)).textFieldStyle(.roundedBorder).frame(width:240)
     }
    }}.padding(.leading,22)
   }
   Toggle("Usage guidelines: clear space, minimum sizes and common mistakes to avoid",isOn:$m.guideOptions.usage)
   if m.guideOptions.usage {
    VStack(alignment:.leading,spacing:10){
     HStack{Text("Minimum width").frame(width:110,alignment:.leading);TextField("0",value:$m.guideOptions.minDigital,format:.number).textFieldStyle(.roundedBorder).frame(width:70);Text("px on screen");TextField("0",value:$m.guideOptions.minPrint,format:.number).textFieldStyle(.roundedBorder).frame(width:70).padding(.leading,12);Text("mm in print");Text("0 leaves it out").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary).padding(.leading,8)}
     TextField("Extra guidance for your client (optional)",text:$m.guideOptions.notes,axis:.vertical).textFieldStyle(.roundedBorder).lineLimit(2...4).frame(maxWidth:620)
    }.padding(.leading,22)
   }
   Toggle("One-page PDF brand sheet for clients who won’t open the HTML guide",isOn:$m.guideOptions.pdf)
  }.padding(20).frame(maxWidth:.infinity,alignment:.leading).craftPanel()
 }
 var successPage:some View {
  VStack(alignment:.center,spacing:22){Image(systemName:"checkmark.seal.fill").font(.system(size:64)).foregroundColor(accent);Text("Your logo package is ready").font(.system(size:30,weight:.semibold));Text("\(m.delivered?.count ?? 0) logo files, organised and ready to hand over.").foregroundColor(.secondary)
   if let d=m.delivered {Text(d.folder).font(.system(size:11,design:.monospaced)).foregroundColor(.secondary).textSelection(.enabled);HStack{Button("Open package folder"){NSWorkspace.shared.open(URL(fileURLWithPath:d.folder))}.buttonStyle(CraftButton(primary:true));Button("Show ZIP in Finder"){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:d.zip)])}}};if !m.warnings.isEmpty {Text("Export notes are included in the package. Please review them before delivery.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}
  }.frame(maxWidth:.infinity).padding(.vertical,80)
 }
 var footer:some View {
  HStack(spacing:15){if m.step>0 && m.step<4 {Button("Back"){m.step-=1}};Text(m.step==0 ? "Your artwork stays on your Mac." : m.step==1 ? "\(m.count) files · \(m.sizes.sorted().map{String($0)}.joined(separator:", ")) px · \(m.padding)% clear space" : m.step==2 ? "\(m.included.count) files selected" : "").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary);Spacer()
   switch m.step {
   case 0:Button("Continue to options"){m.step=1}.buttonStyle(CraftButton(primary:true)).disabled(!m.canContinueArtwork)
   case 1:Button("Build visual preview",action:m.buildPreview).buttonStyle(CraftButton(primary:true)).disabled(!m.canPreview)
   case 2:Button("Continue to save"){m.step=3}.buttonStyle(CraftButton(primary:true)).disabled(m.included.isEmpty)
   case 3:Button("Export \(m.included.count) files",action:m.export).buttonStyle(CraftButton(primary:true)).disabled(!m.validName || m.output.isEmpty || m.included.isEmpty || m.templateError != nil)
   default:Button("Create another package",action:m.startAgain).buttonStyle(CraftButton(primary:true))
   }
  }.controlSize(.large).padding(.horizontal,30).padding(.vertical,20).disabled(m.busy)
 }
 var roleEditor:some View {
  VStack(alignment:.leading,spacing:22){
   SectionTitle(title:m.editingRole==nil ? "Add a logo variation" : "Rename this item",subtitle:"Each item gets its own artwork, previews and export folder.")
   if m.editingRole==nil {
    Text("START WITH A LABEL").font(.system(size:10,weight:.semibold,design:.monospaced)).tracking(1.5).foregroundColor(.secondary)
    LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:10){ForEach(["Horizontal lockup","Vertical lockup","With slogan","Without slogan","Slogan","Social avatar"],id:\.self){name in Button(name){m.roleDraft=name}.frame(maxWidth:.infinity,alignment:.leading)}}
   }
   VStack(alignment:.leading,spacing:10){Text("ITEM NAME").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.5);TextField("e.g. Vertical lockup — no slogan",text:$m.roleDraft).textFieldStyle(.roundedBorder).font(.title3)
    if let problem=m.roleError,!m.roleDraft.isEmpty {Text(problem).font(.caption).foregroundColor(.orange)}
    else {Text("This name will label the previews and exported folder.").font(.caption).foregroundColor(.secondary)}
   }
   if m.editingRole==nil {Text("After adding the item, choose a saved file or an artboard for it. Logo Parcel packages your finished variations; it does not rearrange the logo.").font(.callout).foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)}
   HStack{Button("Cancel"){m.showRoleEditor=false};Spacer();Button(m.editingRole==nil ? "Add item" : "Save name",action:m.saveRole).buttonStyle(CraftButton(primary:true)).disabled(m.roleError != nil)}
  }.padding(28).frame(width:620).background(paper).foregroundColor(ink).buttonStyle(CraftButton()).preferredColorScheme(.light)
 }
 var boardPicker:some View {
  VStack(alignment:.leading,spacing:18){SectionTitle(title:"Which artboard is your \(m.pendingRole.lowercased())?",subtitle:"Choose the artwork you want to use for this component.");ScrollView{LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:15){ForEach(m.pending?.layouts ?? []){board in Button{m.chosenBoard=board.index}label:{VStack{ArtImage(path:board.thumbnail).frame(height:145);HStack{Image(systemName:m.chosenBoard==board.index ? "checkmark.circle.fill" : "circle");Text(board.name).lineLimit(1)}}.padding(10).craftPanel().overlay(Rectangle().stroke(m.chosenBoard==board.index ? accent : Color.clear,lineWidth:2))}.buttonStyle(.plain)}}};HStack{Button("Cancel"){m.pending=nil};Spacer();Button("Use this artboard"){if let d=m.pending,let b=d.layouts.first(where:{$0.index==m.chosenBoard}){m.assign(m.pendingRole,d,b)}}.buttonStyle(CraftButton(primary:true))}}.padding(25).frame(width:720,height:540).background(paper)
 }
}
@main struct LogoParcel:App {
 var body:some Scene{WindowGroup{Content().onAppear{NSApplication.shared.activate(ignoringOtherApps:true)}}.windowStyle(.titleBar).windowResizability(.contentSize)}
}
