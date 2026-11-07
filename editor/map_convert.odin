package map_convert_editor

import "core:os"
import "core:path/filepath"
import "core:strings"
import importer "mirai:cook/import"
import "mirai:editor"
import "mirai:editor/api"
import "mirai:project"
import "mirai:std/base"
import "mirai:std/serial"
import formats "./formats"
import valvemap "../../valve220/editor/loader"
import mapfile "../../valve220/editor/mapfile"

// Maps of other engines in the import of the editor: each format converts its
// file to Valve 220 in memory and the loader of valve220 reads that, so a map
// imports with its brushes and texture axes without a file in between. The
// formats tell their files by their content (formats.kind_of): a .map in the
// standard format of Quake or of Doom 3 is not one of Valve 220.
//
// The API converts a map to a Valve 220 .map in the project, to edit it in
// TrenchBroom, and unpacks the textures of a WAD to PNG.

@(private)
format_of :: proc(name:string,extension:string,sniff:proc(head:[]u8) -> importer.Sniff,read:proc(c:^importer.Reader,bytes:[]u8) -> bool) -> importer.Format {
    return {name=name,extensions={0=extension},version=0,space=valvemap.FORMAT.space,sniff=sniff,read=read}
}

// Converts with formats.convert and reads the Valve 220 it gives.
@(private)
read_converted :: proc(c:^importer.Reader,bytes:[]u8) -> bool {
    r,ok:=formats.convert(bytes,{},context.temp_allocator)
    if !ok {return importer.fail(c,.Malformed,"%s",r.message)}
    for warning in r.m.warnings {importer.warn(c,"%s",warning)}
    return valvemap.read_text(c,mapfile.map_write(&r.m,context.temp_allocator))
}

@(private)
sniff_kind :: proc(head:[]u8,kind:formats.Kind) -> importer.Sniff {
    return .Content if formats.kind_of(head)==kind else .No
}

@(private) sniff_vmf :: proc(head:[]u8) -> importer.Sniff {return sniff_kind(head,.Vmf)}
@(private) sniff_doom3 :: proc(head:[]u8) -> importer.Sniff {return sniff_kind(head,.Doom3_Map)}
@(private) sniff_quake :: proc(head:[]u8) -> importer.Sniff {return sniff_kind(head,.Quake_Map)}
@(private) sniff_q3bsp :: proc(head:[]u8) -> importer.Sniff {return sniff_kind(head,.Quake3_Bsp)}
@(private) sniff_vbsp :: proc(head:[]u8) -> importer.Sniff {return sniff_kind(head,.Source_Bsp)}

@(storage)
Map_Convert_Vmf :: struct {provider:editor.Import_Format_Provider}
map_convert_vmf_default :: proc() -> Map_Convert_Vmf {return {provider={format=format_of("Hammer map",".vmf",sniff_vmf,read_converted)}}}

@(storage)
Map_Convert_Doom3 :: struct {provider:editor.Import_Format_Provider}
map_convert_doom3_default :: proc() -> Map_Convert_Doom3 {return {provider={format=format_of("Doom 3 map",".map",sniff_doom3,read_converted)}}}

@(storage)
Map_Convert_Quake :: struct {provider:editor.Import_Format_Provider}
map_convert_quake_default :: proc() -> Map_Convert_Quake {return {provider={format=format_of("Quake map",".map",sniff_quake,read_converted)}}}

@(storage)
Map_Convert_Quake3_Bsp :: struct {provider:editor.Import_Format_Provider}
map_convert_quake3_bsp_default :: proc() -> Map_Convert_Quake3_Bsp {return {provider={format=format_of("Quake III BSP",".bsp",sniff_q3bsp,read_converted)}}}

@(storage)
Map_Convert_Source_Bsp :: struct {provider:editor.Import_Format_Provider}
map_convert_source_bsp_default :: proc() -> Map_Convert_Source_Bsp {return {provider={format=format_of("Source BSP",".bsp",sniff_vbsp,read_converted)}}}

// ---------------------------------------------------------------- the API

@(storage)
Map_Convert_Api :: struct {provider:editor.Api_Provider}

MAP_CONVERT_API_DEFAULT :: Map_Convert_Api{provider={register=map_convert_api_register}}

To_Valve220_Params :: struct {
    path:[editor.API_PATH_BYTES]u8 `mirai:"text,label=A map to convert, anywhere on disk: .vmf of Hammer, .map of Doom 3 or of Quake, .bsp of Quake III or Source; nothing is written into it"`,
    out:[editor.API_PATH_BYTES]u8 `mirai:"text,label=The Valve 220 .map to write, relative to the project"`,
}

To_Valve220_Result :: struct {
    kind:[64]u8 `mirai:"text,label=What the input was"`,
    entities:int `mirai:"label=Entities written"`,
    brushes:int `mirai:"label=Brushes written"`,
    warnings:int `mirai:"label=What Valve 220 cannot hold and was left out (curved patches, displacements, models)"`,
}

