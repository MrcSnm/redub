module redub.misc.win_icon;

/**
*   Courtesy from Adam D. Ruppe and OpenD: https://github.com/opendlang/opend/blob/master/opend/opend.d#L300
*/
string processIcon(string[] filenames, out string errors)
{
    // FIXME: error if target is not windows prolly here instead of in the compiler
    // https://devblogs.microsoft.com/oldnewthing/20120720-00/?p=7083
    // gotta create a Windows resource file. this means:
    /+
        1) if it is a png, convert to ico. ico can be used directly. other formats not supported by simplifiying choice
        2) concat this into a .res file (can skip if unnecessary via timestamps or something but it cheap enough tbh. user can aksi use the .res externally directly if they want)
            2a) res file just has a header https://learn.microsoft.com/en-us/windows/win32/menurc/resourceheader
            2b) other resource file features maybe usable later but for now just doing the one,
        3) pass this file to the linker
    +/
    // see also https://tmpvar.com/articles/png2res/

    // for mac see: https://developer.apple.com/library/archive/documentation/CoreFoundation/Conceptual/CFBundles/BundleTypes/BundleTypes.html#//apple_ref/doc/uid/10000123i-CH101-SW16

    import std.string;
    import std.file;

    static struct Ico {
        const(ubyte)[] icoBytes;
        ubyte imageWidth;
        ubyte imageHeight;
    }
    Ico[] icos;

    foreach(filename; filenames) {
        static import std.file;
        import arsd.png;
        Ico ico;
        ico.icoBytes = cast(ubyte[]) std.file.read(filename);
        auto hdr = getHeader(readPng(ico.icoBytes));
        if(hdr.width > 256 || hdr.height > 256) {
            errors = "Error: only files 256x256 or smaller supported as exe icons";
            return null;
        }
        ico.imageWidth = cast(ubyte) hdr.width;
        ico.imageHeight = cast(ubyte) hdr.height;

        icos ~= ico;
    }

    if(icos.length < 1 || icos.length > 255) {
        errors = "Error: you need to provide a reasonable number of icon variants";
        return null;
    }

    ubyte[] resBytes;

    static struct ResourceHeader {
        align(1):
        uint dataSize;
        uint headerSize;
        ushort typeFirst;
        ushort typeSecond;
        ushort nameFirst;
        ushort nameSecond;
        uint dataVersion;
        ushort memoryFlags;
        ushort languageId;
        uint Version;
        uint characteristics;
    }
    static assert(ResourceHeader.sizeof == 32);

    // create the .res file header  (id #1, type 0, etc)
    resBytes.length = 32;
    resBytes[0 .. 32] = 0;
    resBytes[4] = 0x20;
    resBytes[0x08] = 0xff;
    resBytes[0x09] = 0xff;
    resBytes[0x0c] = 0xff;
    resBytes[0x0d] = 0xff;

    // add the icon data first
    foreach(ushort icoIdx, ico; icos) {
        ResourceHeader rh;
        rh.dataSize = cast(int) ico.icoBytes.length;
        rh.headerSize = cast(int) ResourceHeader.sizeof;
        rh.typeFirst = 0xffff; // indicating typeSecond is an integer instead of this being a 16 bit string
        rh.typeSecond = 3; // RT_ICON
        rh.nameFirst = 0xffff; // indicate integral
        rh.nameSecond = cast(ushort)(2 + icoIdx); // arbitrary ID number to match what we did above
        rh.dataVersion = 0;
        rh.memoryFlags = 0x1010; // MOVABLE (0x10) | DISCARDABLE (0x1000)
        rh.languageId = 0x0409; // English (United States)
        rh.Version = 0;
        rh.characteristics = 0;

        resBytes ~= cast(ubyte[]) ((&rh)[0 .. 1]);
        resBytes ~= ico.icoBytes;
        while(resBytes.length % 4)
            resBytes ~= 0; // pad to DWORD boundary
    }

    // and the icon group directory must follow the data
    static struct GRPICONDIR {
        align(1):
        ushort idReserved;
        ushort idType;
        ushort idCount;
    }
    static struct GRPICONDIRENTRY {
        align(1):
        ubyte bWidth;
        ubyte bHeight;
        ubyte bColorCount;
        ubyte bReserved;
        ushort wPlanes;
        ushort wBitCount;
        uint dwBytesInRes;
        ushort nId;
    }
    // should be 20 bytes for an icon dir with a single entry, do
    // a GRPICONDIR immediately followed by however many GRPICONDIRENTRYs for it

    GRPICONDIR gid;
    gid.idType = 1; // icon
    gid.idCount = cast(ushort) icos.length;

    ResourceHeader rhDir;
    rhDir.dataSize = cast(int) GRPICONDIR.sizeof + cast(int) GRPICONDIRENTRY.sizeof * gid.idCount;
    rhDir.headerSize = cast(int) ResourceHeader.sizeof;
    rhDir.typeFirst = 0xffff;
    rhDir.typeSecond = 0x0e; // RT_GROUP_ICON
    rhDir.nameFirst = 0xffff;
    rhDir.nameSecond = 1; // want the lowest id number possible, so 1, so it becomes the main exe icon
    rhDir.dataVersion = 0;
    rhDir.memoryFlags = 0x1010; // MOVABLE (0x10) | DISCARDABLE (0x1000)
    rhDir.languageId = 0x0409; // English (United States)
    rhDir.Version = 0;
    rhDir.characteristics = 0;

    GRPICONDIRENTRY[] gides;
    foreach(ushort icoIdx, ico; icos) {
        GRPICONDIRENTRY gide;
        gide.bWidth = ico.imageWidth;
        gide.bHeight = ico.imageHeight;
        gide.wPlanes = 1;
        gide.dwBytesInRes = cast(int) ico.icoBytes.length;
        gide.nId = cast(ushort)(2 + icoIdx); // auto-assign some unused id numbers for each piece of icon data
        gides ~= gide;
    }

    resBytes ~= cast(ubyte[]) ((&rhDir)[0 .. 1]);
    resBytes ~= cast(ubyte[]) ((&gid)[0 .. 1]);
    resBytes ~= cast(ubyte[]) gides[];

    while(resBytes.length % 4)
        resBytes ~= 0; // pad to DWORD boundary

    auto resName = getWindowsResourceName(filenames);
    std.file.write(resName, resBytes);
    return resName;
}


string getWindowsResourceName(const string[] iconPaths)
{
    import std.array:join;
    import std.path;
    enum separator = ",";
    if(iconPaths.length > 1)
    {
        string ret = iconPaths[0];
        for(int i = 1; i < iconPaths.length; i++)
            ret~= separator~iconPaths[i].baseName;
        return ret~".res";
    }
    return join(iconPaths, separator)~".res";
}