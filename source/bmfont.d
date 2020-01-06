/// AngelCode BMFont parser & generator
/// Copyright: Public Domain
/// Author: Jan Jurzitza
module bmfont; @safe:

import std.array : Appender, appender;
import std.ascii : isAlpha, isWhite;
import std.bitmanip : littleEndianToNative, nativeToLittleEndian;
import std.conv : to;
import std.string : representation, splitLines, strip, stripLeft;
import std.traits : isSomeString;

/// Information what each channel contains
enum ChannelType : ubyte
{
	/// (0) This channel will contain the character
	glyph = 0,
	/// (1) This channel will contain the outline of the character
	outline = 1,
	/// (2) This channel will contain the character and outline
	glyphAndOutline = 2,
	/// (3) This channel will always be zero
	zero = 3,
	/// (4) This channel will always be one
	one = 4
}

/// Bitfield on which channel a character is found
enum Channels : ubyte
{
	/// 1
	blue = 1,
	/// 2
	green = 2,
	/// 4
	red = 4,
	/// 8
	alpha = 8,
	/// 15
	all = 15
}

/// Flags for parsing
enum ParseFlags : ubyte
{
	/// No special flags
	none = 0,
	/// The parser will ignore the info block
	skipInfo = 1 << 0,
	/// The parser will ignore the common block
	skipCommon = 1 << 1,
	/// The parser will ignore the kerning block
	skipKerning = 1 << 2,
	/// The parser will ignore the pages block
	skipPages = 1 << 3,
	/// Skips the info and common block
	skipMeta = skipInfo | skipCommon,
	/// Skips all blocks except the character block
	skipNonChar = skipMeta | skipKerning | skipPages
}

private enum FontType : ubyte
{
	none,
	binary,
	xml,
	text
}

/// Generic Font struct containing all information from a BMFont file
struct Font
{
	/// Info struct containing meta information about the exported font and export settings
	struct Info
	{
		/// The size of the true type font
		short fontSize;
		/// bit 0: smooth, bit 1: unicode, bit 2: italic, bit 3: bold, bit 4: fixedHeigth, bits 5-7: reserved
		ubyte bitField;
		/// Charset identifier. Not used when parsing from a text file.
		ubyte charSet;
		/// The font height stretch as percentage. 100 means no stretch.
		ushort stretchH;
		/// The supersampling level used. 1 means no supersampling was used.
		ubyte aa;
		/// The padding for each character (up, right, down, left)
		ubyte[4] padding;
		/// The spacing for each character (horizontal, vertical)
		ubyte[2] spacing;
		/// The name of the true type font
		string fontName;
		/// The outline thickness for the characters
		ubyte outline;
	}

	/// Struct containing common information about the font used for rendering
	struct Common
	{
		/// This is the distance in pixels between each line of text
		ushort lineHeight;
		/// The number of pixels from the absolute top of the line to the base of the characters
		ushort base;
		/// The width of the texture, normally used to scale the x pos of the character image
		ushort scaleW;
		/// The height of the texture, normally used to scale the y pos of the character image
		ushort scaleH;
		/// The number of texture pages included in the font
		ushort pages;
		/// bits 0-6: reserved, bit 7: packed
		ubyte bitField;
		/// What information the alpha channel holds
		ChannelType alphaChnl;
		/// What information the red channel holds
		ChannelType redChnl;
		/// What information the green channel holds
		ChannelType greenChnl;
		/// What information the blue channel holds
		ChannelType blueChnl;
	}

	/// Struct containing information about one character
	struct Char
	{
		/// The character id
		dchar id;
		/// The left position of the character image in the texture
		ushort x;
		/// The top position of the character image in the texture
		ushort y;
		/// The width of the character image in the texture
		ushort width;
		/// The height of the character image in the texture
		ushort height;
		/// How much the current position should be offset when copying the image from the texture to the screen
		short xoffset, yoffset;
		/// How much the current position should be advanced after drawing the character
		short xadvance;
		/// The texture page where the character image is found
		ubyte page;
		/// The texture channel where the character image is found
		Channels chnl;
	}

