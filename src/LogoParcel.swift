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
struct Artwork:Codable { var source:String; var index:Int; var thumbnail:String; var boardName:String }
struct ExportFile: Decodable, Identifiable {
 var id:String; var layout:Int; var role:String; var variant:String; var mode:String; var format:String; var size:Int?; var path:String; var thumbnail:String; var group:String?; var label:String?
 var title:String { group ?? variant.replacingOccurrences(of:"-",with:" ").capitalized }
 var detail:String { label ?? mode.uppercased() + (size.map {" · \($0) px wide"} ?? " · vector") }
}
struct BrandColour: Decodable, Identifiable { var hex:String; var rgb:[Int]; var cmyk:[Int]; var items:[String]; var id:String {hex} }
struct Prepared: Decodable { var prepared:String; var files:[ExportFile]; var warnings:[String]; var checks:[String]?; var colours:[BrandColour]? }
struct ICCProfile: Decodable, Hashable { var name:String; var path:String }
struct ProfileList: Decodable { var profiles:[ICCProfile] }
struct Delivered: Decodable { var folder:String; var zip:String; var count:Int; var warnings:[String] }
struct ProgressReport: Decodable { var message:String; var completed:Int; var total:Int }
struct EngineError: Decodable {var error:String}

struct GuideOptions: Codable { var colours=true; var usage=true; var pdf=true; var minDigital=0; var minPrint=0; var notes=""; var pantone:[String:String]=[:] }

