module redub.misc.file_size_format;

string getFileSizeFormatted(string targetFile)
{
    import std.conv;
    import std.file;

    static struct ByteUnit
    {
        double data;
        string unit;
    }

    static double floorDecimal(double value, ubyte decimals)
    {
        import std.math;
        double factor = pow(10, decimals);

        return floor(value * factor) / factor;
    }

    ByteUnit formatFromBytes(size_t byteCount) @nogc
    {
        double actualResult = byteCount;

        if(actualResult <= 1000)
            return ByteUnit(floorDecimal(actualResult, 2), " B");
        actualResult/= 1000;
        if(actualResult <= 1000)
            return ByteUnit(floorDecimal(actualResult, 2), " KB");
        actualResult/= 1000;
            return ByteUnit(floorDecimal(actualResult, 2), " MB");
        actualResult/= 1000;
        return ByteUnit(floorDecimal(actualResult, 2), " GB");
    }

    try
    {
        ByteUnit b = formatFromBytes(std.file.getSize(targetFile));
        return to!string(b.data)~b.unit;
    }
    catch(Exception e)
    {
        return "File '"~targetFile~"' not found.";
    }
}
