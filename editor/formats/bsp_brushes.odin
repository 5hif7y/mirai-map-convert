package map_convert_formats

import "core:fmt"
import "core:strconv"
import "core:strings"
import mapfile "../../../valve220/editor/mapfile"

// Compiled maps that keep their brushes: the BSP of Quake III (IBSP 46, and 47
// of Quake Live and Enemy Territory) and of Source (VBSP 19 to 21). Their
// brushes come back as they were, without rebuilding them from the tree:
// what the compiler added for collisions (bevel sides) is dropped, and what
// is not a brush (curved patches, displacements, models) is counted and left
// out.

@(private)
lump_of :: proc(b:[]u8,directory_at,i,entry_size:int) -> (lump:[]u8,ok:bool) {
    at:=directory_at+i*entry_size
    if at+8>len(b) {return}
    offset,length:=int(rd_i32(b,at)),int(rd_i32(b,at+4))
    if offset<0 || length<0 || offset+length>len(b) {return}
    return b[offset:offset+length],true
}

// The planes of sides whose polygon has an area: bevels and repeated planes
// leave none and are dropped.
@(private)
brush_keep_faces :: proc(brush:^mapfile.Brush) {
    scratch,scratch2:[dynamic][3]f64
    scratch.allocator,scratch2.allocator=context.temp_allocator,context.temp_allocator
    out:=0
    for i in 0..<len(brush.sides) {
        mapfile.winding_from_plane(brush.sides[i].plane,&scratch)
        alive:=true
        for j in 0..<len(brush.sides) {
            if i==j {continue}
            if !mapfile.winding_clip_back(scratch[:],brush.sides[j].plane,&scratch2,0.01) {alive=false;break}
            scratch,scratch2=scratch2,scratch
        }
        if alive && mapfile.winding_area(scratch[:])<0.01 {alive=false}
        if alive {brush.sides[out]=brush.sides[i];out+=1}
    }
    resize(&brush.sides,out)
}

// The brush model *N an entity names, and its origin when it has one.
@(private)
entity_model :: proc(e:^mapfile.Entity) -> (model:int,origin:[3]f64) {
    model=-1
    out:=0
    for kv in e.keys {
        if kv[0]=="model" && strings.has_prefix(kv[1],"*") {
            if n,ok:=strconv.parse_int(kv[1][1:]);ok {model=n;continue}
        }
        e.keys[out]=kv
        out+=1
    }
    resize(&e.keys,out)
    if value,has:=mapfile.entity_get(e,"origin");has && model>0 {
        v:[3]f64
        if mapfile.text_numbers(value,v[:]) {origin=v}
    }
    return
}

@(private)
brush_move :: proc(brush:^mapfile.Brush,offset:[3]f64) {
    for &side in brush.sides {
        side.plane.dist+=mapfile.dot(side.plane.normal,offset)
        side.shift.x-=mapfile.dot(offset,side.u)/side.scale.x
        side.shift.y-=mapfile.dot(offset,side.v)/side.scale.y
    }
}

// ---- Quake III ----------------------------------------------------------