	/// Struct containing the kerning amount between 2 characters
	struct Kerning
	{
		/// The first character id
		dchar first;
		/// The second character id
		dchar second;
		/// How much the x position should be adjusted when drawing the second character immediately following the first
		short amount;
	}

	/// Version of the file
	ubyte fileVersion;
	/// Info struct containing meta information about the exported font and export settings
	Info info;
	/// Struct containing common information about the font used for rendering
	Common common;
	/// Array of page file locations
	string[] pages;
	/// Array containing information about all characters
	Char[] chars;
	/// Array containing all kerning pairs between characters which are not zero
	Kerning[] kernings;

	/// Type of the font data
	FontType type = FontType.none;

	/// Creates a text representation of this font
	string toString() const @safe pure
	{
		import std.format;

		string content = "";

		//dfmt off
		content ~= format(`info face="%s" size=%d bold=%d italic=%d ` ~
			`charset="" unicode=%d stretchH=%d smooth=%d aa=%d padding=%(%d,%) ` ~
			`spacing=%(%d,%) outline=%d`, info.fontName.escape, info.fontSize, (info.bitField & 0b0001_0000) >> 4,
			(info.bitField & 0b0010_0000) >> 5, (info.bitField & 0b0100_0000) >> 6, info.stretchH,
			(info.bitField & 0b1000_0000) >> 7, info.aa, info.padding, info.spacing, info.outline) ~ '\n';
		content ~= format(`common lineHeight=%d base=%d scaleW=%d scaleH=%d ` ~
			`pages=%d packed=%d alphaChnl=%d redChnl=%d greenChnl=%d blueChnl=%d`,
			common.lineHeight, common.base, common.scaleW, common.scaleH, pages.length,
			(common.bitField & 0b0000_0001), cast(uint) common.alphaChnl, cast(uint) common.redChnl,
			cast(uint) common.greenChnl, cast(uint) common.blueChnl) ~ '\n';
		//dfmt on

		foreach (i, page; pages)
			content ~= format(`page id=%d file="%s"`, i, page.escape) ~ '\n';

		content ~= "chars count=" ~ chars.length.to!string ~ '\n';

		foreach (Char c; chars)
			content ~= format(
				`char id=%d x=%d y=%d width=%d height=%d xoffset=%d yoffset=%d xadvance=%d page=%d chnl=%d`,
				c.id, c.x, c.y, c.width, c.height, c.xoffset, c.yoffset,
				c.xadvance, c.page, cast(uint) c.chnl) ~ '\n';

		content ~= "kernings count=" ~ kernings.length.to!string ~ '\n';

		foreach (Kerning k; kernings)
			content ~= format(`kerning first=%d second=%d amount=%d`,
				cast(uint) k.first, cast(uint) k.second, k.amount) ~ '\n';

		return content;
	}

	/// Creates a binary representation of this font
	ubyte[] toBinary() const @safe pure
	{
		import std.string : toStringz;

		auto header = appender(cast(ubyte[])[66, 77, 70, 3]); // BMF v3
		auto binfo = appender!(ubyte[]);
		auto bcommon = appender!(ubyte[]);
		auto bpages = appender!(ubyte[]);
		auto bchars = appender!(ubyte[]);
		auto bkernings = appender!(ubyte[]);

		binfo.putRange(nativeToLittleEndian(info.fontSize));
		binfo.put(info.bitField);
		binfo.put(info.charSet);
		binfo.putRange(nativeToLittleEndian(info.stretchH));
		binfo.put(info.aa);
		binfo.putRange(info.padding);
		binfo.putRange(info.spacing);
		binfo.put(info.outline);
		binfo.putRange(info.fontName);
		binfo.put(cast(ubyte) 0u);

		bcommon.putRange(nativeToLittleEndian(common.lineHeight));
		bcommon.putRange(nativeToLittleEndian(common.base));
		bcommon.putRange(nativeToLittleEndian(common.scaleW));
		bcommon.putRange(nativeToLittleEndian(common.scaleH));
		bcommon.putRange(nativeToLittleEndian(common.pages));
		bcommon.put(common.bitField);
		bcommon.put(common.alphaChnl);
		bcommon.put(common.redChnl);
		bcommon.put(common.greenChnl);
		bcommon.put(common.blueChnl);

		foreach (page; pages)
		{
			bpages.putRange(page);
			bpages.put(cast(ubyte) 0u);
		}

		foreach (c; chars)
		{
			bchars.putRange(nativeToLittleEndian(cast(uint) c.id));
			bchars.putRange(nativeToLittleEndian(c.x));
			bchars.putRange(nativeToLittleEndian(c.y));
			bchars.putRange(nativeToLittleEndian(c.width));
			bchars.putRange(nativeToLittleEndian(c.height));
			bchars.putRange(nativeToLittleEndian(c.xoffset));
			bchars.putRange(nativeToLittleEndian(c.yoffset));
			bchars.putRange(nativeToLittleEndian(c.xadvance));
			bchars.put(c.page);
			bchars.put(c.chnl);
		}

		foreach (k; kernings)
		{
			bkernings.putRange(nativeToLittleEndian(cast(uint) k.first));
			bkernings.putRange(nativeToLittleEndian(cast(uint) k.second));
			bkernings.putRange(nativeToLittleEndian(k.amount));
		}

		foreach (i, block; [binfo, bcommon, bpages, bchars, bkernings])
		{
			header.put(cast(ubyte)(i + 1));
			header.putRange(nativeToLittleEndian(cast(uint) block.data.length));
			header.put(block.data);
		}

		return header.data;
	}

