package map_convert_formats

import "core:encoding/endian"
import "core:fmt"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:testing"
import importer "mirai:cook/import"
import mapfile "project:plugins/valve220/editor/mapfile"
import valvemap "project:plugins/valve220/editor/loader"

// Each test makes the same cube, [0,64] in map units, in one format, converts
// it and imports the .map with the loader: 12 triangles between 0 and 2 m.

@(private="file")
Bytes :: struct {b:[dynamic]u8}


@(private="file")
put_i32 :: proc(w:^Bytes,v:int) {x:[4]u8;endian.put_i32(x[:],.Little,i32(v));append(&w.b,..x[:])}

@(private="file")
put_u16 :: proc(w:^Bytes,v:int) {x:[2]u8;endian.put_u16(x[:],.Little,u16(v));append(&w.b,..x[:])}

@(private="file")
put_i16 :: proc(w:^Bytes,v:int) {x:[2]u8;endian.put_i16(x[:],.Little,i16(v));append(&w.b,..x[:])}

@(private="file")
put_f32 :: proc(w:^Bytes,v:f64) {x:[4]u8;endian.put_f32(x[:],.Little,f32(v));append(&w.b,..x[:])}

@(private="file")
put_name :: proc(w:^Bytes,name:string,size:int) {
    x:=make([]u8,size,context.temp_allocator)
    copy(x,name)
    append(&w.b,..x)
}


// The six outward planes of the cube: +x -x +y -y +z -z.
@(private="file")
CUBE_PLANES :: [6]mapfile.Plane{{{1,0,0},64},{{-1,0,0},0},{{0,1,0},64},{{0,-1,0},0},{{0,0,1},64},{{0,0,-1},0}}


@(private="file")
import_converted :: proc(t:^testing.T,m:^mapfile.Map,name:string) -> (triangles:int,lo,hi:[3]f32,materials:[]string) {
    directory,_:=os.temp_directory(context.temp_allocator)
    folder:=fmt.tprintf("%s/mirai-mapconvert-%d-%s",directory,os.get_pid(),name)
    os.remove_all(folder)
    os.make_directory_all(folder)
    defer os.remove_all(folder)
    path:=fmt.tprintf("%s/%s.map",folder,name)
    text:=mapfile.map_write(m,context.temp_allocator)
    _=os.write_entire_file(path,transmute([]u8)text)
    formats:=[?]importer.Format{valvemap.FORMAT}
    model,error:=importer.import_model(path,formats[:],{})
    if !testing.expectf(t,error.code==.None,"%s: %v %s\n%s",name,error.code,error.message,text) {return}
    defer importer.model_destroy(&model)
    lo,hi={1e9,1e9,1e9},{-1e9,-1e9,-1e9}
    for mesh in model.meshes {
        triangles+=len(mesh.indices)/3
        lo=linalg.min(lo,mesh.bounds_min)
        hi=linalg.max(hi,mesh.bounds_max)
    }
    names:=make([dynamic]string,context.temp_allocator)
    for mat in model.materials {append(&names,strings.clone(mat.name,context.temp_allocator))}
    return triangles,lo,hi,names[:]
}


@(private="file")
expect_cube :: proc(t:^testing.T,m:^mapfile.Map,name:string,loc:=#caller_location) {
    triangles,lo,hi,_:=import_converted(t,m,name)
    testing.expectf(t,triangles==12,"%s: %d triangles",name,triangles,loc=loc)
    // 32 map units to the meter, Z up turned to Y up, +Y map is -Z.
    testing.expectf(t,linalg.length(lo-[3]f32{0,0,-2})<1e-4 && linalg.length(hi-[3]f32{2,2,0})<1e-4,
        "%s: bounds %v %v",name,lo,hi,loc=loc)
}


@(test)
a_vmf_keeps_its_solids_and_axes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"versioninfo\n{\n\"editorversion\" \"400\"\n}\nworld\n{\n\"id\" \"1\"\n\"classname\" \"worldspawn\"\n\"skyname\" \"sky_day01\"\nsolid\n{\n")
    for p in CUBE_PLANES {
        points:=mapfile.side_points(mapfile.Side{plane=p})
        fmt.sbprintf(&b,"side\n{{\n\"plane\" \"(%v %v %v) (%v %v %v) (%v %v %v)\"\n\"material\" \"DEV/DEV_MEASUREWALL01A\"\n\"uaxis\" \"[1 0 0 16] 0.25\"\n\"vaxis\" \"[0 -1 0 0] 0.25\"\n}}\n",
            points[0].x,points[0].y,points[0].z,points[1].x,points[1].y,points[1].z,points[2].x,points[2].y,points[2].z)
    }
    strings.write_string(&b,"}\n}\nentity\n{\n\"id\" \"9\"\n\"classname\" \"info_player_start\"\n\"origin\" \"32 32 1\"\n}\n")
    r,ok:=convert(transmute([]u8)strings.to_string(b),{},context.temp_allocator)
    if !testing.expectf(t,ok,"%s",r.message) {return}
    testing.expect_value(t,r.kind,"Hammer .vmf")
    testing.expect_value(t,len(r.m.entities),2)
    side:=r.m.entities[0].brushes[0].sides[0]
    testing.expect(t,side.scale==[2]f64{0.25,0.25} && side.shift==[2]f64{16,0})
    testing.expect_value(t,side.texture,"DEV/DEV_MEASUREWALL01A")
    expect_cube(t,&r.m,"vmf")
}