final class Model: ObservableObject {
 static let defaultTemplate="{brand}-{item}-{colour}-{mode}-{size}"
 static let tokens=["brand","item","colour","mode","size","format"]
 @Published var extras:Set<String>=[]
 @Published var profile=""
 @Published var template=Model.defaultTemplate
 @Published var guideOptions=GuideOptions()
 @Published var colours:[BrandColour]=[]
 @Published var installedProfiles:[ICCProfile]=[]
 var profilesLoaded=false
 @Published var recentProjects=UserDefaults.standard.stringArray(forKey:"LogoParcel.recentProjects") ?? []
 let builtinPresets=["Client handover","Digital only","Print supplier"]
 let currentRelease="0.6.0-beta.1"
 @Published var overrides:[String:[String:Artwork]]=[:]
 @Published var pendingVariant:String?=nil
 var importQueue:[ImportRequest]=[]
 @Published var previewBackground="Automatic"
 @Published var previewHex="#202023"
 @Published var presets:[String:ExportSettings]=[:]
 @Published var presetName=""
 @Published var showPresetEditor=false
 @Published var projectMessage=""
 var pendingSelection:[String]?=nil
 @Published var checks:[CheckIssue]=[]
 @Published var checksReviewed=false
 @Published var showChecks=false
 @Published var availableUpdate:GitHubRelease?=nil
 @Published var showUpdate=false
 @Published var checkingUpdate=false
 @Published var updateMessage=""
 @Published var automaticUpdates=UserDefaults.standard.object(forKey:"LogoParcel.autoUpdates") as? Bool ?? true {didSet{UserDefaults.standard.set(automaticUpdates,forKey:"LogoParcel.autoUpdates")}}
 @Published var includeBetas=UserDefaults.standard.object(forKey:"LogoParcel.betaUpdates") as? Bool ?? true {didSet{UserDefaults.standard.set(includeBetas,forKey:"LogoParcel.betaUpdates")}}
 var lastUpdateCheck=Date.distantPast
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
     if let versions=overrides.removeValue(forKey:old){overrides[cleanRole]=versions}
   } else {extraRoles.append(cleanRole)}
   invalidate();roleFilter="All artwork"
   showRoleEditor=false
 }
 func removeRole(_ role:String){guard extraRoles.contains(role) else{return};extraRoles.removeAll{$0==role};artwork.removeValue(forKey:role);overrides.removeValue(forKey:role);invalidate()}
 @Published var artwork:[String:Artwork]=[:]
 @Published var formats:Set<String>=["svg","png","pdf","ai","eps","jpg"]
 @Published var intent="both"
 @Published var variants:Set<String>=["full-colour"]
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
 let resources:URL
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
 var count:Int { let n=effectiveFormats.reduce(0){sum,format in sum + modes.filter{!($0=="cmyk" && ["svg","png"].contains(format))}.count * (["png","jpg"].contains(format) ? sizes.count : 1)};return n*selectedRoles.count*variants.count+selectedRoles.count*((extras.contains("favicon") ? 6 : 0)+(extras.contains("social") ? 5 : 0)+(extras.contains("email") ? 1 : 0)) }
 init(resources:URL?=nil){self.resources=resources ?? Bundle.main.resourceURL!;try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)
 if let data=UserDefaults.standard.data(forKey:"LogoParcel.presets"),let saved=try? JSONDecoder().decode([String:ExportSettings].self,from:data){presets=saved}
 }
 func toggle<T:Hashable>(_ key:ReferenceWritableKeyPath<Model,Set<T>>,_ value:T)->Binding<Bool>{Binding(get:{self[keyPath:key].contains(value)},set:{if $0 {self[keyPath:key].insert(value)} else {self[keyPath:key].remove(value)}})}
 func perform<T:Decodable>(_ cmd:String,config:[String:Any],message:String,done:@escaping(T)->Void) {
   let job=cache.appendingPathComponent(UUID().uuidString);let configURL=job.appendingPathComponent("config.json");let progressURL=job.appendingPathComponent("progress.json")
   do {
     try FileManager.default.createDirectory(at:job,withIntermediateDirectories:true)
     var d=config;d["progress"]=progressURL.path
     try JSONSerialization.data(withJSONObject:d).write(to:configURL)
   } catch {self.error=error.localizedDescription;return}
   busy=true;busyMessage=message;fraction=0
   progressTimer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true){[weak self] _ in
     if let data=try? Data(contentsOf:progressURL), let p=try? JSONDecoder().decode(ProgressReport.self,from:data) {self?.busyMessage=p.message; self?.fraction=Double(p.completed)/Double(max(p.total,1))}
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
       DispatchQueue.main.async {self.progressTimer?.invalidate();self.busy=false;done(value)}
     } catch {DispatchQueue.main.async {self.progressTimer?.invalidate();self.busy=false;self.importQueue=[];self.error=String(error.localizedDescription.prefix(1800))}}
   }
 }
 func add(_ role:String,variant:String?=nil){
   let p=NSOpenPanel();p.title="Choose \(variant ?? "full-colour") artwork for \(role)";p.prompt="Choose artwork";p.canChooseDirectories=false;p.allowsMultipleSelection=false;p.allowedFileTypes=["vectorcraft","svg","pdf","eps","ai"]
   guard p.runModal()==NSApplication.ModalResponse.OK,let url=p.url else{return}
   importURL(url,role:role,variant:variant)
 }
 func assign(_ role:String,_ result:Inspection,_ board:Board){
  let a=Artwork(source:result.source,index:board.index,thumbnail:board.thumbnail,boardName:board.name)
  if let variant=pendingVariant {overrides[role,default:[:]][variant]=a} else {artwork[role]=a}
  importWarnings+=result.warnings;pending=nil;pendingVariant=nil;invalidate()
 }
 func buildPreview(){
   var config=exportConfig;config["cache"]=cache.appendingPathComponent(UUID().uuidString).path
   perform("prepare",config:config,message:"Preparing your preview…") {(result:Prepared) in self.prepared=result.prepared;self.files=result.files;self.included=self.pendingSelection.map{Set($0).intersection(Set(result.files.map{$0.id}))} ?? Set(result.files.map{$0.id});self.pendingSelection=nil;self.warnings=result.warnings;self.colours=result.colours ?? [];self.roleFilter="All artwork";self.modeFilter="All files";self.step=2}
 }
 var templateError:String? {
  let t=template.trimmingCharacters(in:.whitespaces)
  if t.count>120 {return "Keep the pattern under 120 characters."}
  let regex=try! NSRegularExpression(pattern:"\\{([^}]*)\\}")
  for match in regex.matches(in:t,range:NSRange(t.startIndex...,in:t)) {
   if let r=Range(match.range(at:1),in:t), !Model.tokens.contains(String(t[r])) {return "Unknown part {\(t[r])}. Use {brand}, {item}, {colour}, {mode}, {size} or {format}."}
  }
  let remaining=t.replacingOccurrences(of:"\\{[^}]*\\}",with:"",options:.regularExpression)
  if remaining.contains("{") || remaining.contains("}"){return "Use complete filename parts such as {brand}."}
  return nil
 }
 var templateExample:String {
  let t=template.trimmingCharacters(in:.whitespaces)
  var name=t.isEmpty ? Model.defaultTemplate : t
  for (key,value) in ["brand":safeName,"item":roleKey(primaryRole),"colour":"full-colour","mode":"rgb","size":"1024px","format":"png"] {name=name.replacingOccurrences(of:"{\(key)}",with:value)}
  name=name.replacingOccurrences(of:"[^a-zA-Z0-9_.-]+",with:"-",options:.regularExpression).replacingOccurrences(of:"([-_.])[-_.]+",with:"$1",options:.regularExpression).trimmingCharacters(in:CharacterSet(charactersIn:"-_."))
  return name+".png"
 }
 func pantone(_ hex:String)->Binding<String>{Binding(get:{self.guideOptions.pantone[hex] ?? ""},set:{self.guideOptions.pantone[hex]=$0.isEmpty ? nil : String($0.prefix(40))})}
 func loadProfiles(){
  guard !profilesLoaded else{return}
  profilesLoaded=true
  perform("profiles",config:[:],message:"Finding print profiles…"){(result:ProfileList) in
   let chosen=self.installedProfiles.filter{p in !result.profiles.contains{$0.path==p.path}}
   self.installedProfiles=result.profiles+chosen
  }
 }
 func listProfile(_ path:String){if !path.isEmpty && !installedProfiles.contains(where:{$0.path==path}) {installedProfiles.append(ICCProfile(name:URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent,path:path))}}
 func chooseProfile(){
  let p=NSOpenPanel();p.title="Choose your printer’s CMYK profile";p.prompt="Use profile";p.canChooseDirectories=false;p.allowedFileTypes=["icc","icm"]
  if p.runModal()==NSApplication.ModalResponse.OK,let url=p.url {listProfile(url.path);profile=url.path}
 }
 func chooseOutput(){let p=NSOpenPanel();p.title="Where should your logo package be saved?";p.prompt="Save here";p.canChooseFiles=false;p.canChooseDirectories=true;p.canCreateDirectories=true;if p.runModal()==NSApplication.ModalResponse.OK,let url=p.url{output=url.path}}
 func export(){
   let g=guideOptions
   let guide:[String:Any]=["colours":g.colours,"usage":g.usage,"pdf":g.pdf,"minDigital":g.minDigital,"minPrint":g.minPrint,"notes":g.notes,"pantone":g.pantone]
   perform("deliver",config:["prepared":prepared,"include":Array(included),"brand":brand.trimmingCharacters(in:.whitespacesAndNewlines),"output":output,"template":template,"guide":guide],message:"Saving your package…"){(result:Delivered) in self.delivered=result;self.step=4}
 }

 func startAgain(){colours=[];guideOptions=GuideOptions();overrides=[:];importQueue=[];pendingVariant=nil;pendingSelection=nil;checks=[];projectMessage="";baseRoles=roles;extraRoles=[];artwork=[:];files=[];included=[];prepared="";delivered=nil;brand="";output="";importWarnings=[];warnings=[];step=0}
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
 var previewColour:Color {
  if background=="Custom",hex.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression) != nil,let n=UInt32(hex.dropFirst(),radix:16){return Color(red:Double((n>>16)&255)/255,green:Double((n>>8)&255)/255,blue:Double(n&255)/255)}
  return background=="Dark" || (background=="Automatic" && dark) ? Color(red:0.12,green:0.12,blue:0.13) : .white
 }
 var path:String;var dark=false;var background="Automatic";var hex="#202023"
 var body:some View {
   ZStack {
    previewColour
    if background=="Checkerboard" {Canvas{context,size in
     for row in 0..<Int(ceil(size.height/12)){for col in 0..<Int(ceil(size.width/12)) where (row+col)%2==0 {context.fill(Path(CGRect(x:col*12,y:row*12,width:12,height:12)),with:.color(.black.opacity(0.08)))}}
    }}
    if let image=NSImage(contentsOfFile:path) { Image(nsImage:image).resizable().aspectRatio(contentMode:.fit).padding(18) }
    else {Image(systemName:"photo").font(.title).foregroundColor(.secondary)}
   }.clipped()
 }
}
struct SectionTitle:View {var title:String;var subtitle:String;var body:some View {VStack(alignment:.leading,spacing:8){Text(title).font(.system(size:30,weight:.bold)).tracking(-0.7);Text(subtitle).font(.system(size:14)).foregroundColor(.secondary)}}}
struct Content:View {
 @ObservedObject var m:Model
 var body:some View {
  VStack(spacing:0){
   header
   Divider()
   ScrollView {VStack(alignment:.leading,spacing:24){
    switch m.step {case 0: artworkPage;case 1: optionsPage;case 2: previewPage;case 3: savePage;default:successPage}
   }.padding(30).frame(maxWidth:.infinity,alignment:.leading)}.id(m.step)
   Divider();footer
   creatorCredit
  }.disabled(m.busy).frame(width:1040,height:820).background(paper).foregroundColor(ink).tint(accent).buttonStyle(CraftButton()).preferredColorScheme(.light)
  .overlay {if m.busy {ZStack {Color.black.opacity(0.12);VStack(spacing:15){ProgressView().controlSize(.large);Text(m.busyMessage).font(.headline);ProgressView(value:m.fraction).frame(width:300);Text("Your original artwork stays untouched.").foregroundColor(.secondary).font(.system(size:11,design:.monospaced))}.padding(35).background(.regularMaterial,in:RoundedRectangle(cornerRadius:18))}.allowsHitTesting(true)}}
  .alert("Let’s fix that",isPresented:Binding(get:{m.error != nil},set:{if !$0{m.error=nil}})){Button("OK",role:.cancel){m.error=nil}}message:{Text(m.error ?? "")}
  .sheet(isPresented:Binding(get:{m.pending != nil},set:{if !$0{m.pending=nil}}),onDismiss:{m.importNext()}){boardPicker}
  .sheet(isPresented:$m.showRoleEditor){roleEditor}
  .sheet(isPresented:$m.showChecks){checkSheet}
  .sheet(isPresented:$m.showPresetEditor){presetSheet}
  .sheet(isPresented:$m.showUpdate){updateSheet}
  .task {await m.refreshStars();await m.checkUpdates();while !Task.isCancelled {do{try await Task.sleep(nanoseconds:60_000_000_000)}catch{break};await m.checkUpdates()}}
  .sheet(item:$m.enlarged){file in VStack(alignment:.leading,spacing:16){HStack{Text("\(file.role) · \(file.title)").font(.title2);Spacer();Button("Done"){m.enlarged=nil}};ArtImage(path:file.thumbnail,dark:["white","dark-background"].contains(file.variant),background:m.previewBackground,hex:m.previewHex).frame(height:440);Text("\(file.format.uppercased()) · \(file.detail)").foregroundColor(.secondary);Text("Preview background only. CMYK colours can look different in print.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}.padding(25).frame(width:700)}
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
    if let release=m.availableUpdate {Button("Update available · \(release.tag_name)"){m.showUpdate=true}.foregroundColor(accent)}
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
   if !m.recentProjects.isEmpty {Menu("Recent projects"){ForEach(m.recentProjects,id:\.self){path in Button(URL(fileURLWithPath:path).deletingPathExtension().lastPathComponent){if m.confirmReplace(){m.openProjectURL(URL(fileURLWithPath:path))}}};Button("Clear recent list"){m.recentProjects=[];UserDefaults.standard.removeObject(forKey:"LogoParcel.recentProjects")}}}
   HStack{Button("Open project…",action:m.openProject);Button("Save project…",action:m.saveProject).disabled(m.artwork.isEmpty);Spacer();if !m.projectMessage.isEmpty {Text(m.projectMessage).font(.caption).foregroundColor(.secondary)}}
   SectionTitle(title:"Start with your finished artwork",subtitle:"Start with your full logo, then add any symbols, wordmarks or lockup variations you need.")
   LazyVGrid(columns:[GridItem(.flexible(),spacing:0,alignment:.top),GridItem(.flexible(),spacing:0,alignment:.top),GridItem(.flexible(),spacing:0,alignment:.top)],spacing:16){ForEach(m.allRoles,id:\.self){role in artworkCard(role)}}
   Text("Drop saved artwork here to add multiple variations").font(.callout).foregroundColor(.secondary).frame(maxWidth:.infinity).padding(22).craftPanel().contentShape(Rectangle()).onDrop(of:[UTType.fileURL],isTargeted:nil){m.acceptDrop($0)}
   HStack{Button {m.editRole()}label:{Label("Add variation",systemImage:"plus")}.buttonStyle(CraftButton(primary:true));Text("Horizontal, vertical, with slogan, without slogan—or your own label.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}
   Label("Use SVG, VectorCraft, PDF, EPS or AI files. If a file has several artboards, you’ll choose one.",systemImage:"info.circle").font(.callout).foregroundColor(.secondary)
   HStack(alignment:.top,spacing:14){Image(systemName:"lightbulb").foregroundColor(accent);VStack(alignment:.leading,spacing:7){Text("Working in VectorCraft?").font(.headline);Text("Save your finished logo first. Add each component as its own file or artboard. A symbol is the icon on its own; a wordmark is the name on its own.").foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)}}.padding(20).frame(maxWidth:.infinity,alignment:.leading).craftPanel()
   if !m.importWarnings.isEmpty {DisclosureGroup("Artwork import notes (\(m.importWarnings.count))"){Text(m.importWarnings.joined(separator:"\n")).font(.system(size:11,design:.monospaced)).textSelection(.enabled)}}
  }
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
    HStack{Button("Replace…"){m.add(role)};Spacer();Button("Remove"){m.artwork.removeValue(forKey:role);m.overrides.removeValue(forKey:role);m.invalidate()}.foregroundColor(.secondary)}
   } else {
    VStack(spacing:12){Image(systemName:role==m.baseRoles[1] ? "sparkle" : role==m.baseRoles[2] ? "textformat" : "square.on.square").font(.system(size:30)).foregroundColor(accent.opacity(0.6));Text(role==m.primaryRole ? "Your complete logo" : role==m.baseRoles[1] ? "Your standalone icon" : role==m.baseRoles[2] ? "Your brand name" : "Your approved variation").foregroundColor(.secondary)}.frame(maxWidth:.infinity).frame(height:155).background(Color.black.opacity(0.025),in:Rectangle())
    Text(role==m.primaryRole ? "Needed to start your package" : "Leave empty if you don’t have one").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary).frame(height:30,alignment:.top)
    Button(m.baseRoles.contains(role) ? "Add \(role.lowercased())…" : "Choose artwork…"){m.add(role)}.buttonStyle(CraftButton()).frame(maxWidth:.infinity,alignment:.leading)
   }
   if m.artwork[role] != nil {
    DisclosureGroup("Approved colour versions"){
     VStack(alignment:.leading,spacing:12){
      Text("Optional: supply finished artwork to preserve cutouts and brand colours. These versions are used as supplied.").font(.caption).foregroundColor(.secondary)
      ForEach(["black","white","dark-background"],id:\.self){variant in
       VStack(alignment:.leading,spacing:4){
        HStack{Text(variant.replacingOccurrences(of:"-",with:" ").capitalized).font(.caption);Spacer();Button(m.overrides[role]?[variant]==nil ? "Add…" : "Replace…"){m.add(role,variant:variant)}}
        if let a=m.overrides[role]?[variant] {ArtImage(path:a.thumbnail,dark:variant != "black").frame(height:65);HStack{Text(a.boardName).font(.caption).lineLimit(1);Spacer();Button("Remove"){m.overrides[role]?.removeValue(forKey:variant);m.invalidate()}}}
       }
      }
     }.padding(.top,10)
    }.font(.caption)
   }
   if m.extraRoles.contains(role) {Divider();Button("Remove item"){m.removeRole(role)}}
  }.padding(18).frame(maxWidth:.infinity,alignment:.topLeading).craftPanel().contentShape(Rectangle()).onDrop(of:[UTType.fileURL],isTargeted:nil){m.acceptDrop($0,role:role)}
 }
 var optionsPage:some View {
  VStack(alignment:.leading,spacing:23){
   SectionTitle(title:"What do you need to deliver?",subtitle:"Choose where the logos will be used. We’ll handle the compatible colour modes.")
   HStack{Menu("Apply preset"){ForEach(m.builtinPresets+m.presets.keys.sorted(),id:\.self){name in Button(name){m.applyPreset(name)}}};Button("Save custom preset…"){m.showPresetEditor=true};if !m.presets.isEmpty {Menu("Delete preset"){ForEach(m.presets.keys.sorted(),id:\.self){name in Button(name){m.deletePreset(name)}}}};Spacer();Button("Save project…",action:m.saveProject)}
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
   VStack(alignment:.leading,spacing:12){Text("COLOUR VERSIONS").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.5);HStack(spacing:30){ForEach(["full-colour","black","white","dark-background"],id:\.self){v in Toggle(v.replacingOccurrences(of:"-",with:" ").capitalized,isOn:m.toggle(\.variants,v))}};Text("Black and white use your approved versions when supplied; otherwise colours are merged automatically. Review the artwork checks before exporting.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}.padding(18).frame(maxWidth:.infinity,alignment:.leading).craftPanel()
   VStack(alignment:.leading,spacing:12){Text("WEB & SOCIAL SETS").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.5)
    HStack(alignment:.top,spacing:30){ForEach(Array([("favicon","Favicons","favicon.ico, 16 and 32 px, Apple touch icon, Android 192 and 512 px"),("social","Social media","Profile avatar and LinkedIn, X, Facebook and YouTube covers"),("email","Email signature","600 px wide transparent PNG")].enumerated()),id:\.offset){_,option in
     Toggle(isOn:m.toggle(\.extras,option.0)){VStack(alignment:.leading,spacing:3){Text(option.1).font(.headline);Text(option.2).font(.system(size:11,design:.monospaced)).foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)}}.frame(maxWidth:.infinity,alignment:.leading)
    }}
    Text("Full-colour RGB PNGs for each artwork item, ready to upload. A symbol makes the clearest favicon.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)
   }.padding(18).frame(maxWidth:.infinity,alignment:.leading).craftPanel()
   DisclosureGroup("More options",isExpanded:$m.advanced){VStack(alignment:.leading,spacing:16){
    if m.rasterChosen {HStack{Text("Image widths").frame(width:120,alignment:.leading);ForEach([512,1024,2048,4096],id:\.self){n in Toggle("\(n) px",isOn:m.toggle(\.sizes,n))}}}
    HStack{Text("Clear space").frame(width:120,alignment:.leading);Picker("Padding",selection:$m.padding){Text("None").tag(0);Text("Small · 5%").tag(5);Text("Standard · 10%").tag(10);Text("Generous · 20%").tag(20)}.labelsHidden().frame(width:210);Text("On each side of the artwork").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}
    HStack(spacing:25){Toggle("Grayscale",isOn:m.toggle(\.variants,"grayscale"));Toggle("Custom solid colour",isOn:m.toggle(\.variants,"custom"));if m.variants.contains("custom"){TextField("#7355DD",text:$m.custom).textFieldStyle(.roundedBorder).frame(width:110)}}
    Toggle("Outline text in SVG files",isOn:$m.outline)
    if m.intent != "rgb" {
     Button("Find installed print profiles",action:m.loadProfiles).disabled(m.profilesLoaded)
     HStack{Text("Print profile").frame(width:120,alignment:.leading);Picker("Print profile",selection:$m.profile){Text("VectorCraft generic CMYK (SWOP-like)").tag("");ForEach(m.installedProfiles,id:\.path){p in Text(p.name).tag(p.path)}}.labelsHidden().frame(width:330);Button("Choose ICC file…",action:m.chooseProfile)}
     Text("CMYK files and brand colour values are converted with this profile. Ask your printer which one they need, for example Coated FOGRA39 or GRACoL.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)
    }

   }.padding(.top,14)}
   if !m.canPreview {Label(m.effectiveFormats.isEmpty ? "Choose at least one available format." : m.variants.isEmpty ? "Choose at least one colour version." : m.rasterChosen && m.sizes.isEmpty ? "Choose at least one image width in More options." : "Enter a custom colour such as #7355DD.",systemImage:"exclamationmark.circle").foregroundColor(.orange)}
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
   previewControls
   Text("\(m.included.count) of \(m.files.count) files selected · Preview backgrounds do not change your exported files.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)
   if !m.warnings.isEmpty {DisclosureGroup("Review \(m.warnings.count) export notes"){Text(m.warnings.joined(separator:"\n")).font(.system(size:11,design:.monospaced)).textSelection(.enabled)}}
   LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())],spacing:16){ForEach(m.visible){file in
    VStack(alignment:.leading,spacing:10){
     Button {m.enlarged=file} label:{ArtImage(path:file.thumbnail,dark:["white","dark-background"].contains(file.variant),background:m.previewBackground,hex:m.previewHex).frame(height:125)}.buttonStyle(.plain)
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
   case 1:Button("Check artwork & preview",action:m.checkArtwork).buttonStyle(CraftButton(primary:true)).disabled(!m.canPreview)
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
 @StateObject var model=Model()
 var body:some Scene{WindowGroup{Content(m:model).onAppear{NSApplication.shared.activate(ignoringOtherApps:true)}}.windowStyle(.titleBar).windowResizability(.contentSize).commands{
  CommandGroup(after:.appInfo){Button("Check for Updates…"){Task{await model.checkUpdates(manual:true)}}.disabled(model.checkingUpdate)}
  CommandGroup(replacing:.newItem){Button("New Project"){if model.confirmReplace(){model.startAgain()}}.keyboardShortcut("n").disabled(model.busy);Button("Open Project…",action:model.openProject).keyboardShortcut("o").disabled(model.busy);Button("Save Project…",action:model.saveProject).keyboardShortcut("s").disabled(model.busy || model.artwork.isEmpty)}
 }}
}
struct ExportSettings:Codable {
 var formats:Set<String>;var intent:String;var variants:Set<String>;var sizes:Set<Int>;var padding:Int;var custom:String;var outline:Bool;var extras:Set<String>?=nil;var profile:String?=nil;var template:String?=nil
}
struct ProjectItem:Codable {var name:String;var artwork:[String:Artwork]}
struct ProjectDocument:Codable {var version:Int;var baseRoles:[String];var extraRoles:[String];var items:[ProjectItem];var settings:ExportSettings;var brand:String;var previewBackground:String;var previewHex:String;var selectedIDs:[String]?;var guide:GuideOptions?=nil}
struct SavedProject:Decodable {var path:String}
struct CheckIssue:Decodable,Identifiable {var role:String;var message:String;var severity:String;var id:String {role+message}}
struct ArtworkCheck:Decodable {var issues:[CheckIssue];var colours:[String]}
struct GitHubRelease:Decodable,Identifiable {var tag_name:String;var html_url:String;var body:String?;var draft:Bool;var prerelease:Bool;var id:String {tag_name}}
struct ImportRequest {var url:URL;var role:String;var variant:String?}
struct ReleaseVersion:Comparable {
 var core:[Int];var pre:[String]
 init?(_ value:String){
  guard value.range(of:#"^v?[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z.-]+)?$"#,options:.regularExpression) != nil else{return nil}
  let raw=value.hasPrefix("v") ? String(value.dropFirst()) : value
  let parts=raw.components(separatedBy:"+")[0].split(separator:"-",maxSplits:1).map(String.init)
  let coreParts=parts[0].split(separator:".").map(String.init)
  guard coreParts.count==3,coreParts.allSatisfy({Int($0) != nil && Int($0)!>=0}) else{return nil}
  core=coreParts.map{Int($0)!};pre=parts.count==2 ? parts[1].components(separatedBy:".") : []
 }
 static func <(a:Self,b:Self)->Bool {
  if a.core != b.core {return a.core.lexicographicallyPrecedes(b.core)}
  if a.pre.isEmpty || b.pre.isEmpty {return !a.pre.isEmpty && b.pre.isEmpty}
  for (x,y) in zip(a.pre,b.pre) where x != y {
   if let i=Int(x),let j=Int(y){return i<j};if Int(x) != nil{return true};if Int(y) != nil{return false};return x<y
  }
  return a.pre.count<b.pre.count
 }
}
extension Model {
 var settings:ExportSettings {ExportSettings(formats:formats,intent:intent,variants:variants,sizes:sizes,padding:padding,custom:custom,outline:outline,extras:extras,profile:profile,template:template)}
 func apply(_ s:ExportSettings){
  extras=(s.extras ?? []).intersection(["favicon","social","email"]);profile=s.profile ?? "";template=s.template ?? Model.defaultTemplate;listProfile(profile)
  formats=s.formats.intersection(["svg","png","jpg","pdf","eps","ai"]);intent=["rgb","cmyk","both"].contains(s.intent) ? s.intent : "both"
  variants=s.variants.intersection(["full-colour","black","white","grayscale","dark-background","custom"])
  sizes=s.sizes.filter{(16...10000).contains($0)};padding=min(100,max(0,s.padding));custom=s.custom;outline=s.outline;invalidate()
 }
 func invalidate(){files=[];included=[];prepared="";pendingSelection=nil;checks=[];checksReviewed=false}
 func applyPreset(_ name:String){
  let s:ExportSettings
  if name=="Client handover" {s=ExportSettings(formats:["svg","png","jpg","pdf"],intent:"both",variants:["full-colour"],sizes:[1024,2048],padding:10,custom:custom,outline:true)}
  else if name=="Digital only" {s=ExportSettings(formats:["svg","png","jpg"],intent:"rgb",variants:["full-colour"],sizes:[1024,2048],padding:10,custom:custom,outline:true)}
  else if name=="Print supplier" {s=ExportSettings(formats:["pdf","eps"],intent:"cmyk",variants:["full-colour"],sizes:[1024],padding:10,custom:custom,outline:true)}
  else if let saved=presets[name] {s=saved} else {return}
  apply(s)
 }
 func savePreset(){
  let name=presetName.trimmingCharacters(in:.whitespacesAndNewlines)
  guard !name.isEmpty,name.count<=50,!builtinPresets.contains(name),presets[name]==nil else{return}
  presets[name]=settings
  if let data=try? JSONEncoder().encode(presets){UserDefaults.standard.set(data,forKey:"LogoParcel.presets")}
  presetName="";showPresetEditor=false
 }
 func deletePreset(_ name:String){presets.removeValue(forKey:name);if let data=try? JSONEncoder().encode(presets){UserDefaults.standard.set(data,forKey:"LogoParcel.presets")}}
 var layoutConfig:[[String:Any]] {selectedRoles.compactMap{role in
  guard let a=artwork[role] else{return nil}
  return ["source":a.source,"index":a.index,"name":role,"overrides":(overrides[role] ?? [:]).mapValues{["source":$0.source,"index":$0.index] as [String:Any]}]
 }}
 var exportConfig:[String:Any] {["layouts":layoutConfig,"brand":"Logo","formats":effectiveFormats,"variants":["full-colour","black","white","grayscale","dark-background","custom"].filter{variants.contains($0)},"modes":modes,"sizes":sizes.isEmpty ? [1024] : sizes.sorted(),"padding":padding,"custom":custom,"outline":outline,"extras":Array(extras),"profile":profile]}
 func checkArtwork(){
  guard canPreview,!busy else{return}
  perform("preflight",config:exportConfig,message:"Checking artwork, fonts and image quality…"){(result:ArtworkCheck) in
   self.checks=result.issues;self.checksReviewed=result.issues.isEmpty;self.showChecks=true
  }
 }
 func importURL(_ url:URL,role:String,variant:String?=nil){
  guard ["svg","vectorcraft","pdf","eps","ai"].contains(url.pathExtension.lowercased()),url.isFileURL else{error="Choose an SVG, VectorCraft, PDF, EPS or AI file.";return}
  importQueue.append(ImportRequest(url:url,role:role,variant:variant));importNext()
 }
 func importNext(){
  guard !busy,pending==nil,!importQueue.isEmpty else{return}
  let request=importQueue.removeFirst();pendingRole=request.role;pendingVariant=request.variant
  let dir=cache.appendingPathComponent(UUID().uuidString)
  perform("inspect-previews",config:["source":request.url.path,"cache":dir.path],message:"Reading \(request.role)…"){(result:Inspection) in
   if result.layouts.isEmpty {self.error="There are no artboards in this file.";self.importNext();return}
   if result.layouts.count==1 {self.assign(request.role,result,result.layouts[0]);self.importNext()}
   else {self.chosenBoard=result.layouts[0].index;self.pending=result}
  }
 }
 func uniqueRole(_ name:String)->String {
  let cleaned=String(name.prefix(40)).trimmingCharacters(in:.whitespacesAndNewlines)
  let base=roleKey(cleaned).isEmpty ? "Variation" : cleaned
  var candidate=base;var n=2
  while allRoles.contains(where:{roleKey($0)==roleKey(candidate)}) || roleKey(candidate)==roleKey("All artwork") {candidate=base+" \(n)";n+=1}
  return candidate
 }
 func acceptDrop(_ providers:[NSItemProvider],role:String?=nil)->Bool {
  guard !busy,pending==nil,importQueue.isEmpty else{return false}
  let candidates=providers.filter{$0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)}
  guard !candidates.isEmpty,candidates.count<=100 else{return false}
  let group=DispatchGroup();let lock=NSLock();var urls:[Int:URL]=[:]
  for (i,provider) in candidates.enumerated(){group.enter();provider.loadItem(forTypeIdentifier:UTType.fileURL.identifier,options:nil){item,_ in
   let url:URL? = (item as? URL) ?? (item as? Data).flatMap{URL(dataRepresentation:$0,relativeTo:nil)}
   if let url=url {lock.lock();urls[i]=url;lock.unlock()};group.leave()
  }}
  group.notify(queue:.main){
   let ordered=urls.keys.sorted().compactMap{urls[$0]}
   let valid=ordered.filter{$0.isFileURL && ["svg","vectorcraft","pdf","eps","ai"].contains($0.pathExtension.lowercased())}
   if valid.count != candidates.count {self.error="Some dropped items were unsupported. Drop saved SVG, VectorCraft, PDF, EPS or AI files."}
   for (i,url) in valid.enumerated(){
    guard self.allRoles.count<100 || (i==0 && role != nil) else{self.error="Keep projects to 100 artwork items or fewer.";break}
    let name:String
    if i==0,let role=role {name=role}
    else if self.artwork[self.primaryRole]==nil && !self.importQueue.contains(where:{$0.role==self.primaryRole}) {name=self.primaryRole}
    else {name=self.uniqueRole(url.deletingPathExtension().lastPathComponent);self.extraRoles.append(name)}
    self.importQueue.append(ImportRequest(url:url,role:name,variant:nil))
   };self.importNext()
  };return true
 }
 func saveProject(){
  guard !busy,!artwork.isEmpty else{return}
  let panel=NSSavePanel();panel.title="Save Logo Parcel project";panel.nameFieldStringValue=(brand.isEmpty ? "Logo Project" : safeName)+".logoparcel";panel.allowedFileTypes=["logoparcel"]
  guard panel.runModal() == .OK,let url=panel.url else{return}
  let items=allRoles.map{role -> ProjectItem in var entries=overrides[role] ?? [:];if let a=artwork[role]{entries["full-colour"]=a};return ProjectItem(name:role,artwork:entries)}
  let project=ProjectDocument(version:1,baseRoles:baseRoles,extraRoles:extraRoles,items:items,settings:settings,brand:brand,previewBackground:previewBackground,previewHex:previewHex,selectedIDs:prepared.isEmpty ? pendingSelection : Array(included),guide:guideOptions)
  do {let data=try JSONEncoder().encode(project);let object=try JSONSerialization.jsonObject(with:data)
   perform("save-project",config:["path":url.path,"project":object],message:"Saving a portable project…"){(result:SavedProject) in self.rememberProject(url);self.projectMessage="Project saved: "+URL(fileURLWithPath:result.path).lastPathComponent}
  } catch {self.error=error.localizedDescription}
 }
 func confirmReplace()->Bool {
  guard !artwork.isEmpty else{return true}
  let alert=NSAlert();alert.messageText="Replace this workspace?";alert.informativeText="Save a project first if you want to return to the current artwork and settings.";alert.addButton(withTitle:"Cancel");alert.addButton(withTitle:"Replace workspace")
  return alert.runModal() == .alertSecondButtonReturn
 }
 func openProject(){
  guard !busy else{return}
  let panel=NSOpenPanel();panel.title="Open Logo Parcel project";panel.allowedFileTypes=["logoparcel"];panel.canChooseDirectories=false
  guard panel.runModal() == .OK,let url=panel.url,confirmReplace() else{return}
  openProjectURL(url)
 }
 func rememberProject(_ url:URL){recentProjects.removeAll{$0==url.path};recentProjects.insert(url.path,at:0);recentProjects=Array(recentProjects.prefix(8));UserDefaults.standard.set(recentProjects,forKey:"LogoParcel.recentProjects")}
 func openProjectURL(_ url:URL){
  perform("open-project",config:["path":url.path,"cache":cache.appendingPathComponent(UUID().uuidString).path],message:"Opening saved project…"){(project:ProjectDocument) in
   let names=project.baseRoles+project.extraRoles
   guard project.version==1,project.baseRoles.count==3,names.count<=100,Set(names.map{self.roleKey($0)}).count==names.count,names.allSatisfy({!self.roleKey($0).isEmpty && $0.count<=50 && self.roleKey($0) != self.roleKey("All artwork")}),Set(project.items.map{$0.name})==Set(names) else {self.error="This project has invalid artwork labels.";return}
   self.startAgain();self.baseRoles=project.baseRoles;self.extraRoles=project.extraRoles
   for item in project.items {self.artwork[item.name]=item.artwork["full-colour"];self.overrides[item.name]=item.artwork.filter{["black","white","dark-background"].contains($0.key)}}
   self.rememberProject(url);self.guideOptions=project.guide ?? GuideOptions();self.apply(project.settings);self.brand=project.brand;self.previewBackground=project.previewBackground;self.previewHex=project.previewHex;self.pendingSelection=project.selectedIDs;self.projectMessage="Opened "+url.lastPathComponent
  }
 }
 @MainActor func checkUpdates(manual:Bool=false) async {
  if checkingUpdate{return}
  if !manual && (!automaticUpdates || Date().timeIntervalSince(lastUpdateCheck)<86400){return}
  checkingUpdate=true;lastUpdateCheck=Date();defer{checkingUpdate=false}
  if manual {updateMessage="Checking GitHub…";showUpdate=true}
  var request=URLRequest(url:URL(string:"https://api.github.com/repos/stellienft/logo-parcel/releases?per_page=100")!);request.timeoutInterval=12;request.setValue("LogoParcel",forHTTPHeaderField:"User-Agent");request.setValue("application/vnd.github+json",forHTTPHeaderField:"Accept")
  let session=URLSession(configuration:.ephemeral);defer{session.invalidateAndCancel()}
  do {
   let(data,response)=try await session.data(for:request)
   guard (response as? HTTPURLResponse)?.statusCode==200 else{throw URLError(.badServerResponse)}
   let releases=try JSONDecoder().decode([GitHubRelease].self,from:data)
   let current=ReleaseVersion(currentRelease)!
   let latest=releases.filter{!$0.draft && (includeBetas || !$0.prerelease) && ReleaseVersion($0.tag_name) != nil && $0.html_url.hasPrefix("https://github.com/stellienft/logo-parcel/releases/tag/")}.max{ReleaseVersion($0.tag_name)! < ReleaseVersion($1.tag_name)!}
   availableUpdate=latest.flatMap{ReleaseVersion($0.tag_name)!>current ? $0 : nil}
   updateMessage=availableUpdate == nil ? "You’re up to date (\(currentRelease))." : "A new version is available. Download it from GitHub, quit this app and replace your old copy."
  } catch {updateMessage="Couldn’t check for updates. Check your internet connection or try again later. The app still works offline."}
 }
}
extension Content {
 var previewControls:some View {
  VStack(alignment:.leading,spacing:8){
   HStack{Picker("Preview background",selection:$m.previewBackground){ForEach(["Automatic","White","Dark","Checkerboard","Custom"],id:\.self){Text($0).tag($0)}}.frame(width:300)
    if m.previewBackground=="Custom" {TextField("#202023",text:$m.previewHex).textFieldStyle(.roundedBorder).frame(width:100)}
    Spacer();Button("Save project…",action:m.saveProject)
   }
   Text("Preview only. JPEG backgrounds are baked into the image: white and dark-background versions use black; other versions use white.").font(.caption).foregroundColor(.secondary)
   if m.previewBackground=="Custom" && m.previewHex.range(of:"^#[0-9a-fA-F]{6}$",options:.regularExpression)==nil {Text("Enter a six-digit colour such as #202023.").font(.caption).foregroundColor(.orange)}
  }
 }
 var checkSheet:some View {
  VStack(alignment:.leading,spacing:18){
   SectionTitle(title:"Review your artwork",subtitle:"Font availability, linked images, bitmap resolution and automatic colour changes.")
   if m.checks.isEmpty {Label("No issues found by these checks",systemImage:"checkmark.circle").foregroundColor(.green)}
   else {ScrollView{VStack(alignment:.leading,spacing:15){ForEach(m.checks){issue in
    HStack(alignment:.top){Image(systemName:issue.severity=="error" ? "xmark.octagon" : "exclamationmark.triangle").foregroundColor(issue.severity=="error" ? .red : .orange);VStack(alignment:.leading,spacing:4){Text(issue.role).bold();Text(issue.message).fixedSize(horizontal:false,vertical:true)}}
   }}}.frame(maxHeight:310)}
   Text("These checks do not certify a logo for print. Review every preview; confirm final sizes, colour profiles and brand rules with your printer or designer.").font(.caption).foregroundColor(.secondary)
   if !m.checks.isEmpty && !m.checks.contains(where:{$0.severity=="error"}) {Toggle("I’ve reviewed these notes and want to build the preview",isOn:$m.checksReviewed)}
   HStack{Button("Back to options"){m.showChecks=false};Spacer();Button("Build preview"){m.showChecks=false;m.buildPreview()}.buttonStyle(CraftButton(primary:true)).disabled(!m.checksReviewed || m.checks.contains(where:{$0.severity=="error"}))}
  }.padding(28).frame(width:720).background(paper).buttonStyle(CraftButton())
 }
 var presetSheet:some View {
  VStack(alignment:.leading,spacing:18){Text("Save export preset").font(.title2.bold());Text("Remembers formats, colour versions, image widths and padding. Artwork and file selections stay with your project.").foregroundColor(.secondary);TextField("Preset name",text:$m.presetName).textFieldStyle(.roundedBorder);HStack{Button("Cancel"){m.showPresetEditor=false};Spacer();Button("Save preset",action:m.savePreset).disabled(m.presetName.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || m.presetName.count>50 || m.builtinPresets.contains(m.presetName.trimmingCharacters(in:.whitespacesAndNewlines)) || m.presets[m.presetName.trimmingCharacters(in:.whitespacesAndNewlines)] != nil)}}.padding(28).frame(width:540).background(paper).buttonStyle(CraftButton())
 }
 var updateSheet:some View {
  VStack(alignment:.leading,spacing:18){
   Text("Logo Parcel updates").font(.title2.bold());Text(m.currentRelease).font(.caption.monospaced()).foregroundColor(.secondary)
   if m.checkingUpdate {ProgressView()}
   Text(m.updateMessage.isEmpty ? "A new version is available." : m.updateMessage)
   if let release=m.availableUpdate {Text(release.tag_name).bold();ScrollView{Text(release.body ?? "See GitHub for release notes.").frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)}.frame(maxHeight:220)}
   Toggle("Check automatically when opening and daily while running",isOn:$m.automaticUpdates)
   Toggle("Include beta releases",isOn:$m.includeBetas).onChange(of:m.includeBetas){_ in m.availableUpdate=nil;Task{await m.checkUpdates(manual:true)}}
   Text("Only version information is requested from GitHub. Your artwork is never uploaded. Updates are downloaded and installed manually.").font(.caption).foregroundColor(.secondary)
   HStack{Button("Close"){m.showUpdate=false};Button("Check now"){Task{await m.checkUpdates(manual:true)}}.disabled(m.checkingUpdate);Spacer();if let release=m.availableUpdate,let url=URL(string:release.html_url){Link("View update on GitHub ↗",destination:url)}}
  }.padding(28).frame(width:680).background(paper).buttonStyle(CraftButton())
 }
}
