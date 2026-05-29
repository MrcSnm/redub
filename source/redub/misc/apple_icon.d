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

private char[4] getType(uint size)
{
    switch(size)
    {
        case 16:   return "icp4";
        case 32:   return "icp5";
        case 48:   return "icp6";
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
        IcnsChunk chunk;
        chunk.data = cast(ubyte[]) std.file.read(iconPath);
        auto pngHeader = getHeader(readPng(chunk.data));
        chunk.type = getType(pngHeader.width);
        chunk.size = chunk.data.length.to!uint + 8;

        if(pngHeader.width != pngHeader.height)
        {
            error = "Error: Width and Height must be the same in file "~iconPath;
            return null;
        }
        if(chunk.type == (char[4]).init)
        {
            error = "Error: File "~iconPath~" has an unsupported size. Supported sizes are: 
16x16, 32x32, 48x48, 128x128, 256x256, 512x512, 1024x1024
";
            return null;
        }
        header.size+= chunk.size;
        chunk.size = *cast(uint*)nativeToBigEndian(chunk.size);
        chunks~= chunk;
    }
    
    header.size = *cast(uint*)nativeToBigEndian(header.size);
        
    fileData~= (cast(ubyte*)&header)[0..IcnsHeader.sizeof];
    foreach(chunk; chunks)
    {
        fileData~= (cast(ubyte*)&chunk)[0..8];
        fileData~= chunk.data;
    }
    return fileData.data;
}