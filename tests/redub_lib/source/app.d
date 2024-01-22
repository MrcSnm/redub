import std.stdio;
import logging;
import redub_api;

void main()
{
	import std.file;

	setLogLevel(LogLevel.info);
	
	ProjectDetails d = resolveDependencies(
		false,
		os,
		CompilationDetails.init,
		ProjectToParse(null, getcwd())
	);

	buildProject(d);
}
