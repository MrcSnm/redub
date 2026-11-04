module redub.extensions.serve;

version(RedubCLI):

import redub.logging;
import std.socket : Socket;

private struct ServeOptions
{
    @("Port to listen on")
    ushort port = 8080;

    @("Host to bind")
    string host = "127.0.0.1";

    @("Do not open the default browser")
    @("no-open")
    bool noOpen;
}

private void openBrowser(string url)
{
    import redub.misc.find_executable : findExecutable;
    import std.process : spawnProcess;

    version(Windows)
    {
        try
            spawnProcess(["cmd", "/c", "start", "", url]);
        catch(Exception e)
            warn("Could not open the browser: ", e.msg);
    }
    else
    {
        version(OSX)
            string opener = "open";
        else version(Posix)
            string opener = "xdg-open";  
        if(!findExecutable(opener).length)
        {
            warn("Could not open the browser: '", opener, "' was not found. Open ", url, " manually.");
            return;
        }
        try
            spawnProcess([opener, url]);
        catch(Exception e)
            warn("Could not open the browser: ", e.msg);
    } 
}

private int hexValue(char c) pure nothrow @safe
{
    if(c >= '0' && c <= '9') return c - '0';
    if(c >= 'a' && c <= 'f') return c - 'a' + 10;
    if(c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

private string urlDecode(string input)
{
    char[] outBuffer;
    for(size_t i = 0; i < input.length; i++)
    {
        if(input[i] == '%' && i + 2 < input.length)
        {
            int high = hexValue(input[i + 1]);
            int low = hexValue(input[i + 2]);
            if(high >= 0 && low >= 0)
            {
                outBuffer ~= cast(char)((high << 4) | low);
                i += 2;
                continue;
            }
        }
        outBuffer ~= input[i];
    }
    return cast(string) outBuffer;
}

private string mimeType(string path)
{
    import std.path : extension;
    switch(extension(path))
    {
        case ".wasm": return "application/wasm";
        case ".js", ".mjs": return "text/javascript";
        case ".html", ".htm": return "text/html; charset=utf-8";
        case ".css": return "text/css; charset=utf-8";
        case ".json": return "application/json";
        case ".png": return "image/png";
        case ".jpg", ".jpeg": return "image/jpeg";
        case ".svg": return "image/svg+xml";
        default: return "application/octet-stream";
    }
}

private string jsString(string value)
{
    import std.string : replace;
    return "\"" ~ value.replace("\\", "\\\\").replace("\"", "\\\"") ~ "\"";
}

///Whether to use the sibling Emscripten glue instead of redub's WASI loader.
///The build exports the resolved target, so scanning the wasm is only needed
///for manually invoked `redub serve`.
private bool usesEmscriptenGlue(string wasmPath)
{
    import redub.parsers.environment : getEnvVariable;
    import std.string : indexOf;

    string arch = getEnvVariable("REDUB_TARGET_ARCH");
    if(arch.length)
        return arch.indexOf("emscripten") != -1;
    return wasmImportsEnv(wasmPath);
}

///Whether the wasm module imports Emscripten's `env` module.
private bool wasmImportsEnv(string wasmPath)
{
    import std.file : exists, read;

    if(!exists(wasmPath))
        return false;
    auto data = cast(const(ubyte)[]) read(wasmPath);
    if(data.length < 8 || data[0] != 0x00 || data[1] != 0x61
        || data[2] != 0x73 || data[3] != 0x6d)
        return false;

    size_t pos = 8;
    while(pos < data.length)
    {
        ubyte id = data[pos++];
        size_t size, shift;
        while(pos < data.length)
        {
            ubyte b = data[pos++];
            size |= (cast(size_t)(b & 0x7f)) << shift;
            if(!(b & 0x80))
                break;
            shift += 7;
        }
        if(pos + size > data.length)
            return false;
        if(id == 2)
        {
            ///shortcut: scans the import section for the "env" module name;
            ///upgrade to a full wasm parser if field-name collisions matter.
            auto payload = data[pos .. pos + size];
            if(payload.length >= 4)
                foreach(i; 0 .. payload.length - 3)
                    if(payload[i] == 3 && payload[i + 1] == 'e'
                        && payload[i + 2] == 'n' && payload[i + 3] == 'v')
                        return true;
            return false;
        }
        pos += size;
    }
    return false;
}

private immutable string wasiShim = import("redub/extensions/wasi_shim.js");
private immutable string redubIcon = import("redub/extensions/redub.png");

private string loaderScript(string wasmName)
{
    string target = wasmName.length ? jsString(wasmName) : "null";
    return
        "const status = document.getElementById('redub-status');\n"
        ~ "const output = document.getElementById('redub-output');\n"
        ~ "const wasmUrl = " ~ target ~ ";\n"
        ~ "const env = await import('/env.js').catch(() => ({}));\n"
        ~ wasiShim ~ "\n"
        ~ "try {\n"
        ~ "  if (!wasmUrl) throw new Error('No .wasm file found in the served directory');\n"
        ~ "  const response = await fetch(wasmUrl);\n"
        ~ "  if (!response.ok) throw new Error(response.status + ' ' + response.statusText);\n"
        ~ "  const { instance } = await WebAssembly.instantiateStreaming(response, { env, wasi_snapshot_preview1: wasi });\n"
        ~ "  wasiMemory = instance.exports.memory;\n"
        ~ "  window.redubWasm = instance;\n"
        ~ "  const exports = instance.exports;\n"
        ~ "  if (typeof exports._start === 'function') exports._start();\n"
        ~ "  else if (typeof exports.main === 'function') exports.main();\n"
        ~ "  if (status) status.textContent = 'wasm loaded';\n"
        ~ "} catch (e) {\n"
        ~ "  if (e && e.wasiExit !== undefined) {\n"
        ~ "    if (status) status.textContent = 'wasm exited with code ' + e.wasiExit;\n"
        ~ "  } else {\n"
        ~ "    console.error(e);\n"
        ~ "    if (status) status.textContent = 'wasm error: ' + e.message;\n"
        ~ "  }\n"
        ~ "}\n";
}

private string htmlEscape(string value)
{
    import std.string : replace;
    return value.replace("&", "&amp;").replace("\"", "&quot;")
        .replace("<", "&lt;").replace(">", "&gt;");
}

private string indexHtml(string scriptName = null)
{
    if(scriptName.length)
    {
        string script = htmlEscape(scriptName);
        return
            "<!doctype html>\n"
            ~ "<meta charset=\"utf-8\">\n"
            ~ "<title>redub web</title>\n"
            ~ "<link rel=\"icon\" type=\"image/png\" href=\"/favicon.png\">\n"
            ~ "<body style=\"font-family:monospace;background:#111;color:#ddd\">\n"
            ~ "<h1>redub web</h1>\n"
            ~ "<p id=\"redub-status\">loading…</p>\n"
            ~ "<pre id=\"redub-output\" style=\"white-space:pre-wrap\"></pre>\n"
            ~ "<canvas id=\"redub-canvas\" width=\"640\" height=\"360\"></canvas>\n"
            ~ "<script>\n"
            ~ "var redubStatus = document.getElementById('redub-status');\n"
            ~ "var redubOutput = document.getElementById('redub-output');\n"
            ~ "var Module = {\n"
            ~ "  print: function(t) { if (redubStatus) redubStatus.textContent = 'wasm loaded'; if (redubOutput) redubOutput.textContent += t + '\\n'; },\n"
            ~ "  printErr: function(t) { console.error(t); if (redubOutput) redubOutput.textContent += t + '\\n'; },\n"
            ~ "  onRuntimeInitialized: function() { if (redubStatus) redubStatus.textContent = 'wasm loaded'; },\n"
            ~ "  onExit: function(code) { if (redubStatus) redubStatus.textContent = code ? 'wasm exited with code ' + code : 'wasm loaded'; }\n"
            ~ "};\n"
            ~ "</script>\n"
            ~ "<script src=\"/" ~ script ~ "\"></script>\n"
            ~ "</body>\n";
    }
    return
        "<!doctype html>\n"
        ~ "<meta charset=\"utf-8\">\n"
        ~ "<title>redub web</title>\n"
        ~ "<link rel=\"icon\" type=\"image/png\" href=\"/favicon.png\">\n"
        ~ "<body style=\"font-family:monospace;background:#111;color:#ddd\">\n"
        ~ "<h1>redub web</h1>\n"
        ~ "<p id=\"redub-status\">loading…</p>\n"
        ~ "<pre id=\"redub-output\" style=\"white-space:pre-wrap\"></pre>\n"
        ~ "<canvas id=\"redub-canvas\" width=\"640\" height=\"360\"></canvas>\n"
        ~ "<script type=\"module\" src=\"/redub.js\"></script>\n"
        ~ "</body>\n";
}

private void sendResponse(Socket conn, int status, string statusText,
    string contentType, const(ubyte)[] body, bool headOnly)
{
    import std.conv : to;
    string header = "HTTP/1.1 " ~ status.to!string ~ " " ~ statusText ~ "\r\n"
        ~ "Content-Type: " ~ contentType ~ "\r\n"
        ~ "Content-Length: " ~ body.length.to!string ~ "\r\n"
        ~ "Cache-Control: no-store\r\n"
        ~ "Connection: close\r\n\r\n";
    conn.send(cast(const(void)[]) header);
    if(!headOnly && body.length)
        conn.send(cast(const(void)[]) body);
}

private void serveConnection(Socket conn, string root, string wasmName, string scriptName)
{
    import std.array : split;
    import std.file : exists, isDir, read;
    import std.path : buildNormalizedPath, dirName, isAbsolute;
    import std.string : indexOf, replace, split;

    ubyte[8192] buffer;
    ptrdiff_t received = conn.receive(buffer);
    if(received <= 0)
        return;
    string request = cast(string) buffer[0 .. cast(size_t) received];
    auto lineEnd = request.indexOf("\r\n");
    string requestLine = lineEnd >= 0 ? request[0 .. lineEnd] : request;
    string[] parts = requestLine.split(" ");
    if(parts.length < 2)
    {
        sendResponse(conn, 400, "Bad Request", "text/plain", cast(const(ubyte)[]) "bad request", false);
        return;
    }

    string method = parts[0];
    bool headOnly = method == "HEAD";
    if(method != "GET" && !headOnly)
    {
        sendResponse(conn, 405, "Method Not Allowed", "text/plain", cast(const(ubyte)[]) "method not allowed", headOnly);
        return;
    }

    string urlPath = parts[1];
    auto query = urlPath.indexOf('?');
    if(query >= 0) urlPath = urlPath[0 .. query];
    string path = urlDecode(urlPath);

    if(path == "/" || path == "/index.html")
    {
        string index = buildNormalizedPath(root, "index.html");
        if(exists(index))
        {
            auto body = cast(ubyte[]) read(index);
            sendResponse(conn, 200, "OK", "text/html; charset=utf-8", body, headOnly);
            return;
        }
        auto body = cast(const(ubyte)[]) indexHtml(scriptName);
        sendResponse(conn, 200, "OK", "text/html; charset=utf-8", body, headOnly);
        return;
    }
    if(path == "/redub.js")
    {
        auto body = cast(const(ubyte)[]) loaderScript(wasmName);
        sendResponse(conn, 200, "OK", "text/javascript", body, headOnly);
        return;
    }
    if(path == "/favicon.png" || path == "/favicon.ico")
    {
        auto body = cast(const(ubyte)[]) redubIcon;
        sendResponse(conn, 200, "OK", "image/png", body, headOnly);
        return;
    }

    if(path.length == 0)
    {
        sendResponse(conn, 404, "Not Found", "text/plain", cast(const(ubyte)[]) "not found", headOnly);
        return;
    }
    string relative = path[0] == '/' ? path[1 .. $] : path;
    version(Windows)
        relative = relative.replace("/", "\\");
    if(isAbsolute(relative))
    {
        sendResponse(conn, 404, "Not Found", "text/plain", cast(const(ubyte)[]) "not found", headOnly);
        return;
    }
    string[] segments = relative.split("/");
    foreach(segment; segments)
        if(segment == "..")
        {
            sendResponse(conn, 404, "Not Found", "text/plain", cast(const(ubyte)[]) "not found", headOnly);
            return;
        }
    string target = buildNormalizedPath(root, relative);
    if(!exists(target) || isDir(target))
    {
        sendResponse(conn, 404, "Not Found", "text/plain", cast(const(ubyte)[]) "not found", headOnly);
        return;
    }
    auto body = cast(ubyte[]) read(target);
    sendResponse(conn, 200, "OK", mimeType(target), body, headOnly);
}

int serveMain(string[] args)
{
    import std.file : dirEntries, exists, isDir, SpanMode;
    import redub.buildapi : RedubVersionShort;
    import redub.cli.dub : betterGetopt;
    import std.getopt : defaultGetoptPrinter;
    import std.path : absolutePath, baseName, dirName, extension, relativePath;
    import std.socket;
    import std.string : replace;

    setLogLevel(LogLevel.info);
    ServeOptions opts;
    auto res = betterGetopt(args, opts);
    if(res.helpWanted)
    {
        defaultGetoptPrinter(RedubVersionShort~" serve information:\n\t"
            ~ "Serves a build directory for testing wasm/web builds.\n\t"
            ~ "Generates index.html and redub.js when index.html is absent.\n"
            ~ "The default browser is opened automatically unless --no-open is given.\n\t"
            ~ "Arguments:\n", res.options);
        return 0;
    }

    if(args.length > 2)
    {
        error("Unexpected argument: ", args[2]);
        return 1;
    }
    string root = args.length > 1 ? args[1] : ".";
    if(!exists(root))
    {
        error("Path does not exist: ", root);
        return 1;
    }
    root = absolutePath(root);

    string wasmPath;
    string scriptName;
    if(isDir(root))
    {
        foreach(entry; dirEntries(root, SpanMode.depth))
            if(!entry.isDir && extension(entry.name) == ".wasm")
            {
                wasmPath = entry.name;
                break;
            }
        if(wasmPath.length)
        {
            string sibling = wasmPath[0 .. $ - ".wasm".length] ~ ".js";
            if(usesEmscriptenGlue(wasmPath) && exists(sibling))
                scriptName = baseName(sibling);
        }
    }
    else
    {
        string artifact = root;
        root = dirName(root);
        string ext = extension(artifact);
        if(ext == ".js" || ext == ".mjs")
            scriptName = baseName(artifact);
        else if(ext == ".wasm")
        {
            string sibling = artifact[0 .. $ - ".wasm".length] ~ ".js";
            if(usesEmscriptenGlue(artifact) && exists(sibling))
                scriptName = baseName(sibling);
            else
                wasmPath = artifact;
        }
        else
            wasmPath = artifact;
    }
    string wasmName;
    if(wasmPath.length)
        wasmName = relativePath(wasmPath, root).replace("\\", "/");

    auto listener = new TcpSocket(AddressFamily.INET);
    listener.bind(new InternetAddress(opts.host, opts.port));
    listener.listen(16);
    info("Serving ", root, " at http://", opts.host, ":", opts.port, "/");
    if(wasmName.length)
        info("Wasm: /", wasmName);
    if(scriptName.length)
        info("Script: /", scriptName);
    flush();

    if(!opts.noOpen)
    {
        import std.conv : to;
        string browserHost = opts.host == "0.0.0.0" || opts.host == "::"
            ? "127.0.0.1" : opts.host;
        openBrowser("http://" ~ browserHost ~ ":" ~ opts.port.to!string ~ "/");
    }

    while(true)
    {
        Socket conn = listener.accept();
        scope(exit) conn.close();
        try
            serveConnection(conn, root, wasmName, scriptName);
        catch(Exception e)
            error("HTTP error: ", e.msg);
    }
    return 0;
}
