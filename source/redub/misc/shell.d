module redub.misc.shell;
import std.typecons : Tuple;
public import std.process;
import std.array:Appender;

struct ProcessExec2
{
    ProcessPipes pipe;
    Appender!(ubyte[]) output;
}

private string decodeProcessOutput(const(ubyte)[] data)
{
    import std.utf : validate;

    try
    {
        validate(cast(string) data);
        return cast(string) data.idup;
    }
    catch (Exception) {}

    version(Windows)
    {
        import core.sys.windows.winnls : MultiByteToWideChar, WideCharToMultiByte, CP_OEMCP, CP_UTF8;

        int wideLength = MultiByteToWideChar(CP_OEMCP, 0, cast(const(char)*) data.ptr, cast(int) data.length, null, 0);
        if(wideLength > 0)
        {
            auto wide = new wchar[wideLength];
            MultiByteToWideChar(CP_OEMCP, 0, cast(const(char)*) data.ptr, cast(int) data.length, wide.ptr, wideLength);
            int utf8Length = WideCharToMultiByte(CP_UTF8, 0, wide.ptr, wideLength, null, 0, null, null);
            if(utf8Length > 0)
            {
                auto utf8 = new char[utf8Length];
                WideCharToMultiByte(CP_UTF8, 0, wide.ptr, wideLength, utf8.ptr, utf8Length, null, null);
                return cast(string) utf8;
            }
        }
    }

    import std.array : appender;
    import std.utf : decode, UTFException;
    auto output = appender!string;
    const(char)[] chars = cast(const(char)[]) data;
    size_t i;
    while(i < chars.length)
    {
        try
            output.put(decode(chars, i));
        catch (UTFException)
        {
            output.put('?');
            ++i;
        }
    }
    return output.data;
}

ProcessExec2 executeProcess2(scope const(char)[][] command,
                  const string[string] env = null,
                  Config config = Config.none,
                  size_t maxOutput = size_t.max,
                  scope const(char)[] workDir = null)
    @safe
{
    return executeImpl!pipeProcess(command,
                                 env,
                                 config,
                                 maxOutput,
                                 workDir);
}

// Does the actual work for execute() and executeProcess().
private ProcessExec2 executeImpl(alias pipeFunc, Cmd, ExtraPipeFuncArgs...)(
    Cmd commandLine,
    const string[string] env = null,
    Config config = Config.none,
    size_t maxOutput = size_t.max,
    scope const(char)[] workDir = null,
    ExtraPipeFuncArgs extraArgs = ExtraPipeFuncArgs.init)
    @trusted //TODO: @safe
{
    import std.algorithm.comparison : min;
    import std.array : appender, Appender;

    auto redirect = (config.flags & Config.Flags.stderrPassThrough)
        ? Redirect.stdout
        : Redirect.stdout | Redirect.stderrToStdout;

    auto p = pipeFunc(commandLine, redirect,
                      env, config, workDir, extraArgs);

    auto a = appender!(ubyte[])();
    return ProcessExec2(p, a);
}

auto waitProcessExec(ref ProcessExec2 ex)
{
    enum size_t defaultChunkSize = 4096;
    immutable chunkSize = defaultChunkSize;

    // Store up to maxOutput bytes in a.
    foreach (ubyte[] chunk; ex.pipe.stdout.byChunk(chunkSize))
    {
        immutable size_t remain = size_t.max - ex.output.data.length;
        if (chunk.length < remain) ex.output.put(chunk);
        else
        {
            ex.output.put(chunk[0 .. remain]);
            break;
        }
    }
    // Exhaust the stream, if necessary.
    foreach (ubyte[] chunk; ex.pipe.stdout.byChunk(defaultChunkSize)) { }
    return Tuple!(int, "status", string, "output",)(wait(ex.pipe.pid), decodeProcessOutput(ex.output.data));
}