convert_q3bsp :: proc(b:[]u8,m:^mapfile.Map) -> (message:string,ok:bool) {
    if len(b)<8+17*8 {return "too short for a BSP of Quake III",false}
    raven:=string(b[:4])=="RBSP" // Jedi Outcast and Soldier of Fortune 2: sides of 12 bytes
    lumps:[17][]u8
    for i in 0..<17 {
        lump,read:=lump_of(b,8,i,8)
        if !read {return "a lump lies outside the file",false}
        lumps[i]=lump
    }
    entities:=lumps[0]
    for len(entities)>0 && entities[len(entities)-1]==0 {entities=entities[:len(entities)-1]}
    if !mapfile.entities_parse(string(entities),m) || len(m.entities)==0 {return "the entity lump could not be read",false}
    shaders:=lumps[1]
    shader_name :: proc(shaders:[]u8,i:int) -> string {
        if i<0 || (i+1)*72>len(shaders) {return ""}
        name:=shaders[i*72:i*72+64]
        end:=0
        for end<64 && name[end]!=0 {end+=1}
        return string(name[:end])
    }
    planes,models,brushes,sides,surfaces:=lumps[2],lumps[7],lumps[8],lumps[9],lumps[13]
    side_size:=12 if raven else 8
    patches:=0
    for i in 0..<len(surfaces)/104 {if rd_i32(surfaces,i*104+8)==2 {patches+=1}}
    model_count:=len(models)/40
    for &e,ei in m.entities {
        model:=0 if ei==0 else -1
        origin:[3]f64
        if ei>0 {model,origin=entity_model(&e)}
        if model<0 {continue}
        if model>=model_count {mapfile.map_warn(m,"entity %d names model *%d, which the BSP does not have",ei,model);continue}
        first,count:=int(rd_i32(models,model*40+32)),int(rd_i32(models,model*40+36))
        for bi in first..<first+count {
            if bi<0 || (bi+1)*12>len(brushes) {break}
            first_side,side_count:=int(rd_i32(brushes,bi*12)),int(rd_i32(brushes,bi*12+4))
            brush:mapfile.Brush
            for si in first_side..<first_side+side_count {
                if si<0 || (si+1)*side_size>len(sides) {break}
                plane_index,shader:=int(rd_i32(sides,si*side_size)),int(rd_i32(sides,si*side_size+4))
                if plane_index<0 || (plane_index+1)*16>len(planes) {continue}
                at:=plane_index*16
                side:=mapfile.Side{plane={{rd_f32(planes,at),rd_f32(planes,at+4),rd_f32(planes,at+8)},rd_f32(planes,at+12)}}
                side.texture=shader_name(shaders,shader)
                // The BSP keeps no texture axes for a brush side: the ones TrenchBroom gives a new face.
                side.u,side.v=mapfile.default_axes(side.plane.normal)
                side.scale={0.5,0.5}
                append(&brush.sides,side)
            }
            brush_keep_faces(&brush)
            if len(brush.sides)<4 {continue}
            if origin!={} {brush_move(&brush,origin)}
            append(&e.brushes,brush)
        }
    }
    if patches>0 {mapfile.map_warn(m,"%d patches (curved surfaces) were left out",patches)}
    mapfile.map_warn(m,"a BSP of Quake III keeps no texture alignment for brushes: the sides have the default one")
    return "",true
}

// ---- Source -------------------------------------------------------------