@(test)
a_doom3_map_turns_its_planes_and_texture_matrix :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"Version 2\n// entity 0\n{\n\"classname\" \"worldspawn\"\n// primitive 0\n{\n brushDef3\n {\n")
    for p in CUBE_PLANES {
        // a x + b y + c z + d = 0, d = -dist
        fmt.sbprintf(&b,"  ( %v %v %v %v ) ( ( 0.0078125 0 0 ) ( 0 0.0078125 0 ) ) \"textures/base_wall/lfwall13f3\" 0 0 0\n",
            p.normal.x,p.normal.y,p.normal.z,-p.dist)
    }
    strings.write_string(&b," }\n}\n{\n patchDef2\n {\n  \"textures/x\"\n  ( 3 3 0 0 0 )\n (\n ( ( 0 0 0 0 0 ) )\n )\n }\n}\n}\n")
    r,ok:=convert(transmute([]u8)strings.to_string(b),{},context.temp_allocator)
    if !testing.expectf(t,ok,"%s",r.message) {return}
    testing.expect_value(t,r.kind,"Doom 3 .map")
    if !testing.expect_value(t,len(r.m.entities[0].brushes),1) {return}
    // 1/128 of a texture per unit, on a texture of 128 texels: one texel per unit
    for side in r.m.entities[0].brushes[0].sides {
        testing.expectf(t,abs(side.scale.x-1)<1e-6 && abs(side.scale.y-1)<1e-6,"scale %v",side.scale)
    }
    patch:=false
    for w in r.m.warnings {if strings.contains(w,"patches") {patch=true}}
    testing.expectf(t,patch,"the patch is reported: %v",r.m.warnings)
    expect_cube(t,&r.m,"doom3")
}


@(test)
a_quake_map_in_the_standard_format_gets_valve_axes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    b:=strings.builder_make(context.temp_allocator)
    strings.write_string(&b,"{\n\"classname\" \"worldspawn\"\n{\n")
    for p in CUBE_PLANES {
        q:=mapfile.side_points(mapfile.Side{plane=p})
        fmt.sbprintf(&b,"( %v %v %v ) ( %v %v %v ) ( %v %v %v ) {{fence 16 8 0 2 2\n",q[0].x,q[0].y,q[0].z,q[1].x,q[1].y,q[1].z,q[2].x,q[2].y,q[2].z)
    }
    strings.write_string(&b,"}\n}\n")
    r,ok:=convert(transmute([]u8)strings.to_string(b),{},context.temp_allocator)
    if !testing.expectf(t,ok,"%s",r.message) {return}
    floor:mapfile.Side
    for side in r.m.entities[0].brushes[0].sides {if side.plane.normal.z>0.5 {floor=side}}
    testing.expect_value(t,floor.texture,"{fence")
    testing.expect(t,floor.u==[3]f64{1,0,0} && floor.v==[3]f64{0,-1,0},"floor axes")
    testing.expect(t,floor.scale==[2]f64{2,2} && floor.shift==[2]f64{16,8},"scale and shift")
    expect_cube(t,&r.m,"quake")
}


// A BSP of Quake III with the cube as one brush of model 0, plus a bevel side
// that touches only a corner and must go.
@(test)
a_quake3_bsp_gives_back_its_brushes :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    lumps:[17]Bytes
    entities:="{\n\"classname\" \"worldspawn\"\n}\n\x00"
    append(&lumps[0].b,..transmute([]u8)entities)
    put_name(&lumps[1],"textures/base_wall/concrete",64);put_i32(&lumps[1],0);put_i32(&lumps[1],1)
    planes:=CUBE_PLANES
    for p in planes {put_f32(&lumps[2],p.normal.x);put_f32(&lumps[2],p.normal.y);put_f32(&lumps[2],p.normal.z);put_f32(&lumps[2],p.dist)}
    // a bevel through the corner (64,64,64), facing out
    bevel,_:=mapfile.normalize({1,1,1})
    put_f32(&lumps[2],bevel.x);put_f32(&lumps[2],bevel.y);put_f32(&lumps[2],bevel.z);put_f32(&lumps[2],mapfile.dot(bevel,{64,64,64}))
    for v in ([6]f64{0,0,0,64,64,64}) {put_f32(&lumps[7],v)}
    put_i32(&lumps[7],0);put_i32(&lumps[7],0);put_i32(&lumps[7],0);put_i32(&lumps[7],1)
    put_i32(&lumps[8],0);put_i32(&lumps[8],7);put_i32(&lumps[8],0)
    for i in 0..<7 {put_i32(&lumps[9],i);put_i32(&lumps[9],0)}
    out:Bytes
    append(&out.b,..transmute([]u8)string("IBSP"))
    put_i32(&out,46)
    at:=8+17*8
    for l in lumps {put_i32(&out,at);put_i32(&out,len(l.b));at+=len(l.b)}
    for l in lumps {append(&out.b,..l.b[:])}
    r,ok:=convert(out.b[:],{},context.temp_allocator)
    if !testing.expectf(t,ok,"%s",r.message) {return}
    testing.expect_value(t,r.kind,"Quake III BSP")
    if !testing.expect_value(t,len(r.m.entities[0].brushes),1) {return}
    testing.expect_value(t,len(r.m.entities[0].brushes[0].sides),6)
    testing.expect_value(t,r.m.entities[0].brushes[0].sides[0].texture,"textures/base_wall/concrete")
    expect_cube(t,&r.m,"q3")
}


