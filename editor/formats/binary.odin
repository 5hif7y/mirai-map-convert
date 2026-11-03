package map_convert_formats

import "core:encoding/endian"

// Little-endian reads of the lumps of a BSP.

rd_u16 :: proc(b:[]u8,at:int) -> int {v,_:=endian.get_u16(b[at:at+2],.Little);return int(v)}

rd_i16 :: proc(b:[]u8,at:int) -> int {v,_:=endian.get_i16(b[at:at+2],.Little);return int(v)}

rd_i32 :: proc(b:[]u8,at:int) -> i32 {v,_:=endian.get_i32(b[at:at+4],.Little);return v}

rd_u32 :: proc(b:[]u8,at:int) -> u32 {v,_:=endian.get_u32(b[at:at+4],.Little);return v}

rd_f32 :: proc(b:[]u8,at:int) -> f64 {v,_:=endian.get_f32(b[at:at+4],.Little);return f64(v)}

