import Cocoa
import SwiftUI

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
 var id:String; var layout:Int; var role:String; var variant:String; var mode:String; var format:String; var size:Int?; var path:String; var thumbnail:String
 var title:String { variant.replacingOccurrences(of:"-",with:" ").capitalized }
 var detail:String { mode.uppercased() + (size.map {" · \($0) px wide"} ?? " · vector") }
}
struct Prepared: Decodable { var prepared:String; var files:[ExportFile]; var warnings:[String] }
struct Delivered: Decodable { var folder:String; var zip:String; var count:Int; var warnings:[String] }
struct ProgressReport: Decodable { var message:String; var completed:Int; var total:Int }
struct EngineError: Decodable {var error:String}

final class Model: ObservableObject {
 @Published var step=0
 @Published var extraRoles:[String]=[]
 @Published var showRoleEditor=false
 @Published var editingRole:String?=nil
 @Published var roleDraft=""
 var allRoles:[String] {roles+extraRoles}
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
   if let old=editingRole,let i=extraRoles.firstIndex(of:old) {
     extraRoles[i]=cleanRole
     if let image=artwork.removeValue(forKey:old){artwork[cleanRole]=image}
   } else {extraRoles.append(cleanRole)}
   showRoleEditor=false
 }
 func removeRole(_ role:String){extraRoles.removeAll{$0==role};artwork.removeValue(forKey:role)}
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
 var count:Int { let n=effectiveFormats.reduce(0){sum,format in sum + modes.filter{!($0=="cmyk" && ["svg","png"].contains(format))}.count * (["png","jpg"].contains(format) ? sizes.count : 1)};return n*selectedRoles.count*variants.count }
 init(){try? FileManager.default.createDirectory(at:cache,withIntermediateDirectories:true)}
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
       let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/python3");p.arguments=[self.resources.appendingPathComponent("packager.py").path,cmd,configURL.path]
       let stdout=Pipe();p.standardOutput=stdout
       let errURL=job.appendingPathComponent("engine.log");FileManager.default.createFile(atPath:errURL.path,contents:nil)
       let err=try FileHandle(forWritingTo:errURL);defer {try? err.close()};p.standardError=err
       try p.run();let data=stdout.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
       if let e=try? JSONDecoder().decode(EngineError.self,from:data){throw NSError(domain:"LogoParcel",code:1,userInfo:[NSLocalizedDescriptionKey:e.error])}
       guard p.terminationStatus==0 else {throw NSError(domain:"LogoParcel",code:2,userInfo:[NSLocalizedDescriptionKey:"The export engine stopped. Your original artwork is safe. Try a simpler SVG or VectorCraft file."])}
       let value=try JSONDecoder().decode(T.self,from:data)
       DispatchQueue.main.async {self.progressTimer?.invalidate();self.busy=false;done(value)}
     } catch {DispatchQueue.main.async {self.progressTimer?.invalidate();self.busy=false;self.error=String(error.localizedDescription.prefix(1800))}}
   }
 }
 func add(_ role:String){
   let p=NSOpenPanel();p.title="Choose your \(role.lowercased())";p.prompt="Choose artwork";p.canChooseDirectories=false;p.allowsMultipleSelection=false;p.allowedFileTypes=["vectorcraft","svg","pdf","eps","ai"]
   guard p.runModal()==NSApplication.ModalResponse.OK,let url=p.url else{return}
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
   let config:[String:Any]=["layouts":layouts,"brand":"Logo","formats":effectiveFormats,"variants":["full-colour","black","white","grayscale","inverted","custom"].filter{variants.contains($0)},"modes":modes,"sizes":sizes.isEmpty ? [1024] : sizes.sorted(),"padding":padding,"custom":custom,"outline":outline,"cache":dir.path]
   perform("prepare",config:config,message:"Preparing your preview…") {(result:Prepared) in self.prepared=result.prepared;self.files=result.files;self.included=Set(result.files.map{$0.id});self.warnings=result.warnings;self.roleFilter="All artwork";self.modeFilter="All files";self.step=2}
 }
 func chooseOutput(){let p=NSOpenPanel();p.title="Where should your logo package be saved?";p.prompt="Save here";p.canChooseFiles=false;p.canChooseDirectories=true;p.canCreateDirectories=true;if p.runModal()==NSApplication.ModalResponse.OK,let url=p.url{output=url.path}}
 func export(){perform("deliver",config:["prepared":prepared,"include":Array(included),"brand":brand.trimmingCharacters(in:.whitespacesAndNewlines),"output":output],message:"Saving your package…"){(result:Delivered) in self.delivered=result;self.step=4}}
 func startAgain(){extraRoles=[];artwork=[:];files=[];included=[];prepared="";delivered=nil;brand="";output="";importWarnings=[];warnings=[];step=0}
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
  .sheet(item:$m.enlarged){file in VStack(alignment:.leading,spacing:16){HStack{Text("\(file.role) · \(file.title)").font(.title2);Spacer();Button("Done"){m.enlarged=nil}};ArtImage(path:file.thumbnail,dark:file.variant=="white").frame(height:440);Text("\(file.format.uppercased()) · \(file.detail)").foregroundColor(.secondary);Text("Screen preview. CMYK colours can look different in print.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}.padding(25).frame(width:700)}
 }
 var creatorCredit:some View {
  HStack(spacing:7){
   Text("CREATED BY").foregroundColor(.secondary)
   if let url=creatorWebsite {Link("STELLIO CREATIVE LABS ↗",destination:url).foregroundColor(ink)}
   else {Text("STELLIO CREATIVE LABS").foregroundColor(ink)}
   Spacer()
   Link("GITHUB / @STELLIENFT ↗",destination:URL(string:"https://github.com/stellienft")!).foregroundColor(.secondary)
  }.font(.system(size:9,weight:.medium,design:.monospaced)).tracking(1).padding(.horizontal,30).padding(.bottom,13)
 }
 var header:some View {
  VStack(spacing:0){
   HStack(spacing:20){
    (Text("Logo").foregroundColor(ink)+Text("Parcel").foregroundColor(accent)).font(.system(size:27,weight:.heavy)).tracking(-1)
    Rectangle().fill(rule).frame(width:1,height:30)
    Text("LOGO PACKAGING").font(.system(size:10,weight:.semibold,design:.monospaced)).tracking(2).foregroundColor(.secondary)
    Spacer()
    Text("VECTORCRAFT COMPANION").font(.system(size:10,design:.monospaced)).tracking(1.5).foregroundColor(.secondary)
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
   Label("Use SVG, VectorCraft, PDF, EPS or AI files. If a file has several artboards, you’ll choose one.",systemImage:"info.circle").font(.callout).foregroundColor(.secondary)
   HStack(alignment:.top,spacing:14){Image(systemName:"lightbulb").foregroundColor(accent);VStack(alignment:.leading,spacing:7){Text("Working in VectorCraft?").font(.headline);Text("Save your finished logo first. Add each component as its own file or artboard. A symbol is the icon on its own; a wordmark is the name on its own.").foregroundColor(.secondary).fixedSize(horizontal:false,vertical:true)}}.padding(20).frame(maxWidth:.infinity,alignment:.leading).craftPanel()
   if !m.importWarnings.isEmpty {DisclosureGroup("Artwork import notes (\(m.importWarnings.count))"){Text(m.importWarnings.joined(separator:"\n")).font(.system(size:11,design:.monospaced)).textSelection(.enabled)}}
  }
 }
 func artworkCard(_ role:String)->some View {
  VStack(alignment:.leading,spacing:13){
   HStack{Text(String(format:"%02d",(m.allRoles.firstIndex(of:role) ?? 0)+1)).font(.system(size:10,weight:.bold,design:.monospaced)).tracking(1).padding(.horizontal,7).padding(.vertical,5).background(accent);Spacer();Text(role=="Full logo" ? "REQUIRED" : "OPTIONAL").font(.system(size:10,design:.monospaced)).tracking(1.5).foregroundColor(.secondary)}
   Divider()
   Text(role).font(.system(size:22,weight:.bold)).tracking(-0.5).lineLimit(2).frame(minHeight:28,alignment:.leading)
   if let a=m.artwork[role] {
    ArtImage(path:a.thumbnail).frame(height:155)
    Text(URL(fileURLWithPath:a.source).lastPathComponent).font(.system(size:11,design:.monospaced)).lineLimit(1).truncationMode(.middle)
    Text(a.boardName).font(.system(size:11,design:.monospaced)).foregroundColor(.secondary).lineLimit(1)
    HStack{Button("Replace…"){m.add(role)};Spacer();Button("Remove"){m.artwork.removeValue(forKey:role)}.foregroundColor(.secondary)}
   } else {
    VStack(spacing:12){Image(systemName:role=="Symbol" ? "sparkle" : role=="Wordmark" ? "textformat" : "square.on.square").font(.system(size:30)).foregroundColor(accent.opacity(0.6));Text(role=="Full logo" ? "Your complete logo" : role=="Symbol" ? "Your standalone icon" : role=="Wordmark" ? "Your brand name" : "Your approved variation").foregroundColor(.secondary)}.frame(maxWidth:.infinity).frame(height:155).background(Color.black.opacity(0.025),in:Rectangle())
    Text(role=="Full logo" ? "Needed to start your package" : "Leave empty if you don’t have one").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary).frame(height:30,alignment:.top)
    Button(roles.contains(role) ? "Add \(role.lowercased())…" : "Choose artwork…"){m.add(role)}.buttonStyle(CraftButton()).frame(maxWidth:.infinity,alignment:.leading)
   }
   if m.extraRoles.contains(role) {
    Divider()
    HStack {Button("Rename"){m.editRole(role)};Spacer();Button("Remove item"){m.removeRole(role)}}
   }
  }.padding(18).frame(maxWidth:.infinity,alignment:.topLeading).craftPanel()
 }
 var optionsPage:some View {
  VStack(alignment:.leading,spacing:23){
   SectionTitle(title:"What do you need to deliver?",subtitle:"Choose where the logos will be used. We’ll handle the compatible colour modes.")
   HStack(spacing:0){ForEach(["rgb","cmyk","both"],id:\.self){mode in
    Button{m.intent=mode}label:{VStack(alignment:.leading,spacing:8){Text(mode=="rgb" ? "DIGITAL ONLY" : mode=="cmyk" ? "PRINT ONLY" : "DIGITAL + PRINT").font(.system(size:11,weight:.bold,design:.monospaced)).tracking(1.3);Text(mode=="rgb" ? "RGB · screens & websites" : mode=="cmyk" ? "CMYK · print files" : "Both RGB and CMYK").font(.system(size:12))}.frame(maxWidth:.infinity,alignment:.leading).padding(18).foregroundColor(m.intent==mode ? .white : ink).background(m.intent==mode ? ink : Color.clear).overlay(Rectangle().stroke(rule,lineWidth:1))}.buttonStyle(.plain)
   }}
   VStack(alignment:.leading,spacing:12){HStack{Text("FILE FORMATS").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.5);Spacer();Button("Select all"){m.formats=["svg","png","jpg","pdf","eps","ai"]};Button("Clear"){m.formats=[]}}
    LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible()),GridItem(.flexible())],spacing:12){
     ForEach(["svg","png","jpg","pdf","eps","ai"],id:\.self){f in formatCard(f)}
    }
    if m.intent=="cmyk" {Text("PNG and SVG are digital formats, so they’re excluded from print-only packages.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}
    if m.formats.contains("ai") {Text("AI exports are PDF-compatible files from VectorCraft. Full Illustrator-native editing data is not included.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}
   }
   VStack(alignment:.leading,spacing:12){Text("COLOUR VERSIONS").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.5);HStack(spacing:30){ForEach(["full-colour","black","white"],id:\.self){v in Toggle(v.replacingOccurrences(of:"-",with:" ").capitalized,isOn:m.toggle(\.variants,v))}};Text("Black and white versions recolour every filled shape. Check any white cutout shapes in the preview.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}.padding(18).frame(maxWidth:.infinity,alignment:.leading).craftPanel()
   DisclosureGroup("More options",isExpanded:$m.advanced){VStack(alignment:.leading,spacing:16){
    if m.rasterChosen {HStack{Text("Image widths").frame(width:120,alignment:.leading);ForEach([512,1024,2048,4096],id:\.self){n in Toggle("\(n) px",isOn:m.toggle(\.sizes,n))}}}
    HStack{Text("Clear space").frame(width:120,alignment:.leading);Picker("Padding",selection:$m.padding){Text("None").tag(0);Text("Small · 5%").tag(5);Text("Standard · 10%").tag(10);Text("Generous · 20%").tag(20)}.labelsHidden().frame(width:210);Text("On each side of the artwork").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}
    HStack(spacing:25){Toggle("Grayscale",isOn:m.toggle(\.variants,"grayscale"));Toggle("Inverted",isOn:m.toggle(\.variants,"inverted"));Toggle("Custom solid colour",isOn:m.toggle(\.variants,"custom"));if m.variants.contains("custom"){TextField("#7355DD",text:$m.custom).textFieldStyle(.roundedBorder).frame(width:110)}}
    Toggle("Outline text in SVG files",isOn:$m.outline)
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
   Text("\(m.included.count) of \(m.files.count) files selected · White artwork is shown on a dark preview background.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)
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
   VStack(alignment:.leading,spacing:12){Text("SAVE LOCATION").font(.system(size:11,weight:.semibold,design:.monospaced)).tracking(1.5);HStack{Image(systemName:"folder").foregroundColor(accent);Text(m.output.isEmpty ? "Choose where your package should go" : m.output).foregroundColor(m.output.isEmpty ? .secondary : ink).lineLimit(2).textSelection(.enabled);Spacer();Button(m.output.isEmpty ? "Choose folder…" : "Change…",action:m.chooseOutput)}}.padding(20).craftPanel()
   VStack(alignment:.leading,spacing:15){Label("\(m.included.count) reviewed logo files",systemImage:"checkmark.circle.fill");Label("Organised by artwork, RGB / CMYK and colour version",systemImage:"folder.badge.gearshape");Label("ZIP archive and a simple client guide included",systemImage:"shippingbox");Label("Existing packages are kept; new ones get a numbered name",systemImage:"doc.on.doc")}.font(.callout).foregroundColor(.secondary)
   if !m.validName || m.output.isEmpty {Text(m.validName ? "Choose a save folder to continue." : "Enter a package name to continue.").foregroundColor(.secondary).font(.callout)}
  }
 }
 var successPage:some View {
  VStack(alignment:.center,spacing:22){Image(systemName:"checkmark.seal.fill").font(.system(size:64)).foregroundColor(accent);Text("Your logo package is ready").font(.system(size:30,weight:.semibold));Text("\(m.delivered?.count ?? 0) logo files, organised and ready to hand over.").foregroundColor(.secondary)
   if let d=m.delivered {Text(d.folder).font(.system(size:11,design:.monospaced)).foregroundColor(.secondary).textSelection(.enabled);HStack{Button("Open package folder"){NSWorkspace.shared.open(URL(fileURLWithPath:d.folder))}.buttonStyle(CraftButton(primary:true));Button("Show ZIP in Finder"){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:d.zip)])}}};if !m.warnings.isEmpty {Text("Export notes are included in the package. Please review them before delivery.").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary)}
  }.frame(maxWidth:.infinity).padding(.vertical,80)
 }
 var footer:some View {
  HStack(spacing:15){if m.step>0 && m.step<4 {Button("Back"){m.step-=1}};Text(m.step==0 ? "Everything stays on your Mac." : m.step==1 ? "\(m.count) files · \(m.sizes.sorted().map{String($0)}.joined(separator:", ")) px · \(m.padding)% clear space" : m.step==2 ? "\(m.included.count) files selected" : "").font(.system(size:11,design:.monospaced)).foregroundColor(.secondary);Spacer()
   switch m.step {
   case 0:Button("Continue to options"){m.step=1}.buttonStyle(CraftButton(primary:true)).disabled(m.artwork["Full logo"]==nil)
   case 1:Button("Build visual preview",action:m.buildPreview).buttonStyle(CraftButton(primary:true)).disabled(!m.canPreview)
   case 2:Button("Continue to save"){m.step=3}.buttonStyle(CraftButton(primary:true)).disabled(m.included.isEmpty)
   case 3:Button("Export \(m.included.count) files",action:m.export).buttonStyle(CraftButton(primary:true)).disabled(!m.validName || m.output.isEmpty || m.included.isEmpty)
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
