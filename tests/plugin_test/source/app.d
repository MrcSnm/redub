import std.stdio;

void main()
{
	string theImports = import("imports.txt");

	writeln("Found imports: ", theImports);
}
