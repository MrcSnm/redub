module logging;
import colorize;
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
void info(T...)(T args){if(level >= LogLevel.info) cwriteln(args);}
///Short for info success
void infos(T...)(string greenMsg, T args){if(level >= LogLevel.info) cwriteln(greenMsg.color(fg.green) ,args);}
void vlog(T...)(T args){if(level >= LogLevel.verbose) cwriteln(args);}
void vvlog(T...)(T args){if(level >= LogLevel.vverbose) cwriteln(args);}
void warn(T...)(T args){if(level >= LogLevel.warn)cwriteln("Warning: ".color(fg.yellow), args);}
void error(T...)(T args){if(level >= LogLevel.error)cwriteln("ERROR! ".color(fg.red), args);}
void errorTitle(T...)(string redMsg, T args){if(level >= LogLevel.error)cwriteln(redMsg.color(fg.red), args);}