	/// Returns: Information about the character passed as argument `c`. Empty Char struct with dchar.init as id if not found.
	Char getChar(dchar id) const nothrow pure
	{
		foreach (c; chars)
			if (c.id == id)
				return c;
		return Char();
	}

	/// Returns: the kerning between two characters. This is the additional distance the `second` character should be moved if the character before that is `first`
	short getKerning(dchar first, dchar second) const nothrow pure
	{
		foreach (kerning; kernings)
			if (kerning.first == first && kerning.second == second)
				return kerning.amount;
		return 0;
	}
}

private void putRange(size_t n)(ref Appender!(ubyte[]) dst, ubyte[n] src) pure
{
	foreach (b; src)
		dst.put(b);
}

private void putRange(ref Appender!(ubyte[]) dst, scope const(char)[] src) pure
{
	foreach (char c; src)
		dst.put(cast(ubyte) c);
}

private string escape(in string s) pure nothrow @safe
{
	import std.string : replace;

	return s.replace("\\", "\\\\").replace("\"", "\\\"");
}

private const(ubyte)[] getReadonlyBytes(T)(return scope T[] data) pure
	if (T.sizeof == 1)
{
	return (() @trusted => cast(const(ubyte)[]) data)();
}

/// Gets thrown if a Font is in an invalid format
class InvalidFormatException : Exception
{
	this(string msg = "Font is in an invalid format", string file = __FILE__, size_t line = __LINE__) pure nothrow @nogc @safe
	{
		super(msg, file, line);
	}
}

