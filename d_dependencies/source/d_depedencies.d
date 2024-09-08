module d_depedencies;

struct ModuleDef
{
	string modName;
	string modPath;
	ModuleDef[string] importedBy;
	ModuleDef[string] imports;

	package void addImport(ref ModuleDef imported)
	{
		imported.importedBy[modPath] = this;
		imports[imported.modPath] = imported;
	}
}

class ModuleParsing
{
	ModuleDef[string] allModules;

	ModuleDef* getModuleInCache(string moduleName, string modulePath)
	{
		ModuleDef* ret = modulePath in allModules;
		if(!ret)
		{
			allModules[modulePath] = ModuleDef(moduleName, modulePath);
			ret = modulePath in allModules;
		}
		return ret;
	}

	ModuleDef[] findRoots()
	{
		ModuleDef[] ret;
		foreach(key, value; allModules)
		{
			if(value.importedBy.length == 0)
				ret~= value;
		}
		return ret;
	}
	ModuleDef[] findDependees(const string[] filesPath)
	{
		bool[string] visited;
		return findDependees(filesPath, visited);
	}

	ModuleDef[] findDependees(const string[] filesPath, ref bool[string] visited)
	{
		ModuleDef[] ret;
		static void findDependeesImpl(ModuleDef* input, ref ModuleDef[] ret, ref bool[string] visited)
		{
			foreach(modPath, ref modDef; input.importedBy)
			{
				if(!(modPath in visited))
				{
					visited[modPath] = true;
					ret~= modDef;
					findDependeesImpl(&modDef, ret, visited);
				}
			}
		}
		foreach(filePath; filesPath)
		{
			ModuleDef* mod = filePath in allModules;
			if(mod == null)
				continue;
			visited[filePath] = true;
			findDependeesImpl(mod, ret, visited);			
		}
		return ret;
		
	}
}



private void put(Q, T)(Q range, scope T[] args ...) if(is(T == U*, U))
{
    int i = 0;
    foreach(v; range)
    {
        if(i >= args.length)
            return;
		if(args[i] == null)
		{
			i++;
			continue;
		}
        *args[i] = v;
        i++;
    }
}

ModuleParsing parseDependencies(string deps, immutable scope string[] exclude...)
{
	import std.string;
	import std.algorithm;
	ModuleParsing ret = new ModuleParsing();
	ModuleDef* current;

	/**
	 * When including a path from the deps flag, it also includes the selective imports.
	 * (C:\\D\\dmd2\\windows\\bin64\\..\\..\\src\\druntime\\import\\core\\stdc\\string.d):memcpy,strncmp,strlen
	 *
	 * So, it must remove the parenthesis and selective import from the paths.
	 * Params:
	 *   importPath = Import Path style in the way dmd -deps saves.
	 * Returns: A cleaned path only string
	 */
	static string cleanImportPath(string importPath)
	{
		if(importPath.length == 0) return null;
		if(importPath[0] != '(') return importPath;
		ptrdiff_t lastIndex = lastIndexOf(importPath, ')');
		return importPath[1..lastIndex];
	}
	outer: foreach(string line; splitter(deps, "\n"))
	{
		foreach(value; exclude) if(line.startsWith(value))
			continue outer;

		///(moduleName) (modulePath) (:) (private/public/string) (:) (importedName) ((importedPath)
		string modName, modPath, importType, importedName, importedPath;
		put(splitter(line," "), &modName, &modPath, null, &importType, null, &importedName, &importedPath);


		if(current == null || modName != current.modName)
			current = ret.getModuleInCache(modName.dup, cleanImportPath(modPath).dup);

		ModuleDef* importedRef = ret.getModuleInCache(importedName, cleanImportPath(importedPath));
		current.addImport(*importedRef);
	}
	return ret;
}

unittest
{
	import std.stdio;
	immutable string testcase = import("hip_deps");
	ModuleParsing p = parseDependencies(testcase);
	foreach(dep; p.findDependees("D:\\\\HipremeEngine\\\\source\\\\hip\\\\global\\\\gamedef.d"))
		writeln(dep.modName);
}
