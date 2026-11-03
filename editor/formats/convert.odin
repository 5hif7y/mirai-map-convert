package map_convert_formats

import "core:strings"
import mapfile "project:plugins/valve220/editor/mapfile"

// Picks the converter by the first bytes of the file. The BSPs of Quake and
// GoldSrc are not here: they are decompiled, in the plugin bsp_decompile.

Convert_Result :: struct {
    m:mapfile.Map,
    kind:string,    // what the input was
    message:string, // why it failed; the warnings are in m.warnings
}

// Nothing to choose yet: the place for the options of a conversion.
Convert_Options :: struct {}

Kind :: enum u8 {None,Quake3_Bsp,Source_Bsp,Vmf,Doom3_Map,Quake_Map}

// What a file is, by its first bytes: the formats of the plugin tell their
// files with it.
kind_of :: proc(head:[]u8) -> Kind {
    magic:=string(head[:min(len(head),4)])
    switch magic {
    case "IBSP","RBSP": return .Quake3_Bsp
    case "VBSP":        return .Source_Bsp
    }
    trimmed:=strings.trim_left_space(string(head))
    // comments before the first entity
    for strings.has_prefix(trimmed,"//") {
        end:=strings.index_byte(trimmed,'\n')
        if end<0 {return .None}
        trimmed=strings.trim_left_space(trimmed[end+1:])
    }
    switch {
    case strings.has_prefix(trimmed,"versioninfo") || strings.has_prefix(trimmed,"visgroups") || strings.has_prefix(trimmed,"world"):
        return .Vmf
    case strings.has_prefix(trimmed,"Version"):
        return .Doom3_Map
    case strings.has_prefix(trimmed,"{") && quake_standard(string(head)):
        return .Quake_Map
    }
    return .None
}

// A .map in the standard format of Quake: a face line, "( x y z ) ( ... ) ( ... ) texture ...",
// without the [ u ] [ v ] axes of Valve 220. A head that holds no face line yet says nothing.
@(private)
quake_standard :: proc(head:string) -> bool {
    rest:=head
    for line in strings.split_lines_iterator(&rest) {
        trimmed:=strings.trim_space(line)
        if !strings.has_prefix(trimmed,"(") {continue}
        return !strings.contains(trimmed,"[")
    }
    return false
}

convert :: proc(bytes:[]u8,options:Convert_Options,allocator:=context.allocator) -> (r:Convert_Result,ok:bool) {
    context.allocator=allocator
    text:=string(bytes)
    switch kind_of(bytes[:min(len(bytes),4096)]) {
    case .Quake3_Bsp:
        r.kind="Quake III BSP"
        r.message,ok=convert_q3bsp(bytes,&r.m)
    case .Source_Bsp:
        r.kind="Source BSP"
        r.message,ok=convert_vbsp(bytes,&r.m)
    case .Vmf:
        r.kind="Hammer .vmf"
        r.message,ok=convert_vmf(text,&r.m)
    case .Doom3_Map:
        r.kind="Doom 3 .map"
        r.message,ok=convert_doom3(text,&r.m)
    case .Quake_Map:
        r.kind="Quake .map"
        r.message,ok=convert_quake_map(text,&r.m)
    case .None:
        r.message="not a format map_convert reads"
    }
    return
}
