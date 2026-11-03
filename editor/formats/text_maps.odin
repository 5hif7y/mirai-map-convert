package map_convert_formats

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import mapfile "project:plugins/valve220/editor/mapfile"

// ---- VMF ----------------------------------------------------------------

@(private)
Vmf_Block :: struct {
    name:string,
    keys:[dynamic][2]string,
    children:[dynamic]Vmf_Block,
}

@(private)
vmf_block :: proc(l:^mapfile.Text_Lexer,name:string) -> (b:Vmf_Block,ok:bool) {
    b.name=name
    for {
        token,quoted,more:=mapfile.text_token(l)
        if !more {return b,false}
        if !quoted && token=="}" {return b,true}
        if quoted {
            value,value_quoted,read:=mapfile.text_token(l)
            if !read || !value_quoted {return b,false}
            append(&b.keys,[2]string{token,value})
            continue
        }
        open,_,read:=mapfile.text_token(l)
        if !read || open!="{" {return b,false}
        child:=vmf_block(l,token) or_return
        append(&b.children,child)
    }
}

@(private)
vmf_key :: proc(b:^Vmf_Block,key:string) -> string {
    for kv in b.keys {if kv[0]==key {return kv[1]}}
    return ""
}

// "[ux uy uz shift] scale"
@(private)
vmf_axis :: proc(text:string) -> (axis:[3]f64,shift,scale:f64,ok:bool) {
    v:[5]f64
    if !mapfile.text_numbers(text,v[:]) {return}
    return {v[0],v[1],v[2]},v[3],v[4],true
}

@(private)
vmf_solid :: proc(m:^mapfile.Map,solid:^Vmf_Block,displacements:^int) -> (brush:mapfile.Brush,ok:bool) {
    for &child in solid.children {
        if child.name!="side" {continue}
        p:[9]f64
        if !mapfile.text_numbers(vmf_key(&child,"plane"),p[:]) {continue}
        side:mapfile.Side
        side.points={{p[0],p[1],p[2]},{p[3],p[4],p[5]},{p[6],p[7],p[8]}}
        side.has_points=true
        plane,valid:=mapfile.plane_from_points(side.points)
        if !valid {continue}
        side.plane=plane
        side.texture=vmf_key(&child,"material")
        u,shift_u,scale_u,has_u:=vmf_axis(vmf_key(&child,"uaxis"))
        v,shift_v,scale_v,has_v:=vmf_axis(vmf_key(&child,"vaxis"))
        if has_u && has_v {
            side.u,_=mapfile.normalize(u)
            side.v,_=mapfile.normalize(v)
            side.shift={shift_u,shift_v}
            side.scale={scale_u,scale_v}
        } else {
            side.u,side.v=mapfile.default_axes(plane.normal)
            side.scale={1,1}
        }
        for grandchild in child.children {if grandchild.name=="dispinfo" {displacements^+=1}}
        append(&brush.sides,side)
    }
    return brush,len(brush.sides)>=4
}

// A .vmf: world and entity blocks, their keys and their solids.
convert_vmf :: proc(text:string,m:^mapfile.Map) -> (message:string,ok:bool) {
    l:=mapfile.Text_Lexer{text=text,line=1}
    world:mapfile.Entity
    entities:=make([dynamic]mapfile.Entity)
    displacements:=0
    for {
        name,quoted,more:=mapfile.text_token(&l)
        if !more {break}
        if quoted {return "a quoted string outside a block",false}
        open,_,read:=mapfile.text_token(&l)
        if !read || open!="{" {return "{ expected after a block name",false}
        block,valid:=vmf_block(&l,name)
        if !valid {return "a block is not closed",false}
        if name!="world" && name!="entity" {continue}
        e:mapfile.Entity
        for kv in block.keys {
            if kv[0]=="id" || kv[0]=="mapversion" {continue}
            append(&e.keys,kv)
        }
        for &child in block.children {
            if child.name!="solid" {continue}
            if brush,good:=vmf_solid(m,&child,&displacements);good {append(&e.brushes,brush)}
        }
        if name=="world" {world=e} else {append(&entities,e)}
    }
    if len(world.keys)==0 && len(world.brushes)==0 {return "the .vmf has no world block",false}
    mapfile.entity_set(&world,"classname","worldspawn")
    append(&m.entities,world)
    append(&m.entities,..entities[:])
    if displacements>0 {mapfile.map_warn(m,"%d displacements were left as their flat brush side",displacements)}
    return "",true
}

