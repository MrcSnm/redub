module d_downloader.curl;
version(Posix):
import std.net.curl : HTTP;

private void httpOnce(string url,
    scope void delegate(ubyte[] data) onData,
    scope void delegate(size_t received, size_t total) onProgress = null)
{
    import d_downloader.retry : NonRetryableException;
    import core.time : dur;
    import std.conv : to;
    import std.string : icmp, strip;

    HTTP http = HTTP(url);
    http.connectTimeout = dur!"seconds"(10);
    http.dataTimeout = dur!"seconds"(30);

    size_t total, received;
    http.onReceiveHeader = (in char[] key, in char[] value)
    {
        if(icmp(key, "Content-Length") == 0)
            total = strip(value).to!size_t;
    };
    http.onReceive = (ubyte[] data)
    {
        onData(data);
        received += data.length;
        if(onProgress)
            onProgress(received, total);
        return data.length;
    };
    http.perform();
    ushort code = http.statusLine.code;
    if(code >= 400)
    {
        string msg = "HTTP " ~ code.to!string ~ " " ~ http.statusLine.reason;
        if(code >= 500 || code == 408 || code == 429)
            throw new Exception(msg);
        throw new NonRetryableException(msg);
    }
}

ubyte[] downloadToBuffer(string file)
{
    import d_downloader.retry : downloadWithRetries;

    ubyte[] buffer;
    size_t processed;
    downloadWithRetries({
        buffer.length = 0;
        processed = 0;
        httpOnce(file, (ubyte[] data)
        {
            if(buffer.length < processed + data.length)
                buffer.length = processed + data.length;
            buffer[processed .. processed + data.length] = data;
            processed += data.length;
        });
        if(processed == 0)
            throw new Exception("Empty response received.");
    });
    return buffer;
}

void downloadToFile(string url, string targetFile)
{
    downloadToFile(url, targetFile, null);
}

void downloadToFile(string url, string targetFile,
    void delegate(size_t received, size_t total) onProgress)
{
    import d_downloader.retry : downloadWithRetries;
    import std.file : getSize;
    import std.stdio : File;

    downloadWithRetries({
        File file = File(targetFile, "wb");
        scope(exit) file.close();
        httpOnce(url, (ubyte[] data) => file.rawWrite(data), onProgress);
        if(getSize(targetFile) == 0)
            throw new Exception("Empty response received.");
    });
}