/// Parses a font and automatically figures out if its binary or text. Pass additional ParseFlags to skip sections.
Font parseFnt(T)(auto ref in T data, ParseFlags flags = ParseFlags.none) pure
		if (isSomeString!T || is(T == ubyte[]))
{
	Font font;

	ubyte[] buffer;
	ubyte currentBlock = 0;
	uint blockLength = 0;
	uint skipRemaining = 0;
	bool parseFontName = false;
	size_t curPage = 0;
	uint pageTotal = 0;
	if (data[0 .. 3].getReadonlyBytes == "BMF".representation)
	{
		font.type = FontType.binary;
		font.fileVersion = data[3];
		if (font.fileVersion != 3)
			throw new InvalidFormatException(
					"Font version is not supported: " ~ font.fileVersion.to!string);
	}
	else if (data[0 .. 4].getReadonlyBytes == "<?xm".representation)
		font.type = FontType.xml;
	else
		font.type = FontType.text;
	final switch (font.type)
	{
	case FontType.binary:
		foreach (c; data)
		{
			if (skipRemaining > 0)
			{
				skipRemaining--;
				continue;
			}
			buffer ~= cast(ubyte) c;
			switch (currentBlock)
			{
			case ubyte.max: // to be determined
				if (buffer.length == 5)
				{
					currentBlock = buffer[0];
					blockLength = littleEndianToNative!uint(buffer[1 .. 5]);
					buffer.length = 0;

					if ((flags & ParseFlags.skipInfo && currentBlock == 1)
							|| (flags & ParseFlags.skipCommon && currentBlock == 2)
							|| (flags & ParseFlags.skipPages && currentBlock == 3)
							|| (flags & ParseFlags.skipKerning && currentBlock == 5))
					{
						skipRemaining = blockLength;
						currentBlock = ubyte.max;
					}
				}
				else if (buffer.length > 5)
					throw new InvalidFormatException();
				break;
			case 0: // header
				if (buffer.length == 4)
				{

					currentBlock = ubyte.max;
					buffer.length = 0;
				}
				else if (buffer.length > 4)
					throw new InvalidFormatException();
				break;
			case 1: // info
				if (parseFontName)
				{
					if (buffer[$ - 1] == 0)
					{
						currentBlock = ubyte.max;
						buffer.length = 0;
						parseFontName = false;
					}
					else
						font.info.fontName ~= cast(char) buffer[$ - 1];
				}
				else
				{
					if (buffer.length == 14)
					{
						font.info.fontSize = littleEndianToNative!short(buffer[0 .. 2]);
						font.info.bitField = buffer[2];
						font.info.charSet = buffer[3];
						font.info.stretchH = littleEndianToNative!ushort(buffer[4 .. 6]);
						font.info.aa = buffer[6];
						font.info.padding = buffer[7 .. 11];
						font.info.spacing = buffer[11 .. 13];
						font.info.outline = buffer[13];
						parseFontName = true;
					}
					else if (buffer.length > 14)
						throw new InvalidFormatException();
				}
				break;
			case 2: // common
				if (buffer.length == 15)
				{
					font.common.lineHeight = littleEndianToNative!ushort(buffer[0 .. 2]);
					font.common.base = littleEndianToNative!ushort(buffer[2 .. 4]);
					font.common.scaleW = littleEndianToNative!ushort(buffer[4 .. 6]);
					font.common.scaleH = littleEndianToNative!ushort(buffer[6 .. 8]);
					font.common.pages = littleEndianToNative!ushort(buffer[8 .. 10]);
					if ((flags & ParseFlags.skipPages) == 0)
						font.pages.length = font.common.pages;
					font.common.bitField = buffer[10];
					font.common.alphaChnl = cast(ChannelType) buffer[11];
					font.common.redChnl = cast(ChannelType) buffer[12];
					font.common.greenChnl = cast(ChannelType) buffer[13];
					font.common.blueChnl = cast(ChannelType) buffer[14];
					currentBlock = ubyte.max;
					buffer.length = 0;
				}
				else if (buffer.length > 15)
					throw new InvalidFormatException();
				break;
			case 3: // pages
				if (pageTotal > blockLength)
					throw new Exception("Parse error. Please report!");
				if (buffer[$ - 1] == 0)
				{
					font.pages[curPage] = cast(string) buffer[0 .. $ - 1].idup;
					curPage++;
					pageTotal += buffer.length;
					buffer.length = 0;
				}
				if (pageTotal == blockLength)
				{
					assert(buffer.length == 0,
						"String ended wrong! Still in buffer: " ~ buffer.to!string);
					currentBlock = ubyte.max;
					buffer.length = 0;
					break;
				}
				break;
			case 4: // chars
				if (buffer.length == 20)
				{
					Font.Char charInfo;
					charInfo.id = cast(dchar) littleEndianToNative!uint(buffer[0 .. 4]);
					charInfo.x = littleEndianToNative!ushort(buffer[4 .. 6]);
					charInfo.y = littleEndianToNative!ushort(buffer[6 .. 8]);
					charInfo.width = littleEndianToNative!ushort(buffer[8 .. 10]);
					charInfo.height = littleEndianToNative!ushort(buffer[10 .. 12]);
					charInfo.xoffset = littleEndianToNative!short(buffer[12 .. 14]);
					charInfo.yoffset = littleEndianToNative!short(buffer[14 .. 16]);
					charInfo.xadvance = littleEndianToNative!short(buffer[16 .. 18]);
					charInfo.page = buffer[18];
					charInfo.chnl = cast(Channels) buffer[19];
					font.chars ~= charInfo;
					buffer.length = 0;
				}
				else if (buffer.length > 20)
					throw new Exception("Skipped some bytes. Please report.");
				if (font.chars.length == blockLength / 20)
				{
					currentBlock = ubyte.max;
					buffer.length = 0;
					break;
				}
				break;
			case 5: // kernings
				if (buffer.length == 10)
				{
					Font.Kerning kerning;
					kerning.first = cast(dchar) littleEndianToNative!uint(buffer[0 .. 4]);
					kerning.second = cast(dchar) littleEndianToNative!uint(buffer[4 .. 8]);
					kerning.amount = littleEndianToNative!short(buffer[8 .. 10]);
					font.kernings ~= kerning;
					buffer.length = 0;
				}
				else if (buffer.length > 20)
					throw new Exception("Skipped some bytes. Please report.");
				if (font.kernings.length == blockLength / 10)
				{
					currentBlock = ubyte.max;
					buffer.length = 0;
					break;
				}
				break;
			default:
				throw new InvalidFormatException("Unknown block: " ~ currentBlock.to!string);
			}
		}
		break;
	case FontType.text:
		foreach (line; (cast(const(char)[]) data).splitLines)
		{
			string type;
			foreach (c; line)
			{
				if (isWhite(c))
					break;
				type ~= c;
			}
			line = line[type.length .. $].stripLeft;
			const(char)[][2][] arguments = line.getArguments();
			ushort pageID = 0;
			switch (type)
			{
			case "info":
				if (flags & ParseFlags.skipInfo)
					break;
				foreach (argument; arguments)
				{
					switch (argument[0])
					{
					case "face":
						font.info.fontName = argument[1].idup;
						break;
					case "size":
						font.info.fontSize = argument[1].to!short;
						break;
					case "bold":
						font.info.bitField |= argument[1] == "1" ? 0b0001_0000 : 0;
						break;
					case "italic":
						font.info.bitField |= argument[1] == "1" ? 0b0010_0000 : 0;
						break;
					case "charset":
						// TODO
						break;
					case "unicode":
						font.info.bitField |= argument[1] == "1" ? 0b0100_0000 : 0;
						break;
					case "stretchH":
						font.info.stretchH = argument[1].to!ushort;
						break;
					case "smooth":
						font.info.bitField |= argument[1] == "1" ? 0b1000_0000 : 0;
						break;
					case "aa":
						font.info.aa = cast(ubyte) argument[1].to!uint;
						break;
					case "padding":
						font.info.padding = ("[" ~ argument[1] ~ "]").to!(ubyte[]);
						break;
					case "spacing":
						font.info.spacing = ("[" ~ argument[1] ~ "]").to!(ubyte[]);
						break;
					case "outline":
						font.info.outline = cast(ubyte) argument[1].to!uint;
						break;
					default:
						throw new InvalidFormatException("Unkown info argument: " ~ argument[0].to!string);
					}
				}
				break;
			case "common":
				if (flags & ParseFlags.skipCommon)
					break;
				foreach (argument; arguments)
				{
					switch (argument[0])
					{
					case "lineHeight":
						font.common.lineHeight = argument[1].to!ushort;
						break;
					case "base":
						font.common.base = argument[1].to!ushort;
						break;
					case "scaleW":
						font.common.scaleW = argument[1].to!ushort;
						break;
					case "scaleH":
						font.common.scaleH = argument[1].to!ushort;
						break;
					case "pages":
						font.common.pages = argument[1].to!ushort;
						font.pages.length = font.common.pages;
						break;
					case "packed":
						font.common.bitField |= argument[1] == "1" ? 0b0000_0001 : 0;
						break;
					case "alphaChnl":
						font.common.alphaChnl = cast(ChannelType) argument[1].to!uint;
						break;
					case "redChnl":
						font.common.redChnl = cast(ChannelType) argument[1].to!uint;
						break;
					case "greenChnl":
						font.common.greenChnl = cast(ChannelType) argument[1].to!uint;
						break;
					case "blueChnl":
						font.common.blueChnl = cast(ChannelType) argument[1].to!uint;
						break;
					default:
						throw new InvalidFormatException("Unkown common argument: " ~ argument[0].to!string);
					}
				}
				break;
			case "page":
				if (flags & ParseFlags.skipPages)
					break;
				foreach (argument; arguments)
				{
					switch (argument[0])
					{
					case "id":
						pageID = argument[1].to!ushort;
						break;
					case "file":
						font.pages[pageID] = argument[1].idup;
						break;
					default:
						throw new InvalidFormatException("Unkown page argument: " ~ argument[0].to!string);
					}
				}
				break;
			case "chars":
				if (arguments.length != 1)
					throw new InvalidFormatException();
				font.chars.reserve(arguments[0][1].to!int);
				break;
			case "char":
				Font.Char currChar;
				foreach (argument; arguments)
				{
					switch (argument[0])
					{
					case "id":
						currChar.id = cast(dchar) argument[1].to!uint;
						break;
					case "x":
						currChar.x = argument[1].to!ushort;
						break;
					case "y":
						currChar.y = argument[1].to!ushort;
						break;
					case "width":
						currChar.width = argument[1].to!ushort;
						break;
					case "height":
						currChar.height = argument[1].to!ushort;
						break;
					case "xoffset":
						currChar.xoffset = argument[1].to!short;
						break;
					case "yoffset":
						currChar.yoffset = argument[1].to!short;
						break;
					case "xadvance":
						currChar.xadvance = argument[1].to!short;
						break;
					case "page":
						currChar.page = cast(ubyte) argument[1].to!uint;
						break;
					case "chnl":
						currChar.chnl = cast(Channels) argument[1].to!uint;
						break;
					default:
						throw new InvalidFormatException(
							"Unkown char argument: " ~ argument.to!string);
					}
				}
				font.chars ~= currChar;
				break;
			case "kernings":
				if (flags & ParseFlags.skipKerning)
					break;
				if (arguments.length != 1)
					throw new InvalidFormatException();
				font.kernings.reserve(arguments[0][1].to!int);
				break;
			case "kerning":
				if (flags & ParseFlags.skipKerning)
					break;
				Font.Kerning kerning;
				foreach (argument; arguments)
				{
					switch (argument[0])
					{
					case "first":
						kerning.first = cast(dchar) argument[1].to!uint;
						break;
					case "second":
						kerning.second = cast(dchar) argument[1].to!uint;
						break;
					case "amount":
						kerning.amount = argument[1].to!short;
						break;
					default:
						throw new InvalidFormatException("Unkown kerning argument: " ~ argument[0].to!string);
					}
				}
				font.kernings ~= kerning;
				break;
			default:
				throw new InvalidFormatException();
			}
		}
		break;
	case FontType.xml:
		throw new Exception("xml parsing is not yet implemented");
	case FontType.none:
		throw new InvalidFormatException();
	}

	return font;
}