// ---- Doom 3 and Quake 4 --------------------------------------------------

// The texture axes Radiant and Doom 3 put on a plane before the texture
// tex_matrix of brushDef3 turns and scales them.
@(private)
axis_base :: proc(normal:[3]f64) -> (s,t:[3]f64) {
    n:=normal
    for &k in n {if abs(k)<1e-6 {k=0}}
    rot_y:=-math.atan2(n.z,math.sqrt(n.y*n.y+n.x*n.x))
    rot_z:=math.atan2(n.y,n.x)
    s={-math.sin(rot_z),math.cos(rot_z),0}
    t={-math.sin(rot_y)*math.cos(rot_z),-math.sin(rot_y)*math.sin(rot_z),-math.cos(rot_y)}
    return
}

@(private)
doom3_expect :: proc(l:^mapfile.Text_Lexer,wanted:string) -> bool {
    token,quoted,ok:=mapfile.text_token(l)
    return ok && !quoted && token==wanted
}

@(private)
doom3_number :: proc(l:^mapfile.Text_Lexer) -> (v:f64,ok:bool) {
    token,quoted,read:=mapfile.text_token(l)
    if !read || quoted {return}
    return strconv.parse_f64(token)
}

// ( a b c d ) ( ( xx xy xz ) ( yx yy yz ) ) "material" 0 0 0
@(private)
doom3_side :: proc(l:^mapfile.Text_Lexer) -> (side:mapfile.Side,ok:bool) {
    eq:[4]f64
    for k in 0..<4 {eq[k]=doom3_number(l) or_return}
    doom3_expect(l,")") or_return
    doom3_expect(l,"(") or_return
    tex_matrix:[2][3]f64
    for row in 0..<2 {
        doom3_expect(l,"(") or_return
        for k in 0..<3 {tex_matrix[row][k]=doom3_number(l) or_return}
        doom3_expect(l,")") or_return
    }
    doom3_expect(l,")") or_return
    material,quoted,read:=mapfile.text_token(l)
    if !read || !quoted {return}
    // three flags or numbers that Valve 220 has no use for
    for _ in 0..<3 {
        save:=l^
        token,_,more:=mapfile.text_token(l)
        if !more || token==")" || token=="(" || token=="}" {l^=save;break}
    }
    n,length:=mapfile.normalize({eq[0],eq[1],eq[2]})
    if length<1e-9 {return}
    side.plane={n,-eq[3]/length}
    side.texture=material
    // s = (m00 S + m01 T)·p + m02, in textures; in texels, times the size.
    s_axis,t_axis:=axis_base(n)
    for row in 0..<2 {
        world:=s_axis*tex_matrix[row][0]+t_axis*tex_matrix[row][1]
        axis,size:=mapfile.normalize(world)
        if size<1e-12 {axis=s_axis if row==0 else t_axis;size=1.0/mapfile.DOOM3_TEXTURE_SIZE}
        if row==0 {side.u=axis} else {side.v=axis}
        side.scale[row]=1/(size*mapfile.DOOM3_TEXTURE_SIZE)
        side.shift[row]=tex_matrix[row][2]*mapfile.DOOM3_TEXTURE_SIZE
    }
    return side,true
}

@(private)
skip_block :: proc(l:^mapfile.Text_Lexer) -> bool {
    depth:=1
    for depth>0 {
        token,quoted,ok:=mapfile.text_token(l)
        if !ok {return false}
        if quoted {continue}
        if token=="{" {depth+=1}
        if token=="}" {depth-=1}
    }
    return true
}

