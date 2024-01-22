import std.stdio;
import redub.logging;
import redub.api;

void main()
{
	import std.file;

	setLogLevel(LogLevel.verbose);
	
	ProjectDetails d = resolveDependencies(
		false,
		os,
		CompilationDetails.init,
		ProjectToParse(null, getcwd())
	);

	buildProject(d);
}
