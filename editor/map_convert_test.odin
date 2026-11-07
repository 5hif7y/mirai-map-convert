package map_convert_editor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import importer "mirai:cook/import"
import valve220 "../../valve220/editor"

@(private="file")
temp_folder :: proc(name:string) -> string {
    directory,_:=os.temp_directory(context.temp_allocator)
    path,_:=strings.replace_all(fmt.tprintf("%s/mirai-map-convert-%d-%s",directory,os.get_pid(),name),"\\","/",context.temp_allocator)
    os.remove_all(path)
    os.make_directory_all(path)
    return path
}

// The formats the editor imports with valve220 and this plugin, in the order
// of the plugins: valve220 first, as a dependency.
@(private="file")
formats_with_plugins :: proc() -> []importer.Format {
    out:=make([dynamic]importer.Format,context.temp_allocator)
    append(&out,valve220.valve220_format_default().provider.format)
    append(&out,map_convert_vmf_default().provider.format)
    append(&out,map_convert_doom3_default().provider.format)
    append(&out,map_convert_quake_default().provider.format)
    append(&out,map_convert_quake3_bsp_default().provider.format)
    append(&out,map_convert_source_bsp_default().provider.format)
    return out[:]
}

// The six sides of the cube [0,64] as a standard Quake brush: no texture axes.
QUAKE_CUBE :: `{
"classname" "worldspawn"
{
( 0 0 0 ) ( 0 64 0 ) ( 0 0 64 ) crate 0 0 0 1 1
( 64 0 0 ) ( 64 0 64 ) ( 64 64 0 ) crate 0 0 0 1 1
( 0 0 0 ) ( 0 0 64 ) ( 64 0 0 ) crate 0 0 0 1 1
( 0 64 0 ) ( 64 64 0 ) ( 0 64 64 ) crate 0 0 0 1 1
( 0 0 0 ) ( 64 0 0 ) ( 0 64 0 ) crate 0 0 0 1 1
( 0 0 64 ) ( 0 64 64 ) ( 64 0 64 ) crate 0 0 0 1 1
}
}
`

VALVE_CUBE :: `{
"classname" "worldspawn"
"mapversion" "220"
{
( 0 0 0 ) ( 0 64 0 ) ( 0 0 64 ) crate [ 0 1 0 0 ] [ 0 0 -1 0 ] 0 1 1
( 64 0 0 ) ( 64 0 64 ) ( 64 64 0 ) crate [ 0 1 0 0 ] [ 0 0 -1 0 ] 0 1 1
( 0 0 0 ) ( 0 0 64 ) ( 64 0 0 ) crate [ 1 0 0 0 ] [ 0 0 -1 0 ] 0 1 1
( 0 64 0 ) ( 64 64 0 ) ( 0 64 64 ) crate [ 1 0 0 0 ] [ 0 0 -1 0 ] 0 1 1
( 0 0 0 ) ( 64 0 0 ) ( 0 64 0 ) crate [ 1 0 0 0 ] [ 0 -1 0 0 ] 0 1 1
( 0 0 64 ) ( 0 64 64 ) ( 64 0 64 ) crate [ 1 0 0 0 ] [ 0 -1 0 0 ] 0 1 1
}
}
`

@(test)
each_map_goes_to_its_format_and_imports :: proc(t:^testing.T) {
    folder:=temp_folder("formats")
    defer os.remove_all(folder)
    formats:=formats_with_plugins()
    cases:=[?]struct{file,text,format:string}{
        {"quake.map",QUAKE_CUBE,"Quake map"},
        {"valve.map",VALVE_CUBE,"Valve map"},
    }
    for c in cases {
        found,known:=importer.format_find(formats,transmute([]u8)c.text,".map")
        if !testing.expectf(t,known && found.name==c.format,"%s: %v",c.file,found.name if known else "none") {continue}
        path:=fmt.tprintf("%s/%s",folder,c.file)
        testing.expect(t,os.write_entire_file(path,transmute([]u8)c.text)==nil)
        model,error:=importer.import_model(path,formats,{})
        if !testing.expectf(t,error.code==.None,"%s: %v %s",c.file,error.code,error.message) {continue}
        triangles:=0
        for mesh in model.meshes {triangles+=len(mesh.indices)/3}
        testing.expectf(t,triangles==12,"%s: %d triangles",c.file,triangles)
        importer.model_destroy(&model)
    }
    // a Doom 3 map and a Hammer .vmf are told by their first bytes, whatever the extension
    doom3,doom3_known:=importer.format_find(formats,transmute([]u8)string("Version 2\n// entity 0\n{\n"),".map")
    testing.expect(t,doom3_known && doom3.name=="Doom 3 map")
    vmf,vmf_known:=importer.format_find(formats,transmute([]u8)string("versioninfo\n{\n}\nworld\n{\n"),".txt")
    testing.expect(t,vmf_known && vmf.name=="Hammer map")
}