// A .map of Doom 3 or Quake 4: "Version 2" (or 3), entities with brushDef3 and patches.
convert_doom3 :: proc(text:string,m:^mapfile.Map) -> (message:string,ok:bool) {
    l:=mapfile.Text_Lexer{text=text,line=1}
    patches,old_brushes:=0,0
    for {
        token,quoted,more:=mapfile.text_token(&l)
        if !more {break}
        if !quoted && token=="Version" {_,_,_=mapfile.text_token(&l);continue}
        if quoted || token!="{" {return "an entity was expected",false}
        e:mapfile.Entity
        entity: for {
            key,key_quoted,read:=mapfile.text_token(&l)
            if !read {return "an entity is not closed",false}
            switch {
            case key_quoted:
                value,_,_:=mapfile.text_token(&l)
                append(&e.keys,[2]string{key,value})
            case key=="}":
                break entity
            case key=="{":
                kind,_,_:=mapfile.text_token(&l)
                if kind!="brushDef3" {
                    if kind=="patchDef2" || kind=="patchDef3" {patches+=1} else {old_brushes+=1}
                    // the rest of this primitive, and the brace that closes it
                    if !skip_block(&l) {return "a primitive is not closed",false}
                    continue
                }
                if !doom3_expect(&l,"{") {return "{ expected after brushDef3",false}
                brush:mapfile.Brush
                for {
                    t,_,r:=mapfile.text_token(&l)
                    if !r {return "a brush is not closed",false}
                    if t=="}" {break}
                    if t!="(" {return "a side was expected in a brushDef3",false}
                    side,good:=doom3_side(&l)
                    if !good {return "a side of a brushDef3 could not be read",false}
                    append(&brush.sides,side)
                }
                if !doom3_expect(&l,"}") {return "} expected after a brushDef3",false}
                if len(brush.sides)>=4 {append(&e.brushes,brush)}
            case:
                return "a key, a brush or } was expected in an entity",false
            }
        }
        // Doom 3 places the brushes of an entity other than worldspawn around its origin.
        if len(m.entities)>0 {
            if origin,has:=mapfile.entity_get(&e,"origin");has {
                o:[3]f64
                if mapfile.text_numbers(origin,o[:]) && o!={} {
                    // The texture of Doom 3 is already in the space of the world
                    // (GetTextureVectors adds the origin): only the planes move.
                    for &brush in e.brushes {
                        for &side in brush.sides {side.plane.dist+=mapfile.dot(side.plane.normal,o)}
                    }
                }
            }
        }
        append(&m.entities,e)
    }
    if len(m.entities)==0 {return "the map has no entities",false}
    if patches>0 {mapfile.map_warn(m,"%d patches (curved surfaces) were left out",patches)}
    if old_brushes>0 {mapfile.map_warn(m,"%d primitives that are not brushDef3 were left out",old_brushes)}
    mapfile.map_warn(m,"Doom 3 does not say the size of its textures: each is taken as %d texels",mapfile.DOOM3_TEXTURE_SIZE)
    return "",true
}

// ---- Quake .map, the standard format --------------------------------------

// The texture axes of Quake for a face of the standard format: those of the
// world plane closest to it (TextureAxisFromPlane in qbsp), turned by the
// rotation and divided by the scale.
@(private)
QUAKE_BASE_AXES :: [6][3][3]f64{
    {{0,0,1},{1,0,0},{0,-1,0}},  // floor
    {{0,0,-1},{1,0,0},{0,-1,0}}, // ceiling
    {{1,0,0},{0,1,0},{0,0,-1}},  // west wall
    {{-1,0,0},{0,1,0},{0,0,-1}}, // east wall
    {{0,1,0},{1,0,0},{0,0,-1}},  // south wall
    {{0,-1,0},{1,0,0},{0,0,-1}}, // north wall
}

quake_standard_vecs :: proc(normal:[3]f64,shift:[2]f64,rotation:f64,scale:[2]f64) -> (vecs:[2][4]f64) {
    axes:=QUAKE_BASE_AXES
    best,best_dot:=0,-1.0
    for i in 0..<6 {
        if d:=mapfile.dot(axes[i][0],normal);d>best_dot+1e-9 {best,best_dot=i,d}
    }
    v:=[2][3]f64{axes[best][1],axes[best][2]}
    sinv,cosv:=math.sin(math.to_radians(rotation)),math.cos(math.to_radians(rotation))
    switch rotation {
    case 0:   sinv,cosv=0,1
    case 90:  sinv,cosv=1,0
    case 180: sinv,cosv=0,-1
    case 270: sinv,cosv=-1,0
    }
    sv:=0 if v[0][0]!=0 else (1 if v[0][1]!=0 else 2)
    tv:=0 if v[1][0]!=0 else (1 if v[1][1]!=0 else 2)
    for i in 0..<2 {
        ns:=cosv*v[i][sv]-sinv*v[i][tv]
        nt:=sinv*v[i][sv]+cosv*v[i][tv]
        v[i][sv],v[i][tv]=ns,nt
    }
    for i in 0..<2 {
        sc:=scale[i] if scale[i]!=0 else 1
        for k in 0..<3 {vecs[i][k]=v[i][k]/sc}
        vecs[i][3]=shift[i]
    }
    return
}

