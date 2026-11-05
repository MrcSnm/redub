module redub.misc.download;

private string formatSize(size_t bytes)
{
    import std.format : format;

    double value = cast(double) bytes;
    string unit = "B";
    foreach(next; ["KiB", "MiB", "GiB", "TiB"])
    {
        if(value < 1024)
            break;
        value /= 1024;
        unit = next;
    }
    return format("%.1f %s", value, unit);
}

void downloadWithProgress(string url, string targetFile)
{
    import d_downloader : downloadToFile;
    import redub.logging : hasLogLevel, LogLevel;

    if(!hasLogLevel(LogLevel.info))
    {
        downloadToFile(url, targetFile);
        return;
    }

    import std.datetime.stopwatch : AutoStart, StopWatch;
    import std.format : format;
    import std.stdio : stderr;

    StopWatch sw = StopWatch(AutoStart.yes);
    long lastMs = -1000;
    size_t lastPercent = size_t.max;
    size_t finalReceived, finalTotal;

    string render(size_t received, size_t total, bool force)
    {
        long ms = sw.peek.total!"msecs";
        size_t percent = total ? received * 100 / total : size_t.max;
        if(!force && ms - lastMs < 100 && percent == lastPercent)
            return null;
        lastMs = ms;
        lastPercent = percent;

        enum barWidth = 30;
        string bar = "[";
        if(total)
        {
            size_t filled = cast(size_t)(received * barWidth / total);
            foreach(i; 0 .. barWidth)
                bar ~= i < filled ? '=' : ' ';
            bar ~= "]";
            return format("%s %3d%% %s / %s", bar, percent,
                formatSize(received), formatSize(total));
        }
        bar ~= "                              ]";
        return format("%s %s", bar, formatSize(received));
    }

    try
        downloadToFile(url, targetFile, (size_t received, size_t total)
        {
            finalReceived = received;
            finalTotal = total;
            string line = render(received, total, false);
            if(line.length)
            {
                stderr.write("\r", line);
                stderr.flush;
            }
        });
    finally
    {
        string line = render(finalReceived, finalTotal, true);
        stderr.write("\r", line, "\n");
        stderr.flush;
    }
}
