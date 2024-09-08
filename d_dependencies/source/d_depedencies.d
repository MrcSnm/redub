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
			ret~= *mod;
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
	static string cleanImportPath(string importPath, bool isUsingWinSep)
	{
		if(importPath.length == 0) return null;
		if(importPath[0] != '(') return importPath;
		ptrdiff_t lastIndex = lastIndexOf(importPath, ')');
		string ret = importPath[1..lastIndex];
		if(isUsingWinSep)
		{
			import std.string;
			return replace(ret, "\\\\", "\\");
		}
		return ret;
	}
	bool isUsingWindowsSep;
	bool hasCheckWindowsSep;
	outer: foreach(string line; splitter(deps, "\n"))
	{
		foreach(value; exclude) if(line.startsWith(value))
			continue outer;
		if(!hasCheckWindowsSep)
		{
			isUsingWindowsSep = line.indexOf('\\') != -1;
			hasCheckWindowsSep = true;
		}

		///(moduleName) (modulePath) (:) (private/public/string) (:) (importedName) ((importedPath)
		string modName, modPath, importType, importStatic, importedName, importedPath;
		int i = 0;

		foreach(part; splitter(line, " : "))
		{
			auto infos = splitter(part, " ");
			switch(i)
			{
				case 0:
					infos.put(&modName, &modPath);
					break;
				case 1:
					infos.put(&importType, &importStatic);
					break;
				case 2:
					infos.put(&importedName, &importedPath);
					break;
				case 3: break; //object (/Library/D/dmd/src/druntime/import/object.d) : public : core.attribute (/Library/D/dmd/src/druntime/import/core/attribute.d):selector
				default:
					import std.stdio;
					writeln("Unexpected format received with line '"~line);
					writeln(infos);
					throw new Exception("Information received: input name: "~modName~"  input path:" ~ modPath~" importType: "~importType~" importStatic: "~importStatic~" importedName: "~importedName~" importedPath:"~importedPath);
			}
			i++;
		}
		importedPath = cleanImportPath(importedPath, isUsingWindowsSep);


		if(current == null || modName != current.modName)
		{
			modPath = cleanImportPath(modPath, isUsingWindowsSep);
			current = ret.getModuleInCache(modName.dup, isUsingWindowsSep ? modPath : modPath.idup);
		}

		ModuleDef* importedRef = ret.getModuleInCache(importedName, importedPath);
		current.addImport(*importedRef);
	}
	return ret;
}

unittest
{
	import std.stdio;
	immutable string testcase = import("dub.deps");
	ModuleParsing p = parseDependencies(testcase);
	foreach(ModuleDef v; p.allModules)
	{
		// writeln(v.modName);
	}
	// foreach(dep; p.findDependees("D:\\\\HipremeEngine\\\\source\\\\hip\\\\global\\\\gamedef.d"))
	// 	writeln(dep.modName);
}

unittest
{
	import std.stdio;
	immutable string testcase = `core.internal.hash (C:\\D\\dmd2\\windows\\bin64\\..\\..\\src\\druntime\\import\\core\\internal\\hash.d) : private : object (C:\\D\\dmd2\\windows\\bin64\\..\\..\\src\\druntime\\import\\object.d)`;
	ModuleParsing p = parseDependencies(testcase);
	foreach(ModuleDef v; p.allModules)
	{
		// writeln(v.modName);
	}
	// foreach(dep; p.findDependees("D:\\\\HipremeEngine\\\\source\\\\hip\\\\global\\\\gamedef.d"))
	// 	writeln(dep.modName);
}