convert_vbsp :: proc(b:[]u8,m:^mapfile.Map) -> (message:string,ok:bool) {
    if len(b)<8+64*16+4 {return "too short for a BSP of Source",false}
    lumps:[64][]u8
    lump_versions:[64]i32
    for i in 0..<64 {
        at:=8+i*16
        offset,length:=int(rd_i32(b,at)),int(rd_i32(b,at+4))
        if offset<0 || length<0 || offset+length>len(b) {return "a lump lies outside the file",false}
        lumps[i]=b[offset:offset+length]
        lump_versions[i]=rd_i32(b,at+8)
        if length>=4 && string(lumps[i][:4])=="LZMA" {
            return fmt.aprintf("lump %d is compressed with LZMA, which mapconvert does not read yet",i),false
        }
    }
    entities:=lumps[0]
    for len(entities)>0 && entities[len(entities)-1]==0 {entities=entities[:len(entities)-1]}
    if !mapfile.entities_parse(string(entities),m) || len(m.entities)==0 {return "the entity lump could not be read",false}
    planes,texdata,nodes,texinfo,leaves,leafbrushes,models,brushes,sides:=lumps[1],lumps[2],lumps[5],lumps[6],lumps[10],lumps[17],lumps[14],lumps[18],lumps[19]
    strings_data,string_table:=lumps[43],lumps[44]
    // Leaves of lump version 0 carry 24 bytes of ambient light after the 32 of version 1.
    leaf_size:=56 if lump_versions[10]==0 && len(leaves)%56==0 else 32
    texture_name :: proc(texdata,strings_data,string_table:[]u8,index:int) -> string {
        if index<0 || (index+1)*32>len(texdata) {return ""}
        id:=int(rd_i32(texdata,index*32+12))
        if id<0 || (id+1)*4>len(string_table) {return ""}
        at:=int(rd_i32(string_table,id*4))
        if at<0 || at>=len(strings_data) {return ""}
        end:=at
        for end<len(strings_data) && strings_data[end]!=0 {end+=1}
        return string(strings_data[at:end])
    }
    // The brushes under the tree of each model, each once.
    taken:=make([]bool,len(brushes)/12,context.temp_allocator)
    displacements:=0
    collect :: proc(nodes,leaves,leafbrushes:[]u8,leaf_size,node:int,out:^[dynamic]int,depth:int) {
        if depth>4096 {return}
        if node<0 {
            leaf:=-1-node
            if (leaf+1)*leaf_size>len(leaves) {return}
            first,count:=rd_u16(leaves,leaf*leaf_size+24),rd_u16(leaves,leaf*leaf_size+26)
            for i in first..<first+count {
                if (i+1)*2>len(leafbrushes) {break}
                append(out,rd_u16(leafbrushes,i*2))
            }
            return
        }
        if (node+1)*32>len(nodes) {return}
        for c in 0..<2 {collect(nodes,leaves,leafbrushes,leaf_size,int(rd_i32(nodes,node*32+4+c*4)),out,depth+1)}
    }
    found:=make([dynamic]int,context.temp_allocator)
    for &e,ei in m.entities {
        model:=0 if ei==0 else -1
        origin:[3]f64
        if ei>0 {model,origin=entity_model(&e)}
        if model<0 {continue}
        if (model+1)*48>len(models) {mapfile.map_warn(m,"entity %d names model *%d, which the BSP does not have",ei,model);continue}
        clear(&found)
        collect(nodes,leaves,leafbrushes,leaf_size,int(rd_i32(models,model*48+36)),&found,0)
        for bi in found {
            if bi>=len(taken) || taken[bi] {continue}
            taken[bi]=true
            first,count:=int(rd_i32(brushes,bi*12)),int(rd_i32(brushes,bi*12+4))
            brush:mapfile.Brush
            for si in first..<first+count {
                if (si+1)*8>len(sides) {break}
                plane_index:=rd_u16(sides,si*8)
                ti:=rd_i16(sides,si*8+2)
                disp:=rd_i16(sides,si*8+4)
                bevel:=rd_i16(sides,si*8+6)
                if bevel!=0 || (plane_index+1)*20>len(planes) {continue}
                if disp>=0 {displacements+=1}
                at:=plane_index*20
                side:=mapfile.Side{plane={{rd_f32(planes,at),rd_f32(planes,at+4),rd_f32(planes,at+8)},rd_f32(planes,at+12)}}
                if ti>=0 && (ti+1)*72<=len(texinfo) {
                    vecs:[2][4]f64
                    for s in 0..<2 {for k in 0..<4 {vecs[s][k]=rd_f32(texinfo,ti*72+s*16+k*4)}}
                    mapfile.side_texture_from_vecs(&side,vecs)
                    side.texture=texture_name(texdata,strings_data,string_table,int(rd_i32(texinfo,ti*72+68)))
                } else {
                    side.u,side.v=mapfile.default_axes(side.plane.normal)
                    side.scale={1,1}
                    side.texture="TOOLS/TOOLSNODRAW"
                }
                append(&brush.sides,side)
            }
            brush_keep_faces(&brush)
            if len(brush.sides)<4 {continue}
            if origin!={} {brush_move(&brush,origin)}
            append(&e.brushes,brush)
        }
    }
    if displacements>0 {mapfile.map_warn(m,"%d displacements were left as their flat brush side",displacements)}
    return "",true
}
