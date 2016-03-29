# bmfont

Parser & generator for font files generated using AngelCode Bitmap Font Generator

## Usage

### Parsing files
```d
import bmfont;

import std.file;
import std.stdio : writeln;

auto font = parseFnt(cast(ubyte[]) read("fonts/roboto.fnt"));

writeln(font.info.fontName);
```

### Generating files
```d
import bmfont;

Font font; // ... set somewhere

string text = font.toString();
ubyte[] binary = font.toBinary();
```