// A BSP of Source: model 0 is a tree of one node whose back leaf lists the
// brush; the texture comes from texinfo, texdata and the string table.
@(test)
a_source_bsp_gives_back_its_brushes_with_their_texture :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    lumps:[64]Bytes
    entities:="{\n\"classname\" \"worldspawn\"\n}\n\x00"
    append(&lumps[0].b,..transmute([]u8)entities)
    planes:=CUBE_PLANES
    for p in planes {put_f32(&lumps[1],p.normal.x);put_f32(&lumps[1],p.normal.y);put_f32(&lumps[1],p.normal.z);put_f32(&lumps[1],p.dist);put_i32(&lumps[1],0)}
    // texdata 0: reflectivity, name 0, 512×512
    for _ in 0..<3 {put_f32(&lumps[2],0.5)}
    put_i32(&lumps[2],0);put_i32(&lumps[2],512);put_i32(&lumps[2],512);put_i32(&lumps[2],512);put_i32(&lumps[2],512)
    // node 0 on plane 0: front leaf 0 (empty), back leaf 1 (the brush)
    put_i32(&lumps[5],0);put_i32(&lumps[5],-1);put_i32(&lumps[5],-2)
    for _ in 0..<10 {put_i16(&lumps[5],0)}
    // texinfo 0: 1/4 texel... 4 texels per unit along x and -y
    for v in ([8]f64{0.25,0,0,0, 0,-0.25,0,0}) {put_f32(&lumps[6],v)}
    for _ in 0..<8 {put_f32(&lumps[6],0)}
    put_i32(&lumps[6],0);put_i32(&lumps[6],0)
    // leaves (version 1, 32 bytes): 0 without brushes, 1 with brush 0
    for leaf in 0..<2 {
        put_i32(&lumps[10],0);put_i16(&lumps[10],0);put_i16(&lumps[10],0)
        for _ in 0..<6 {put_i16(&lumps[10],0)}
        put_u16(&lumps[10],0);put_u16(&lumps[10],0)
        put_u16(&lumps[10],0);put_u16(&lumps[10],leaf)
        put_i16(&lumps[10],-1);put_i16(&lumps[10],0)
    }
    put_u16(&lumps[17],0)
    for v in ([9]f64{0,0,0,64,64,64,0,0,0}) {put_f32(&lumps[14],v)}
    put_i32(&lumps[14],0);put_i32(&lumps[14],0);put_i32(&lumps[14],0)
    put_i32(&lumps[18],0);put_i32(&lumps[18],6);put_i32(&lumps[18],1)
    for i in 0..<6 {put_u16(&lumps[19],i);put_i16(&lumps[19],0);put_i16(&lumps[19],-1);put_i16(&lumps[19],0)}
    name:="BRICK/BRICKFLOOR001A\x00"
    append(&lumps[43].b,..transmute([]u8)name)
    put_i32(&lumps[44],0)
    out:Bytes
    append(&out.b,..transmute([]u8)string("VBSP"))
    put_i32(&out,20)
    at:=8+64*16+4
    for l,i in lumps {put_i32(&out,at);put_i32(&out,len(l.b));put_i32(&out,1 if i==10 else 0);put_i32(&out,0);at+=len(l.b)}
    put_i32(&out,1)
    for l in lumps {append(&out.b,..l.b[:])}
    r,ok:=convert(out.b[:],{},context.temp_allocator)
    if !testing.expectf(t,ok,"%s",r.message) {return}
    testing.expect_value(t,r.kind,"Source BSP")
    if !testing.expect_value(t,len(r.m.entities[0].brushes),1) {return}
    side:=r.m.entities[0].brushes[0].sides[0]
    testing.expect_value(t,side.texture,"BRICK/BRICKFLOOR001A")
    testing.expect(t,abs(side.scale.x-4)<1e-6 && side.u==[3]f64{1,0,0},"axes from texinfo")
    expect_cube(t,&r.m,"source")
}

