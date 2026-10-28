module d_downloader.curl;
version(Posix):
import std.net.curl;
ubyte[] downloadToBuffer(string file)
{
	import d_downloader.retry : downloadWithRetries;
	return downloadWithRetries({
		HTTP http = HTTP(file);
		ubyte[] temp;
		http.onReceive = (ubyte[] data)
		{
			temp~= data;
			return data.length;
		};
		http.perform();
		return temp;
	});
}
alias downloadToFile = std.net.curl.download;