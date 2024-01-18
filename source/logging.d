module logging;
import std.stdio;
enum LogLevel
{
    none,
    error,
    warn,
    info,
    verbose,
    vverbose
}
private LogLevel level;
void setLogLevel(LogLevel lvl){ level = lvl; }
void info(T...)(T args){if(level <= LogLevel.info) writeln(args);}
void vlog(T...)(T args){if(level <= LogLevel.verbose) writeln(args);}
void vvlog(T...)(T args){if(level <= LogLevel.vverbose) writeln(args);}
void warn(T...)(T args){if(level <= LogLevel.warn)writeln("Warning: ", args);}
void error(T...)(T args){if(level <= LogLevel.error)writeln("ERROR! ", args);}