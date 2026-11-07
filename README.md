# map_convert: maps of other engines for Mirai

A plugin for the Mirai engine editor that imports maps of Quake III, Source, Hammer and Doom 3, and
standard Quake maps. Each format converts its file to a Valve 220 map in memory, and the loader of
[valve220](https://github.com/5hif7y/mirai-valve220) imports that: the brushes keep their textures
and their texture axes.

It needs `valve220`. BSPs of Quake and GoldSrc are in [bsp_decompile](https://github.com/5hif7y/mirai-bsp-decompile),
a separate plugin under the GPL.

## Install

It is not in the catalog on its own: there it is part of
[brush_maps](https://github.com/5hif7y/mirai-brush-maps), which joins the map plugins in one install
(`mirai plugin add brush_maps`). Installed alone, by its address, in the folder of a Mirai project:

```sh
mirai plugin add https://github.com/5hif7y/mirai-valve220.git
mirai plugin add https://github.com/5hif7y/mirai-map-convert.git
```

## Formats

| File | What is read |
| --- | --- |
| `.vmf` of Hammer (Source) | Its `solid`s, with `uaxis` and `vaxis`. |
| `.map` of Doom 3 and Quake 4 | `brushDef3`, with the texture matrix over the base axes of Radiant. The `.map` does not say the size of a texture: 128 texels are assumed. |
| `.map` of Quake, Quake II and Quake III (standard format) | The base axes of `TextureAxisFromPlane` of qbsp turned into Valve 220 axes. |
| `.bsp` of Quake III (IBSP 46/47, RBSP) | Its brushes, which the BSP keeps, without the bevel sides. Without texture alignment: the default axes of the editor. |
| `.bsp` of Source (VBSP 19-21) | Its brushes, with the textures of `texinfo`. Lumps compressed with LZMA are refused. |

A `.map` is told by its content: one with `brushDef3` is Doom 3, one with face lines without `[ ]`
axes is the standard Quake format, and the rest is Valve 220 for `valve220`.

What Valve 220 cannot hold is left out and counted in a warning: the curved patches of id Tech 3 and
4, the displacements of Source and the models.

## API

Methods of the editor API, and so of its MCP server:

- `map_convert.to_valve220 {path, out}`: converts a map anywhere on disk to a Valve 220 `.map` in the
  project, to edit it in TrenchBroom.
- `map_convert.unpack_wad {path, out, palette}`: writes the textures of a WAD2 or WAD3 as PNG in a
  folder of the project, `textures/` beside a map being where `valve220` looks. A WAD2 of Quake keeps no
  palette: give `gfx/palette.lmp`.

## Tests

With `mirai test plugins/map_convert/editor/formats`. Every test builds its file in code (a cube in
each format, a WAD of two textures): no content of Valve or id is in the repository.

## Not verified

The planes of a `.vmf` and of a Doom 3 `.map` were checked against files written in code with the same
convention as the converter, not against files saved by Hammer or DOOM 3. A real BSP of Quake III and
one of Source were not tried.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE), at your option.
