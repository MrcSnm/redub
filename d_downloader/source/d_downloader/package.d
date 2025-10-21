module d_downloader;
version(Windows)
    public import d_downloader.windows;
else
    public import d_downloader.curl;