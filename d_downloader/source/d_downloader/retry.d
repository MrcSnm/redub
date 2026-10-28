module d_downloader.retry;

class NonRetryableException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null)
    {
        super(msg, file, line, nextInChain);
    }
}

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
        {
            if(cast(NonRetryableException)e !is null)
                throw e;
            lastError = e;
        }
    }
    if(lastError !is null)
        throw lastError;
    throw new Exception("Empty response received after retries.");
}
