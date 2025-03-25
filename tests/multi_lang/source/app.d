
import std.stdio;
extern(C) void AnotherCFunction();
extern(C) void CFunction();

void main()
{
	CFunction();
	AnotherCFunction();
	writeln("Edit source/app.d to start your project.");
}
