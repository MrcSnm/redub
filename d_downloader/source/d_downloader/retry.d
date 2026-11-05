module d_downloader.retry;

class NonRetryableException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null)
    {
        super(msg, file, line, nextInChain);
    }
}

void downloadWithRetries(scope void delegate() download)
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
            download();
            return;
        }
        catch(NonRetryableException e)
        {
            throw e;
        }
        catch(Exception e)
        {
            lastError = e;
        }
    }
    if(lastError !is null)
        throw lastError;
    throw new Exception("Download failed.");
}
