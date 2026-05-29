module redub.misc.apple_icon; import std.path;

struct IcnsHeader
{
    char[4] magic = "icns";
    uint size = 8;
}
struct IcnsChunk
{
    char[4] type;
    uint size;
    ubyte[] data;
}

/**
*   Types with needsProcessing are those which can't be raw png directly. Applied to 16x16 and 32x32 non 2x images.
*   They get the icons RLE compression.
*/
private char[4] getType(uint size, bool is2X, out bool needsProcessing)
{
    if(is2X)
    {
        switch(size)
        {
            case 32:   return "ic11";
            case 64:   return "ic12";
            case 128:  return "ic07";
            case 256:  return "ic13";
            case 512:  return "ic14";
            case 1024: return "ic10";
            default: return (char[4]).init;
        }
    }
    else switch(size)
    {
        case 16:   needsProcessing = true; return "is32";
        case 32:   needsProcessing = true; return "il32";
        case 64:   return "ic12";
        case 128:  return "ic07";
        case 256:  return "ic08";
        case 512:  return "ic09";
        case 1024: return "ic10";
        default: return (char[4]).init;
    }
}

ubyte[] getAppleICNSData(const string[] icons, out string error)
{
    import std.array;
    import std.bitmanip:nativeToBigEndian;
    import std.conv:to;
    IcnsHeader header;

    Appender!(ubyte[]) fileData = appender!(ubyte[]);
    IcnsChunk[] chunks;
    
    foreach(iconPath; icons)
    {
        import arsd.png;
        import std.file;
        import std.algorithm.searching:canFind;
        IcnsChunk chunk;
        chunk.data = cast(ubyte[]) std.file.read(iconPath);
        auto pngHeader = getHeader(readPng(chunk.data));
        if(pngHeader.width != pngHeader.height)
        {
            error = "Error: Width and Height must be the same in file "~iconPath;
            return null;
        }
        bool needsProcessing;
        chunk.type = getType(pngHeader.width, iconPath.canFind("@2x"),needsProcessing);
        if(chunk.type == (char[4]).init)
        {
            error = "Error: File "~iconPath~" has an unsupported size. Supported sizes are: 
16x16, 32x32, 64x64, 128x128, 256x256, 512x512, 1024x1024
";
            return null;
        }
        if(needsProcessing)
        {
            TrueColorImage img = readPngFromBytes(chunk.data).getAsTrueColorImage;
            IcnsChunk[2] dualChunk = addRGB24AndMask(chunk.type, img.imageData.bytes, pngHeader.width);
            header.size+= dualChunk[0].size + dualChunk[1].size;
            chunks~= dualChunk;
        }
        else
        {
            chunk.size = chunk.data.length.to!uint + 8;
            header.size+= chunk.size;
            chunks~= chunk;
        }
    }
    
    fileData~= cast(ubyte[])header.magic;      
    fileData~= cast(ubyte[])nativeToBigEndian(header.size);
    foreach(chunk; chunks)
    {
        fileData~= cast(ubyte[])chunk.type[];
        fileData~= cast(ubyte[])nativeToBigEndian(chunk.size);
        fileData~= chunk.data;
    }
    return fileData.data;
}

private ubyte[] icnsRLE(const(ubyte)[] input)
{
    import std.array : appender, staticArray;
    import std.algorithm : min;

    auto output = appender!(ubyte[]);
    size_t i = 0;

    while(i < input.length)
    {
        size_t run = 1;
        while(i + run < input.length && run < 130 && input[i + run] == input[i])
            run++;

        if(run >= 3)
        {
            output.put([cast(ubyte)(0x80 + run - 3), cast(ubyte)input[i]].staticArray[]);
            i += run;
            continue;
        }

        immutable start = i;

        while(i < input.length && i - start < 128)
        {
            run = 1;
            while(i + run < input.length && run < 130 && input[i + run] == input[i])
                run++;

            if(run >= 3)
                break;

            auto take = min(run, 128 - (i - start));
            i += take;

            if(take < run)
                break;
        }

        auto len = i - start;
        output.put(cast(ubyte)(len - 1));
        output.put(input[start..i]);
    }

    return output.data;
}

private IcnsChunk[2] addRGB24AndMask(
    char[4] rgbMask,
    const(ubyte)[] rgba,
    uint size
)
{
    import std.array : appender;
    import std.exception;
    import std.conv : to;
    enforce(size*size <= 1024, "Can't deal with image resolution bigger than 32x32");
    uint length = size*size;
    ubyte[1024] r = void;
    ubyte[1024] g = void;
    ubyte[1024] b = void;
    ubyte[1024] a = void;


    foreach(i; 0 .. length)
    {
        auto base = i * 4;
        r[i] = (rgba[base + 0]);
        g[i] = (rgba[base + 1]);
        b[i] = (rgba[base + 2]);
        a[i] = (rgba[base + 3]);
    }


    IcnsChunk rgbChunk;
    rgbChunk.type = rgbMask;
    rgbChunk.data = icnsRLE(r[0..length]) ~ icnsRLE(g[0..length]) ~ icnsRLE(b[0..length]);
    rgbChunk.size = rgbChunk.data.length.to!uint + 8;

    IcnsChunk maskChunk;
    maskChunk.type = rgbMask == "is32" ? "s8mk" : "l8mk";
    maskChunk.data = a[0..length].dup; // alpha mask
    maskChunk.size = maskChunk.data.length.to!uint + 8;
    
    return [rgbChunk, maskChunk];
}