package map_convert_formats

import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:testing"

// A miptex of GoldSrc of width×height with its four levels, every pixel of
// index fill, and a palette whose color i is (i, 255-i, 7).
test_miptex :: proc(name:string,width,height:int,fill:u8,palette:=true) -> []u8 {
    levels:=miptex_levels_bytes(width,height)
    b:=make([dynamic]u8,levels,context.temp_allocator)
    copy(b[:16],name)
    endian.put_u32(b[16:20],.Little,u32(width))
    endian.put_u32(b[20:24],.Little,u32(height))
    at:=MIPTEX_HEADER
    for level in 0..<4 {
        endian.put_u32(b[24+level*4:28+level*4],.Little,u32(at))
        at+=(width>>uint(level))*(height>>uint(level))
    }
    for i in MIPTEX_HEADER..<levels {b[i]=fill}
    if palette {
        append(&b,0,1)
        for i in 0..<256 {append(&b,u8(i),u8(255-i),7)}
        append(&b,0,0)
    }
    return b[:]
}

@(test)
a_wad_written_reads_back_its_textures_and_colors :: proc(t:^testing.T) {
    a,_:=miptex_read(test_miptex("brick",16,16,3))
    b,_:=miptex_read(test_miptex("{fence",32,16,TRANSPARENT_INDEX))
    wad:=wad_write({a,b},context.temp_allocator)
    found,declared,ok:=wad_read(wad,context.temp_allocator)
    testing.expect(t,ok)
    testing.expect_value(t,declared,2)
    if !testing.expect_value(t,len(found),2) {return}
    testing.expect_value(t,found[0].name,"brick")
    testing.expect_value(t,found[1].name,"{fence")
    testing.expect(t,found[1].width==32 && found[1].height==16)
    rgba,read:=miptex_rgba(found[0],nil,context.temp_allocator)
    testing.expect(t,read && rgba[0]==3 && rgba[1]==252 && rgba[2]==7 && rgba[3]==255)
    // Index 255 of a masked texture is transparent.
    masked,_:=miptex_rgba(found[1],nil,context.temp_allocator)
    testing.expect_value(t,masked[3],0)
}

@(test)
a_quake_texture_needs_the_palette_given :: proc(t:^testing.T) {
    m,ok:=miptex_read(test_miptex("rock",16,16,9,palette=false))
    testing.expect(t,ok && m.palette==nil)
    _,without:=miptex_rgba(m,nil,context.temp_allocator)
    testing.expect(t,!without)
    palette:=make([]u8,PALETTE_BYTES,context.temp_allocator)
    palette[27]=200
    rgba,with:=miptex_rgba(m,palette,context.temp_allocator)
    testing.expect(t,with && rgba[0]==200)
}

@(test)
a_texture_kept_in_a_wad_is_only_a_name_and_a_size :: proc(t:^testing.T) {
    b:=make([]u8,MIPTEX_HEADER,context.temp_allocator)
    copy(b[:16],"sky")
    endian.put_u32(b[16:20],.Little,64)
    endian.put_u32(b[20:24],.Little,32)
    m,ok:=miptex_read(b)
    testing.expect(t,ok && m.name=="sky" && m.width==64 && m.pixels==nil)
}

// A WAD3 with the textures given, for the tests, each with its levels and palette as they came.
wad_write :: proc(textures:[]Miptex,allocator:=context.allocator) -> []u8 {
    out:=make([dynamic]u8,12,allocator)
    offsets:=make([]int,len(textures),context.temp_allocator)
    sizes:=make([]int,len(textures),context.temp_allocator)
    for m,i in textures {
        for len(out)%4!=0 {append(&out,0)}
        offsets[i]=len(out)
        append(&out,..m.lump)
        sizes[i]=len(m.lump)
    }
    for len(out)%4!=0 {append(&out,0)}
    table:=len(out)
    for m,i in textures {
        entry:[32]u8
        endian.put_u32(entry[0:4],.Little,u32(offsets[i]))
        endian.put_u32(entry[4:8],.Little,u32(sizes[i]))
        endian.put_u32(entry[8:12],.Little,u32(sizes[i]))
        entry[12]=0x43 // TYP_MIPTEX
        copy(entry[16:31],m.name)
        append(&out,..entry[:])
    }
    copy(out[0:4],"WAD3")
    endian.put_u32(out[4:8],.Little,u32(len(textures)))
    endian.put_u32(out[8:12],.Little,u32(table))
    return out[:]
}

@(test)
the_textures_of_a_wad_unpack_to_png_files :: proc(t:^testing.T) {
    context.allocator=context.temp_allocator
    a,_:=miptex_read(test_miptex("BRICK",16,32,5))
    q,_:=miptex_read(test_miptex("rock",16,16,9,palette=false))
    w,_:=miptex_read(test_miptex("*water1",16,16,1))
    found,_,_:=wad_read(wad_write({a,q,w}))
    directory,_:=os.temp_directory(context.temp_allocator)
    folder:=fmt.tprintf("%s/mirai-wad-%d/textures",directory,os.get_pid())
    os.remove_all(folder)
    defer os.remove_all(folder)
    written,skipped,ok:=textures_write(found,folder)
    testing.expect(t,ok)
    testing.expect_value(t,written,1)
    // a Quake texture without the palette, and a name no file can have
    testing.expect_value(t,len(skipped),2)
    bytes,read:=os.read_entire_file(fmt.tprintf("%s/BRICK.png",folder),context.temp_allocator)
    testing.expect(t,read==nil && len(bytes)>24 && string(bytes[1:4])=="PNG","BRICK.png")
    // width and height in the header
    testing.expect(t,bytes[19]==16 && bytes[23]==32,"16×32")
}
