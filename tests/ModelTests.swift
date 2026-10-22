import Cocoa
@main struct Checks {
 static func main() throws {
  func version(_ s:String)->ReleaseVersion {ReleaseVersion(s)!}
  assert(version("0.6.0-beta.2")>version("v0.6.0-beta.1"))
  assert(version("0.6.0-beta.10")>version("0.6.0-beta.2"))
  assert(version("0.6.0")>version("0.6.0-beta.10"))
  assert(version("0.7.0-beta.1")>version("0.6.0"))
  assert(version("0.6.0+metadata")==version("0.6.0"))
  assert(ReleaseVersion("latest")==nil);assert(ReleaseVersion("")==nil);assert(ReleaseVersion("0.6.0-")==nil)
  let m=Model();m.applyPreset("Digital only");assert(m.intent=="rgb" && m.formats.contains("svg"))
  m.applyPreset("Print supplier");assert(m.intent=="cmyk" && !m.effectiveFormats.contains("svg"))
  let a=Artwork(source:"/example.svg",index:0,thumbnail:"/preview.png",boardName:"Original")
  m.artwork["Full logo"]=a;m.overrides["Full logo"]=["white":a];m.pendingSelection=["stale"]
  m.editRole("Full logo");m.roleDraft="Horizontal";m.saveRole()
  assert(m.artwork["Horizontal"] != nil && m.overrides["Horizontal"]?["white"] != nil && m.overrides["Full logo"]==nil && m.pendingSelection==nil)
  let settings=m.settings;let roundtrip=try JSONDecoder().decode(ExportSettings.self,from:JSONEncoder().encode(settings));assert(roundtrip.formats==settings.formats)
  m.apply(ExportSettings(formats:["exe","png"],intent:"bad",variants:["inverted","white"],sizes:[-1,512],padding:200,custom:"#000000",outline:true))
  assert(m.formats==["png"] && m.intent=="both" && m.variants==["white"] && m.sizes==[512] && m.padding==100)
  m.startAgain();assert(m.overrides.isEmpty && m.artwork.isEmpty)
  if let resources=ProcessInfo.processInfo.environment["LOGO_PARCEL_RESOURCES"] {
   let drop=Model(resources:URL(fileURLWithPath:resources))
   let svg="<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"100\"><rect width=\"100\" height=\"100\" fill=\"#123456\"/></svg>"
   let a=drop.cache.appendingPathComponent("First.svg");let b=drop.cache.appendingPathComponent("Second.svg")
   try svg.write(to:a,atomically:true,encoding:.utf8);try svg.write(to:b,atomically:true,encoding:.utf8)
   assert(drop.acceptDrop([NSItemProvider(contentsOf:a)!,NSItemProvider(contentsOf:b)!]))
   let limit=Date().addingTimeInterval(30)
   while drop.artwork.count<2 && drop.error==nil && Date()<limit {RunLoop.current.run(until:Date().addingTimeInterval(0.05))}
   assert(drop.error==nil,drop.error ?? "");assert(drop.artwork.count==2);assert(drop.artwork[drop.primaryRole] != nil);assert(drop.extraRoles==["Second"])
   print("Multi-file drag providers imported into the required card and a new variation.")
  }
  print("Version comparison, preset validation, override renaming and reset checks passed.")
 }
}
