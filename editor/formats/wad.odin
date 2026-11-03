package map_convert_formats

import "core:c"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:strings"
import stbi "vendor:stb/image"

// The textures of Quake and GoldSrc, which mapconvert unpacks to the PNG
// files the importer reads (<folder of the map>/textures/<name>.png): Mirai
// reads no WAD. A miptex is a name of 16 bytes, its
// width and height, the offsets of four mip levels of 8-bit indices and, in
// GoldSrc (WAD3 and BSP 30), a palette of 256 RGB colors after the last level.
// Quake (WAD2 and BSP 29) keeps no palette in the texture: it uses the one of
// gfx/palette.lmp. A WAD is a header, the textures and a table of lumps; a BSP
// keeps its textures in a lump of offsets and miptexes.
//
// A name that starts with `{` is a masked texture: index 255 is transparent.

MIPTEX_HEADER :: 40
MIPTEX_MAX_SIZE :: 4096
PALETTE_BYTES :: 768
TRANSPARENT_INDEX :: 255

Miptex :: struct {
    name:string,  // a view into the bytes it was read from
    width,height:int,
    pixels:[]u8,  // width*height indices of mip 0
    palette:[]u8, // PALETTE_BYTES, or nil when the texture keeps none
    lump:[]u8,    // the whole miptex, its levels and its palette
}

@(private)
u32le :: proc "contextless" (b:[]u8,at:int) -> u32 {
    value,_:=endian.get_u32(b[at:at+4],.Little)
    return value
}

@(private)
aligned :: proc "contextless" (at:int) -> int {return (at+3)&~3}

// The bytes a miptex of this size takes up to its palette: the header and
// four levels, each a quarter of the one before (85/64 of mip 0).
@(private)
miptex_levels_bytes :: proc "contextless" (width,height:int) -> int {
    return MIPTEX_HEADER+width*height*85/64
}

// The miptex at the start of b, when its header is one. A texture that keeps
// its pixels elsewhere (offsets 0: a texture of a WAD referred to by a BSP)
// is only a name and a size, with no pixels.
miptex_read :: proc(b:[]u8) -> (m:Miptex,ok:bool) {
    if len(b)<MIPTEX_HEADER {return}
    width,height:=int(u32le(b,16)),int(u32le(b,20))
    if width<=0 || height<=0 || width>MIPTEX_MAX_SIZE || height>MIPTEX_MAX_SIZE {return}
    name_bytes:=b[:16]
    end:=0
    for end<16 && name_bytes[end]!=0 {end+=1}
    m.name=string(name_bytes[:end])
    m.width,m.height=width,height
    first:=int(u32le(b,24))
    if first==0 {return m,true} // in a WAD, not in this file
    if first!=MIPTEX_HEADER {return}
    levels:=miptex_levels_bytes(width,height)
    if levels>len(b) {return}
    m.pixels=b[MIPTEX_HEADER:MIPTEX_HEADER+width*height]
    m.lump=b[:levels]
    // GoldSrc: a count of colors (u16, 256) and the palette after the last level.
    last:=int(u32le(b,36))+max(width/8,1)*max(height/8,1)
    if last+2+PALETTE_BYTES<=len(b) && last>=MIPTEX_HEADER && b[last]==0 && b[last+1]==1 {
        m.palette=b[last+2:last+2+PALETTE_BYTES]
        m.lump=b[:last+2+PALETTE_BYTES]
    }
    return m,true
}

// The RGBA8 pixels of mip 0, rows from the top, with palette or, when the
// texture keeps none, fallback. A masked texture leaves index 255 transparent.
miptex_rgba :: proc(m:Miptex,fallback:[]u8=nil,allocator:=context.allocator) -> (rgba:[]u8,ok:bool) {
    palette:=m.palette if m.palette!=nil else fallback
    if len(palette)<PALETTE_BYTES || len(m.pixels)<m.width*m.height {return nil,false}
    masked:=strings.has_prefix(m.name,"{")
    rgba=make([]u8,m.width*m.height*4,allocator)
    for index,i in m.pixels[:m.width*m.height] {
        if masked && index==TRANSPARENT_INDEX {continue}
        at:=int(index)*3
        rgba[i*4+0]=palette[at+0]
        rgba[i*4+1]=palette[at+1]
        rgba[i*4+2]=palette[at+2]
        rgba[i*4+3]=255
    }
    return rgba,true
}

