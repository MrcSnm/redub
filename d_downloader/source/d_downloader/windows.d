module d_downloader.windows;
version(Windows):
import core.sys.windows.winhttp;

bool download(string link, scope ubyte[] delegate(size_t incomingBytes) bufferSink, scope void delegate(ubyte[] buffer) onDataReceived = null)
{
    import std.utf:toUTF16z;
    import core.sys.windows.windef;
    HINTERNET hSession = WinHttpOpen("D-Downloader/1.0",
        WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
        WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);

    if (!hSession)
        return false;
    scope(exit)
        WinHttpCloseHandle(hSession);

    NetURL url = NetURL(link);

    uint[1] protocols = [WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2];
    WinHttpSetOption(hSession, WINHTTP_OPTION_SECURE_PROTOCOLS, protocols.ptr, protocols.length);
    HINTERNET hConnect = WinHttpConnect(hSession, url.domain.toUTF16z,
        INTERNET_DEFAULT_HTTPS_PORT, 0);
    scope(exit)
        WinHttpCloseHandle(hConnect);

    HINTERNET hRequest = WinHttpOpenRequest(hConnect, "GET", url.object.toUTF16z,
        null, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES,
        WINHTTP_FLAG_SECURE);

    if(hRequest is null)
    {
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

    scope(exit)
        WinHttpCloseHandle(hRequest);

    if (WinHttpSendRequest(hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                           WINHTTP_NO_REQUEST_DATA, 0, 0, 0)
        && WinHttpReceiveResponse(hRequest, null))
    {
        DWORD remainingDataSize = 0;

        do {
            if (!WinHttpQueryDataAvailable(hRequest, &remainingDataSize))
                break;
            if (!remainingDataSize)
                break;

            DWORD dwRead = 0;
            ubyte[] buffer = bufferSink(remainingDataSize);
            assert(buffer.length < DWORD.max, "Buffer sink length is too big.");
            WinHttpReadData(hRequest, buffer.ptr, cast(DWORD)buffer.length, &dwRead);
            if(onDataReceived)
                onDataReceived(buffer);
        } while (remainingDataSize > 0);
    }

    return true;
}

ubyte[] downloadToBuffer(string url)
{
    ubyte[] buffer;
    download(url, (size_t incomingBytes)
    {
        size_t bufferTail = buffer.length;
        buffer.length+= incomingBytes;
        return buffer[bufferTail..$];
    });
    return buffer;
}

void downloadToFile(string url, string targetFile, bool lowMem = false)
{
    import std.stdio;
    import std.file;
    string newFile = targetFile;
    if(exists(targetFile))
        newFile~= ".temp";

    File f = File(newFile, "wb");
    if(lowMem)
    {
        ubyte[4096] buffer;
        download(url, (size_t incomingBytes)
        {
            return incomingBytes > buffer.length ? buffer[0..$] : buffer[0..incomingBytes];
        }, (ubyte[] b)
        {
            f.rawWrite(b);
        });
    }
    else
    {
        ubyte[] buffer = downloadToBuffer(url);
        f.rawWrite(buffer);
    }
    f.close();
    if(newFile != targetFile)
        std.file.rename(newFile, targetFile);
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