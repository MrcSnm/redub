module redub.misc.shell;
import std.typecons : Tuple;
public import std.process;
import std.array:Appender;

struct ProcessExec2
{
    ProcessPipes pipe;
    Appender!string output;
}

ProcessExec2 executeShell2(scope const(char)[] command,
                  const string[string] env = null,
                  Config config = Config.none,
                  size_t maxOutput = size_t.max,
                  scope const(char)[] workDir = null,
                  string shellPath = nativeShell)
    @safe
{
    return executeImpl!pipeShell(command,
                                 env,
                                 config,
                                 maxOutput,
                                 workDir,
                                 shellPath);
}

// Does the actual work for execute() and executeShell().
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

    auto a = appender!string;
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
    return Tuple!(int, "status", string, "output",)(wait(ex.pipe.pid), ex.output.data);
}