module d_downloader.retry;

ubyte[] downloadWithRetries(ubyte[] delegate() download)
{
    import core.thread : Thread;
    import core.time : dur;
    enum retryDelays = [1, 5, 10];
    Throwable lastError;
    foreach(attempt; 0 .. retryDelays.length + 1)
    {
        if(attempt)
            Thread.sleep(dur!"seconds"(retryDelays[attempt - 1]));
        try
        {
            ubyte[] content = download();
            if(content.length)
                return content;
        }
        catch(Exception e)
            lastError = e;
    }
    if(lastError !is null)
        throw lastError;
    return null;
}
