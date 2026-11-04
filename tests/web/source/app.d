import std.stdio;

extern(C) void someLog();

void main()
{
    writeln("Edit source/app.d to start your project.");
    someLog();
}