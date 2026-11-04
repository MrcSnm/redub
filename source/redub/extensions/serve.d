module redub.extensions.serve;

version(RedubCLI):

import redub.logging;
import std.socket : Socket;
import std.stdio;

private struct ServeOptions
{
    string path;
    ushort port = 8080;
    string host = "127.0.0.1";
}

private void serveUsage()
{
    writeln("redub serve [<artifact|dir>] [--port=8080] [--host=127.0.0.1]");
    writeln("Serves a build directory for testing wasm/web builds.");
    writeln("If <artifact> is a .wasm file, its directory is served and a minimal");
    writeln("index.html + redub.js loader is generated when index.html is absent.");
}

private int parseServeOptions(string[] args, ref ServeOptions opts)
{
    import std.conv : to;
    import std.string : startsWith;

    for(size_t i = 1; i < args.length; i++)
    {
        string arg = args[i];
        if(arg == "--help" || arg == "-h")
        {
            serveUsage();
            return 2;
        }
        if(arg.startsWith("--port="))
            opts.port = arg["--port=".length .. $].to!ushort;
        else if(arg == "--port")
        {
            if(i + 1 >= args.length) { error("--port requires a value"); return 1; }
            opts.port = args[++i].to!ushort;
        }
        else if(arg.startsWith("--host="))
            opts.host = arg["--host=".length .. $];
        else if(arg == "--host")
        {
            if(i + 1 >= args.length) { error("--host requires a value"); return 1; }
            opts.host = args[++i];
        }
        else if(opts.path is null)
            opts.path = arg;
        else
        {
            error("Unexpected argument: ", arg);
            return 1;
        }
    }
    return 0;
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

private immutable string wasiShim = q"WASI_SHIM
const wasi = {};
const wasiNoop = () => 0;
for (const name of [
    "args_get", "args_sizes_get", "environ_get", "environ_sizes_get",
    "clock_res_get", "clock_time_get", "fd_advise", "fd_allocate", "fd_close",
    "fd_datasync", "fd_fdstat_get", "fd_fdstat_set_flags", "fd_fdstat_set_rights",
    "fd_filestat_get", "fd_filestat_set_size", "fd_filestat_set_times", "fd_pread",
    "fd_prestat_get", "fd_prestat_dir_name", "fd_pwrite", "fd_read", "fd_readdir",
    "fd_renumber", "fd_seek", "fd_sync", "fd_tell", "fd_write",
    "path_create_directory", "path_filestat_get", "path_filestat_set_times",
    "path_link", "path_open", "path_readlink", "path_remove_directory", "path_rename",
    "path_symlink", "path_unlink_file", "poll_oneoff", "proc_exit", "proc_raise",
    "sched_yield", "random_get", "sock_accept", "sock_recv", "sock_send", "sock_shutdown"
]) wasi[name] = wasiNoop;
let wasiMemory = null;
wasi.fd_write = (fd, iovs, iovsLen, nwritten) => {
    if (!wasiMemory) return 0;
    const view = new DataView(wasiMemory.buffer);
    const decoder = new TextDecoder();
    let written = 0;
    let text = "";
    for (let i = 0; i < iovsLen; i++) {
        const ptr = view.getUint32(iovs + i * 8, true);
        const len = view.getUint32(iovs + i * 8 + 4, true);
        text += decoder.decode(new Uint8Array(wasiMemory.buffer, ptr, len));
        written += len;
    }
    if (fd === 1 || fd === 2) {
        if (output) output.textContent += text;
        console.log(text);
    }
    view.setUint32(nwritten, written, true);
    return 0;
};
wasi.fd_prestat_get = () => 8;
wasi.clock_res_get = (id, ptr) => {
    if (wasiMemory) new DataView(wasiMemory.buffer).setBigUint64(ptr, 1n, true);
    return 0;
};
wasi.fd_fdstat_get = (fd, ptr) => {
    if (wasiMemory) {
        const view = new DataView(wasiMemory.buffer);
        view.setUint8(ptr, 2);
        view.setBigUint64(ptr + 8, 0xffffffffffffffffn, true);
        view.setBigUint64(ptr + 16, 0xffffffffffffffffn, true);
    }
    return 0;
};
wasi.args_sizes_get = (argc, argv) => {
    if (wasiMemory) {
        const view = new DataView(wasiMemory.buffer);
        view.setUint32(argc, 0, true);
        view.setUint32(argv, 0, true);
    }
    return 0;
};
wasi.environ_sizes_get = (count, size) => {
    if (wasiMemory) {
        const view = new DataView(wasiMemory.buffer);
        view.setUint32(count, 0, true);
        view.setUint32(size, 0, true);
    }
    return 0;
};
wasi.clock_time_get = (id, precision, ptr) => {
    if (wasiMemory) new DataView(wasiMemory.buffer).setBigUint64(ptr, 0n, true);
    return 0;
};
wasi.random_get = (ptr, len) => {
    if (wasiMemory) new Uint8Array(wasiMemory.buffer, ptr, len).fill(0);
    return 0;
};
wasi.proc_exit = (code) => { throw { wasiExit: code }; };
WASI_SHIM";

private string loaderScript(string wasmName)
{
    string target = wasmName.length ? jsString(wasmName) : "null";
    return
        "const status = document.getElementById('redub-status');\n"
        ~ "const output = document.getElementById('redub-output');\n"
        ~ "const wasmUrl = " ~ target ~ ";\n"
        ~ wasiShim ~ "\n"
        ~ "try {\n"
        ~ "  if (!wasmUrl) throw new Error('No .wasm file found in the served directory');\n"
        ~ "  const response = await fetch(wasmUrl);\n"
        ~ "  if (!response.ok) throw new Error(response.status + ' ' + response.statusText);\n"
        ~ "  const { instance } = await WebAssembly.instantiateStreaming(response, { wasi_snapshot_preview1: wasi });\n"
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
    import std.path : absolutePath, baseName, dirName, extension, relativePath;
    import std.socket;
    import std.string : replace;

    setLogLevel(LogLevel.info);
    ServeOptions opts;
    int parseResult = parseServeOptions(args, opts);
    if(parseResult != 0)
        return parseResult == 2 ? 0 : parseResult;

    string root = opts.path is null ? "." : opts.path;
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
            if(exists(sibling))
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
            if(exists(sibling))
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
