module d_downloader.curl;
version(Posix):
import std.net.curl;
ubyte[] downloadToBuffer(string file)
{
	HTTP http = HTTP(file);
	ubyte[] temp;
	http.onReceive = (ubyte[] data)
	{
		temp~= data;
		return data.length;
	};
	http.perform();
	return temp;
}
alias downloadToFile = std.net.curl.download;