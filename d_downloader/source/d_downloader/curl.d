module d_downloader.curl;
version(Posix):
import std.net.curl;
ubyte[] downloadToBuffer(string file)
{
	import d_downloader.retry : downloadWithRetries, NonRetryableException;
	import core.time : dur;
	return downloadWithRetries({
		HTTP http = HTTP(file);
		http.connectTimeout = dur!"seconds"(10);
		http.dataTimeout = dur!"seconds"(30);
		ubyte[] temp;
		http.onReceive = (ubyte[] data)
		{
			temp~= data;
			return data.length;
		};
		http.perform();
		ushort code = http.statusLine.code;
		if(code >= 400)
		{
			import std.conv : to;
			string msg = "HTTP " ~ code.to!string ~ " " ~ http.statusLine.reason;
			if(code >= 500 || code == 408 || code == 429)
				throw new Exception(msg);
			throw new NonRetryableException(msg);
		}
		return temp;
	});
}
alias downloadToFile = std.net.curl.download;