private const(char)[][2][] getArguments(ref scope const(char)[] line) pure @safe
{
	const(char)[][2][] args;
	const(char)[][2] currArg = "";
	bool inString = false;
	bool escape = false;
	bool isKey = true;
	foreach (c; line)
	{
		if (isKey)
		{
			if (c == '=')
			{
				isKey = false;
			}
			else if (c.isWhite && currArg[0].strip.length)
			{
				currArg[0] = currArg[0].strip;
				currArg[1] = currArg[1].strip;
				args ~= currArg;
				isKey = true;
				currArg[0] = "";
				currArg[1] = "";
			}
			else
				currArg[0] ~= c;
		}
		else
		{
			if (inString)
			{
				if (escape)
				{
					currArg[1] ~= c;
					escape = false;
				}
				else
				{
					if (c == '"')
						inString = false;
					else if (c == '\\')
						escape = true;
					else
					{
						currArg[1] ~= c;
					}
				}
			}
			else
			{
				if (c.isWhite)
				{
					currArg[0] = currArg[0].strip;
					currArg[1] = currArg[1].strip;
					if (currArg[0].length)
					{
						args ~= currArg;
						isKey = true;
						currArg[0] = "";
						currArg[1] = "";
					}
				}
				else if (c == '"')
					inString = true;
				else
					currArg[1] ~= c;
			}
		}
	}
	if (currArg[0].strip.length)
	{
		currArg[0] = currArg[0].strip;
		currArg[1] = currArg[1].strip;
		args ~= currArg;
	}
	return args;
}