Unpack_Wad_Params :: struct {
    path:[editor.API_PATH_BYTES]u8 `mirai:"text,label=A WAD2 (Quake) or WAD3 (GoldSrc), anywhere on disk"`,
    out:[editor.API_PATH_BYTES]u8 `mirai:"text,label=The folder to write <name>.png into, relative to the project: textures/ beside a map is where valve220 looks"`,
    palette:[editor.API_PATH_BYTES]u8 `mirai:"text,optional,label=gfx/palette.lmp: the WAD2 of Quake keeps no palette"`,
}

Unpack_Wad_Result :: struct {
    written:int `mirai:"label=Textures written as PNG"`,
    skipped:int `mirai:"label=Textures left out: a name that cannot be a file, or no palette"`,
}

@(private)
map_convert_api_register :: proc(s:^editor.Session) {
    editor.api_method_register(s,{name="map_convert.to_valve220",summary="Converts a map of another engine (Hammer .vmf, Doom 3 or Quake .map, Quake III or Source .bsp) to a Valve 220 .map in the project, which TrenchBroom edits and valve220 imports.",params=To_Valve220_Params,params_info=type_info_of(To_Valve220_Params),result=To_Valve220_Result,result_info=type_info_of(To_Valve220_Result),run=api_to_valve220})
    editor.api_method_register(s,{name="map_convert.unpack_wad",summary="Writes the textures of a WAD2 or WAD3 as PNG files in a folder of the project, where valve220 finds the textures of a map.",params=Unpack_Wad_Params,params_info=type_info_of(Unpack_Wad_Params),result=Unpack_Wad_Result,result_info=type_info_of(Unpack_Wad_Result),run=api_unpack_wad})
}

// A path the API writes: relative to the project and inside it.
project_file :: proc(s:^editor.Session,call:^api.Call,given,field:string) -> (path:string,ok:bool) {
    if !s.has_project {api.call_fail(call,api.SERVER_ERROR,"There is no project to write into");return}
    if given=="" || filepath.is_abs(given) || strings.contains(given,"..") {
        api.call_failf(call,api.INVALID_PARAMS,"%s %q is not a path relative to the project",field,given)
        return
    }
    return project.path(s.project_root,given,allocator=context.temp_allocator),true
}

@(private)
api_to_valve220 :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,To_Valve220_Params)
    source:=base.text_get(p.path[:])
    out,ok:=project_file(s,call,base.text_get(p.out[:]),"out")
    if !ok {return}
    bytes,error:=serial.file_read(source,context.temp_allocator)
    if error!=.None {api.call_failf(call,api.INVALID_PARAMS,"path %q could not be read",source);return}
    r,converted:=formats.convert(bytes,{},context.temp_allocator)
    if !converted {api.call_failf(call,api.INVALID_PARAMS,"%s: %s",source,r.message);return}
    os.make_directory_all(filepath.dir(out))
    if os.write_entire_file(out,transmute([]u8)mapfile.map_write(&r.m,context.temp_allocator))!=nil {api.call_failf(call,api.SERVER_ERROR,"%s could not be written",out);return}
    result:=api.call_result(call,To_Valve220_Result)
    base.text_set(result.kind[:],r.kind)
    result.entities=len(r.m.entities)
    for e in r.m.entities {result.brushes+=len(e.brushes)}
    result.warnings=len(r.m.warnings)
}

@(private)
api_unpack_wad :: proc(s:^editor.Session,call:^api.Call) {
    p:=api.call_params(call,Unpack_Wad_Params)
    source:=base.text_get(p.path[:])
    folder,ok:=project_file(s,call,base.text_get(p.out[:]),"out")
    if !ok {return}
    bytes,error:=serial.file_read(source,context.temp_allocator)
    if error!=.None {api.call_failf(call,api.INVALID_PARAMS,"path %q could not be read",source);return}
    textures,_,read:=formats.wad_read(bytes,context.temp_allocator)
    if !read {api.call_failf(call,api.INVALID_PARAMS,"%s is not a WAD2 or WAD3",source);return}
    palette:[]u8
    if given:=base.text_get(p.palette[:]);given!="" {
        data,palette_error:=serial.file_read(given,context.temp_allocator)
        if palette_error!=.None || len(data)<formats.PALETTE_BYTES {api.call_failf(call,api.INVALID_PARAMS,"palette %q is not a palette of 768 bytes",given);return}
        palette=data[:formats.PALETTE_BYTES]
    }
    written,skipped,made:=formats.textures_write(textures,folder,palette)
    if !made {api.call_failf(call,api.SERVER_ERROR,"%s could not be made",folder);return}
    result:=api.call_result(call,Unpack_Wad_Result)
    result.written,result.skipped=written,len(skipped)
}