// The textures of a WAD2 or WAD3, in the order they are in the file. They are
// read walking the file, not by its table of lumps: some writers (bsputil of
// ericw-tools) leave the offsets of the table before the palette, and the
// table is wrong. Each texture ends where the next header begins, with or
// without the palette that follows a last level that is not aligned.
wad_read :: proc(b:[]u8,allocator:=context.allocator) -> (textures:[]Miptex,declared:int,ok:bool) {
    if len(b)<12 || (string(b[:4])!="WAD2" && string(b[:4])!="WAD3") {return}
    declared=int(u32le(b,4))
    table:=int(u32le(b,8))
    found:=make([dynamic]Miptex,allocator)
    at:=12
    // The textures go between the header and the table, or after the table.
    if table==12 {at=aligned(12+declared*32)}
    header_at :: proc(b:[]u8,at:int) -> bool {
        if at<0 || at+MIPTEX_HEADER>len(b) {return false}
        width,height:=int(u32le(b,at+16)),int(u32le(b,at+20))
        if width<=0 || height<=0 || width>MIPTEX_MAX_SIZE || height>MIPTEX_MAX_SIZE {return false}
        if int(u32le(b,at+24))!=MIPTEX_HEADER {return false}
        return at+miptex_levels_bytes(width,height)<=len(b)
    }
    for header_at(b,aligned(at)) {
        at=aligned(at)
        width,height:=int(u32le(b,at+16)),int(u32le(b,at+20))
        levels:=miptex_levels_bytes(width,height)
        length:=levels
        // The next texture starts after the levels, or after the levels and the palette.
        for extra in ([2]int{0,2+PALETTE_BYTES}) {
            if header_at(b,aligned(at+levels+extra)) {length=aligned(at+levels+extra)-at;break}
            if extra>0 && at+levels+extra<=len(b) {length=levels+extra}
        }
        if m,read:=miptex_read(b[at:min(at+length,len(b))]);read && m.name!="" {append(&found,m)}
        at+=length
        if table>12 && at>=table {break}
    }
    return found[:],declared,true
}

// Characters a texture name may have that a file name may not (Quake names
// liquids *water1): such a texture is not written, as no PNG can carry its name.
@(private)
FILE_NAME_FORBIDDEN :: `<>:"/\|?*`

// Writes each texture as <folder>/<name>.png, the file the importer of maps
// looks for. palette is for the textures of Quake, which keep none (the
// 768 bytes of gfx/palette.lmp); nil leaves them out.
textures_write :: proc(textures:[]Miptex,folder:string,palette:[]u8=nil) -> (written:int,skipped:[dynamic]string,ok:bool) {
    skipped=make([dynamic]string,context.temp_allocator)
    if os.make_directory_all(folder)!=nil && !os.is_dir(folder) {return 0,skipped,false}
    seen:=make(map[string]bool,context.temp_allocator)
    for m in textures {
        if m.pixels==nil || m.name=="" {continue}
        lower:=strings.to_lower(m.name,context.temp_allocator)
        if seen[lower] {continue}
        seen[lower]=true
        if strings.contains_any(m.name,FILE_NAME_FORBIDDEN) {
            append(&skipped,fmt.tprintf("%s: the name cannot be a file name",m.name))
            continue
        }
        rgba,has_palette:=miptex_rgba(m,palette,context.temp_allocator)
        if !has_palette {
            append(&skipped,fmt.tprintf("%s: no palette (a Quake texture: give gfx/palette.lmp)",m.name))
            continue
        }
        path:=fmt.ctprintf("%s/%s.png",folder,m.name)
        if stbi.write_png(path,c.int(m.width),c.int(m.height),4,raw_data(rgba),c.int(m.width*4))==0 {
            append(&skipped,fmt.tprintf("%s: %s could not be written",m.name,path))
            continue
        }
        written+=1
    }
    return written,skipped,true
}