///
unittest
{
	auto font = parseFnt(`info face="Roboto" size=32 bold=0 italic=0 charset="" unicode=1 stretchH=100 smooth=1 aa=1 padding=1,1,1,1 spacing=1,1 outline=0
common lineHeight=33 base=26 scaleW=768 scaleH=512 pages=1 packed=0 alphaChnl=0 redChnl=4 greenChnl=4 blueChnl=4
page id=0 file="roboto_txt_0.png"
chars count=2
char id=97   x=383   y=452   width=15    height=16    xoffset=0     yoffset=11    xadvance=15    page=0  chnl=15
char id=98   x=554   y=239   width=16    height=22    xoffset=0     yoffset=5     xadvance=15    page=0  chnl=15
kernings count=1
kerning first=97  second=98  amount=-1  
`);
	assert(font.info.aa == 1);
	assert(font.info.bitField == 0b1100_0000);
	assert(font.info.charSet == 0);
	assert(font.info.fontName == "Roboto");
	assert(font.info.fontSize == 32);
	assert(font.info.padding == [1, 1, 1, 1]);
	assert(font.info.spacing == [1, 1]);
	assert(font.info.stretchH == 100);

	assert(font.common.alphaChnl == ChannelType.glyph);
	assert(font.common.base == 26);
	assert(font.common.bitField == 0b0000_0000);
	assert(font.common.blueChnl == ChannelType.one);
	assert(font.common.greenChnl == ChannelType.one);
	assert(font.common.lineHeight == 33);
	assert(font.common.pages == 1);
	assert(font.common.redChnl == ChannelType.one);
	assert(font.common.scaleH == 512);
	assert(font.common.scaleW == 768);

	assert(font.chars.length == 2);
	assert(font.chars[0].chnl == Channels.all);
	assert(font.chars[0].height == 16);
	assert(font.chars[0].id == 'a');
	assert(font.chars[0].page == 0);
	assert(font.chars[0].width == 15);
	assert(font.chars[0].x == 383);
	assert(font.chars[0].xadvance == 15);
	assert(font.chars[0].xoffset == 0);
	assert(font.chars[0].y == 452);
	assert(font.chars[0].yoffset == 11);

	assert(font.chars[1].chnl == Channels.all);
	assert(font.chars[1].height == 22);
	assert(font.chars[1].id == 'b');
	assert(font.chars[1].page == 0);
	assert(font.chars[1].width == 16);
	assert(font.chars[1].x == 554);
	assert(font.chars[1].xadvance == 15);
	assert(font.chars[1].xoffset == 0);
	assert(font.chars[1].y == 239);
	assert(font.chars[1].yoffset == 5);

	assert(font.kernings.length == 1);
	assert(font.kernings[0].first == 'a');
	assert(font.kernings[0].second == 'b');
	assert(font.kernings[0].amount == -1);
}

@system unittest
{
	import std.file;

	auto binary = parseFnt(cast(ubyte[]) read("test/roboto.fnt"));
	auto text = parseFnt(readText("test/roboto_txt.fnt"));
	assert(binary.info == text.info);
	assert(binary.common == text.common);
	assert(binary.kernings == text.kernings);
	assert(binary.chars == text.chars);
	assert(binary.type != text.type);
}

@system unittest
{
	import std.file;

	auto binary = parseFnt(cast(ubyte[]) read("test/roboto.fnt"));
	auto text = parseFnt(parseFnt(readText("test/roboto_txt.fnt")).toString());
	assert(binary.info == text.info);
	assert(binary.common == text.common);
	assert(binary.kernings == text.kernings);
	assert(binary.chars == text.chars);
	assert(binary.type != text.type);
}

@system unittest
{
	import std.file;

	auto binary = parseFnt(parseFnt(cast(ubyte[]) read("test/roboto.fnt")).toBinary());
	auto text = parseFnt(readText("test/roboto_txt.fnt"));
	assert(binary.info == text.info);
	assert(binary.common == text.common);
	assert(binary.kernings == text.kernings);
	assert(binary.chars == text.chars);
	assert(binary.type != text.type);
}
