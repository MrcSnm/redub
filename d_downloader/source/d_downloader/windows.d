module d_downloader.windows;
version(Windows):
import core.sys.windows.winhttp;

private void downloadStream(string link,
    scope void delegate(ubyte[] data) onData,
    scope void delegate(size_t received, size_t total) onProgress = null)
{
    import std.utf : toUTF16z;
    import core.sys.windows.windef;
    import core.sys.windows.winhttp;
    import d_downloader.retry : NonRetryableException;

    HINTERNET hSession = WinHttpOpen("D-Downloader/1.0",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if(!hSession)
        throw new Exception("Could not initialize the WinHTTP session.");
    scope(exit) WinHttpCloseHandle(hSession);
    WinHttpSetTimeouts(hSession, 10_000, 10_000, 30_000, 30_000);

    NetURL parsed = NetURL(link);
    uint[1] protocols = [WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2];
    WinHttpSetOption(hSession, WINHTTP_OPTION_SECURE_PROTOCOLS,
        protocols.ptr, protocols.length);

    HINTERNET hConnect = WinHttpConnect(hSession, parsed.domain.toUTF16z,
        INTERNET_DEFAULT_HTTPS_PORT, 0);
    scope(exit) WinHttpCloseHandle(hConnect);
    HINTERNET hRequest = WinHttpOpenRequest(hConnect, "GET", parsed.object.toUTF16z,
        null, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    if(hRequest is null)
        throwWindowsError();
    scope(exit) WinHttpCloseHandle(hRequest);

    if(!WinHttpSendRequest(hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
        WINHTTP_NO_REQUEST_DATA, 0, 0, 0))
        throwWindowsError();
    if(!WinHttpReceiveResponse(hRequest, null))
        throwWindowsError();

    DWORD statusCode;
    DWORD statusCodeLength = DWORD.sizeof;
    if(WinHttpQueryHeaders(hRequest,
        cast(DWORD)(WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER),
        WINHTTP_HEADER_NAME_BY_INDEX, &statusCode, &statusCodeLength,
        WINHTTP_NO_HEADER_INDEX))
    {
        import std.conv : to;
        if(statusCode >= 500 || statusCode == 408 || statusCode == 429)
            throw new Exception("HTTP " ~ statusCode.to!string);
        if(statusCode >= 400)
            throw new NonRetryableException("HTTP " ~ statusCode.to!string);
    }

    size_t total;
    wchar[256] headerBuffer = void;
    uint headerLength = headerBuffer.length * wchar.sizeof;
    if(WinHttpQueryHeaders(hRequest, WINHTTP_QUERY_CONTENT_LENGTH, null,
        headerBuffer.ptr, &headerLength, null))
    {
        import std.string : strip;
        import std.conv : to;
        total = strip(headerBuffer[0 .. headerLength / wchar.sizeof]).to!size_t;
    }

    ubyte[64 * 1024] chunk;
    size_t received;
    while(true)
    {
        DWORD remaining;
        if(!WinHttpQueryDataAvailable(hRequest, &remaining))
            throwWindowsError();
        if(!remaining)
            break;
        DWORD toRead = cast(DWORD)(remaining > chunk.length ? chunk.length : remaining);
        DWORD read;
        if(!WinHttpReadData(hRequest, chunk.ptr, toRead, &read))
            throwWindowsError();
        if(read)
        {
            onData(chunk[0 .. read]);
            received += read;
            if(onProgress)
                onProgress(received, total);
        }
    }
    if(total && received != total)
    {
        import std.conv : to;
        throw new Exception("Incomplete download: received " ~ received.to!string ~
            " of " ~ total.to!string ~ " bytes.");
    }
}

ubyte[] downloadToBuffer(string url)
{
    import d_downloader.retry : downloadWithRetries;

    ubyte[] buffer;
    size_t processed;
    downloadWithRetries({
        buffer.length = 0;
        processed = 0;
        downloadStream(url, (ubyte[] data)
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

void downloadToFile(string url, string targetFile, bool lowMem = false)
{
    downloadToFile(url, targetFile, cast(void delegate(size_t, size_t)) null);
}

void downloadToFile(string url, string targetFile,
    void delegate(size_t received, size_t total) onProgress)
{
    import std.stdio : File;
    import std.file : exists, getSize, rename;
    import d_downloader.retry : downloadWithRetries;

    string newFile = targetFile;
    if(exists(targetFile))
        newFile ~= ".temp";

    downloadWithRetries({
        File file = File(newFile, "wb");
        scope(exit) file.close();
        downloadStream(url, (ubyte[] data) => file.rawWrite(data), onProgress);
        if(getSize(newFile) == 0)
            throw new Exception("Empty response received.");
    });

    if(newFile != targetFile)
        rename(newFile, targetFile);
}

private void throwWindowsError()
{
    import core.sys.windows.windef;
    import core.sys.windows.winbase;
    DWORD code = GetLastError();
    string msg;
    switch(code)
    {
        case ERROR_WINHTTP_INCORRECT_HANDLE_TYPE:
            msg = `The type of handle supplied is incorrect for this operation.`; break;
        case ERROR_WINHTTP_INTERNAL_ERROR:
            msg = `An internal error has occurred.`; break;
        case ERROR_WINHTTP_INVALID_URL:
            msg = `The URL is invalid.`; break;
        case ERROR_WINHTTP_OPERATION_CANCELLED:
            msg = `The operation was canceled, usually because the handle on which the request was operating was closed before the operation completed.`; break;
        case ERROR_WINHTTP_UNRECOGNIZED_SCHEME:
            msg = `The URL specified a scheme other than "http:" or "https:".`; break;
        case ERROR_NOT_ENOUGH_MEMORY:
            msg = `Not enough memory was available to complete the requested operation. (Windows error code)`; break;
        default:
            wchar* buffer;
            DWORD msgLength = FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM |
                FORMAT_MESSAGE_IGNORE_INSERTS |
                FORMAT_MESSAGE_ALLOCATE_BUFFER, null, code, LANG_NEUTRAL, cast(wchar*)&buffer, 0, null);
            if(msgLength)
            {
                import std.conv:to;
                msg = buffer[0..msgLength].to!string;
                LocalFree(buffer);
            }
            break;
    }
    throw new Exception(msg);

}

private struct NetURL
{
    string protocol;
    string domain;
    string object;

    this(string url)
    {
        import std.algorithm.searching;
        auto protocolIdx = countUntil(url, "://");
        if(protocolIdx != -1)
        {
            protocol = url[0..protocolIdx+3];
            url = url[protocolIdx+3..$];
        }
        auto objectIdx = countUntil(url, "/");
        if(objectIdx == -1)
        {
            object = "/";
            domain = url;
        }
        else
        {
            object = url[objectIdx..$];
            domain = url[0..objectIdx];
        }

    }
}