// A .map of Quake, Quake II or Quake III in the standard format (a face is
// three points, a texture, two shifts, a rotation and two scales, and in
// Quake II and III three numbers more), or already in Valve 220.
convert_quake_map :: proc(text:string,m:^mapfile.Map) -> (message:string,ok:bool) {
    l:=mapfile.Text_Lexer{text=text,line=1}
    standard,patches:=0,0
    for {
        token,quoted,more:=mapfile.text_token(&l)
        if !more {break}
        if quoted || token!="{" {return fmt.aprintf("line %d: an entity was expected",l.line),false}
        e:mapfile.Entity
        entity: for {
            key,key_quoted,read:=mapfile.text_token(&l)
            if !read {return "an entity is not closed",false}
            switch {
            case key_quoted:
                value,_,_:=mapfile.text_token(&l)
                append(&e.keys,[2]string{key,value})
            case key=="}":
                break entity
            case key=="{":
                save:=l
                first,_,_:=mapfile.text_token(&l)
                if first!="(" {
                    // patchDef2, brushDef: not a brush of the standard format
                    if first=="patchDef2" || first=="patchDef3" {patches+=1}
                    l=save
                    if !skip_block(&l) {return "a primitive is not closed",false}
                    continue
                }
                l=save
                brush:mapfile.Brush
                for {
                    t,_,r:=mapfile.text_token(&l)
                    if !r {return "a brush is not closed",false}
                    if t=="}" {break}
                    if t!="(" {return fmt.aprintf("line %d: a face was expected",l.line),false}
                    side:mapfile.Side
                    for k in 0..<3 {
                        if k>0 && !doom3_expect(&l,"(") {return fmt.aprintf("line %d: ( expected",l.line),false}
                        for c in 0..<3 {
                            v,good:=doom3_number(&l)
                            if !good {return fmt.aprintf("line %d: a number expected",l.line),false}
                            side.points[k][c]=v
                        }
                        if !doom3_expect(&l,")") {return fmt.aprintf("line %d: ) expected",l.line),false}
                    }
                    side.has_points=true
                    side.texture=mapfile.text_word(&l)
                    plane,valid:=mapfile.plane_from_points(side.points)
                    side.plane=plane
                    save_axes:=l
                    open,_,_:=mapfile.text_token(&l)
                    if open=="[" {
                        // Valve 220: [ u shift ] [ v shift ] rotation sx sy
                        nums:[8]f64
                        bad:=false
                        for i in 0..<4 {v,good:=doom3_number(&l);nums[i]=v;bad|=!good}
                        bad|=!doom3_expect(&l,"]")
                        bad|=!doom3_expect(&l,"[")
                        for i in 4..<8 {v,good:=doom3_number(&l);nums[i]=v;bad|=!good}
                        bad|=!doom3_expect(&l,"]")
                        _,_=doom3_number(&l)
                        sx,_:=doom3_number(&l)
                        sy,_:=doom3_number(&l)
                        if bad {return fmt.aprintf("line %d: Valve 220 texture axes expected",l.line),false}
                        side.u,_=mapfile.normalize({nums[0],nums[1],nums[2]})
                        side.v,_=mapfile.normalize({nums[4],nums[5],nums[6]})
                        side.shift={nums[3],nums[7]}
                        side.scale={sx if sx!=0 else 1,sy if sy!=0 else 1}
                    } else {
                        l=save_axes
                        p:[5]f64
                        for i in 0..<5 {
                            v,good:=doom3_number(&l)
                            if !good {return fmt.aprintf("line %d: texture shift, rotation and scale expected",l.line),false}
                            p[i]=v
                        }
                        mapfile.side_texture_from_vecs(&side,quake_standard_vecs(plane.normal,{p[0],p[1]},p[2],{p[3],p[4]}))
                        standard+=1
                        // Quake II and III: contents, flags and value
                        for _ in 0..<3 {
                            save_extra:=l
                            t2,_,r2:=mapfile.text_token(&l)
                            if !r2 || t2=="(" || t2=="}" {l=save_extra;break}
                        }
                    }
                    if valid {append(&brush.sides,side)}
                }
                if len(brush.sides)>=4 {append(&e.brushes,brush)}
            case:
                return fmt.aprintf("line %d: a key, a brush or } was expected",l.line),false
            }
        }
        append(&m.entities,e)
    }
    if len(m.entities)==0 {return "the map has no entities",false}
    if patches>0 {mapfile.map_warn(m,"%d patches (curved surfaces) were left out",patches)}
    if standard>0 {mapfile.map_warn(m,"%d faces of the standard format were turned into Valve 220 axes",standard)}
    return "",true
}
