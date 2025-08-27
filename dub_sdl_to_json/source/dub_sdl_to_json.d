module dub_sdl_to_json;
public import hipjson;
import sdlite;
import core.stdc.math;

SDLNode[] parseSDL(string fileName)
{
	import std.file;
	return parseSDL(fileName, readText(fileName));
}


SDLNode[] parseSDL(string fileName, string sdlData)
{
	SDLNode[] result;
	sdlData = fixSDLParsingBugs(sdlData);
	parseSDLDocument!((n){result~= n;})(sdlData, fileName);
	return result;
}

JSONValue toJSONValue(SDLValue v)
{
	switch(v.kind)
	{
		case SDLValue.Kind.text:
			return JSONValue(v.textValue);
		case SDLValue.Kind.int_:
			return JSONValue(v.int_Value);
		case SDLValue.Kind.long_:
			return JSONValue(v.long_Value);
		case SDLValue.Kind.float_:
			return JSONValue(v.float_Value);
		case SDLValue.Kind.double_:
			return JSONValue(v.double_Value);
		case SDLValue.Kind.bool_:
			return JSONValue(v.bool_Value);
		default:break;
	}
	return JSONValue(null);
}

JSONValue toJSONValue(SDLValue[] values, bool forceArray = false)
{
	if(values.length == 1 && !forceArray)
		return toJSONValue(values[0]);
	JSONValue ret = JSONValue.emptyArray;
	foreach(v; values)
	{
		ret.jsonArray~= toJSONValue(v);
	}
	return ret;
}

string getName(SDLNode node)
{
	import std.exception;
	if(node.attributes.length == 0) return node.name;
	SDLValue plat = node.getAttribute("platform");
	if(plat.isNull_) return node.name;
	enforce(plat.isText, "platform attribute from node "~node.name~" must be a string.");
	return node.name~"-"~plat.textValue;
}

JSONValue sdlToJSON(SDLNode[] sdl)
{
	import std.exception;
	import std.algorithm.searching:countUntil;

	JSONValue ret = JSONValue.emptyObject;

	JSONValue dependencies = JSONValue.emptyObject;
	JSONValue subConfigurations = JSONValue.emptyObject;
	JSONValue buildTypes = JSONValue.emptyObject;

	JSONValue configurations = JSONValue.emptyArray;
	JSONValue subPackages = JSONValue.emptyArray;

	foreach(SDLNode v; sdl)
	{
		switch(v.name)
		{
			case "dependency":
				enforce(v.values.length == 1, "Can only have a single value for dependency");
				enforce(v.values[0].isText, "Value for dependency must be a text.");
				string depName = v.values[0].textValue;

				enforce(v.attributes.length > 0, "A dependency must have at least one attribute. (Parsing "~depName~")");

				SDLValue pathValue = v.getAttribute("path");
				SDLValue versionValue = v.getAttribute("version");

        if(pathValue.isNull_)
        {
					enforce(!versionValue.isNull_, "If no path is present in a .sdl file, a version must be present. (Parsing "~depName~")");
					enforce(versionValue.isText, "version must be a string. Parsing ("~depName~")");
        }
        else if(versionValue.isNull)
        {
          enforce(!pathValue.isNull_, "If no version is present in a .sdl file, a path must be present. (Parsing "~depName~")");
					enforce(pathValue.isText, "path must be a string. Parsing ("~depName~")");
        }

        if(v.attributes.length == 1 && !versionValue.isNull_)
					dependencies[depName] = JSONValue(versionValue.textValue);
				else
				{
					JSONValue dep = JSONValue.emptyObject;
					foreach(SDLAttribute attr; v.attributes)
						dep[attr.name] = toJSONValue(attr.value);
					dependencies[depName] = dep;
				}
				break;
			case "configuration":
				enforce(v.values.length == 1, "A configuration can only have a single value, which is the configuration name");
				enforce(v.values[0].isText, "The configuration value must be a string.");
				JSONValue configSdl = sdlToJSON(v.children);
				configSdl["name"] = v.values[0].textValue;
				configurations.jsonArray~= configSdl;
				break;
			case "buildType":
				enforce(v.values.length == 1, "A buildType can only have a single value, which is the buildType name");
				enforce(v.values[0].isText, "The buildType value must be a string.");
				JSONValue buildTypeSDL = sdlToJSON(v.children);
				buildTypes[v.values[0].textValue] = buildTypeSDL;
				break;
			case "toolchainRequirements":
				if(v.attributes.length == 0)
					break;
				JSONValue requirements = JSONValue.emptyObject;
				foreach(a; v.attributes)
					requirements[a.name] = toJSONValue(a.value);
				ret["toolchainRequirements"] = requirements;
				break;
			case "subConfiguration":
				enforce(v.values.length == 2, "subConfiguration must contain a two values.");
				enforce(v.values[0].isText, "subConfiguration value 1 must be a text.");
				enforce(v.values[1].isText, "subConfiguration value 2 must be a text.");
				enforce(!(v.values[0].textValue in subConfigurations), "Subconfiguration "~v.values[0].textValue~" is already present in subConfigurations.");
				subConfigurations[v.values[0].textValue] = JSONValue(v.values[1].textValue);

				break;
			case "subPackage":
				if(v.values.length > 0)
				{
					enforce(v.values.length == 1, "subPackage containing a value, must be a single value.");
					enforce(v.values[0].isText, "Whenever a subPackage has a single value, it must be a text.");
					subPackages.jsonArray~= JSONValue(v.values[0].textValue);
				}
				else
				{
					JSONValue subPkg = sdlToJSON(v.children);
					enforce("name" in subPkg, "SDL->JSON subPackage must contain a name");
					subPackages.jsonArray~= subPkg;
				}
				break;
			default:
				bool shouldForceArray = countUntil([
					"dflags",
					"lflags",
					"libs",
					"versions",
					"platforms",
					"authors",

					"preGenerateCommands",
					"postGenerateCommands",
					"preBuildCommands",
					"postBuildCommands",

					"sourceFiles",
					"excludedSourceFiles",
					"copyFiles",

					"sourcePaths",
					"importPaths",
					"stringImportPaths",

					"buildOptions",
					"buildRequirements",
					], v.name) != -1;
				string name = getName(v);
				JSONValue* json = name in ret;
				if(json)
				{
					if(json.type != JSONType.array)
					{
						import std.stdio;
						stderr.writeln("Warning: Can only show twice on SDL's '"~name~"' if it is an array type.");
					}
					else
					{
						foreach(jsonValue; toJSONValue(v.values, true).array)
							json.jsonArray~= jsonValue;
					}
				}
				else
					ret[getName(v)] = toJSONValue(v.values, shouldForceArray);
				break;
		}
		// ret[v.name] = v.values[0]
	}
	if(dependencies.data.object !is null)
		ret["dependencies"] = dependencies;
	if(subConfigurations.data.object !is null)
		ret["subConfigurations"] = subConfigurations;
	if(buildTypes.data.object !is null)
		ret["buildTypes"] = buildTypes;

	if(configurations.array.length != 0)
		ret["configurations"] = configurations;
	if(subPackages.array.length != 0)
		ret["subPackages"] = subPackages;


	return ret;
}


/**
*   Strips single and multi line comments (C style)
*/
string stripComments(string str)
{
    string ret;
    size_t i = 0;
    size_t length = str.length;
    ret.reserve(str.length);

    while(i < length)
    {
        //Don't parse comments inside strings
        if(str[i] == '`')
        {
            size_t left = i;
            i++;
            while(i < length && str[i] != '`')
                i++;
            i++; //Skip '`'
            ret~= str[left..i];
        }
        else if(str[i] == '"')
        {
            size_t left = i;
            i++;
            while(i < length && str[i] != '"')
            {
                if(str[i] == '\\')
                    i++;
                i++;
            }
            i++; //Skip '"'
            ret~= str[left..i];
        }
        //Parse single liner comments
        else if(str[i] == '/' && i+1 < length && str[i+1] == '/')
        {
            i+=2;
            while(i < length && str[i] != '\n')
                i++;
        }
		else if(str[i] == '-' && i + 1 < length && str[i+1] == '-') //Single line --
		{
			i+=2;
            while(i < length && str[i] != '\n')
                i++;
		}
        //Single line #
        else if(str[i] == '#')
        {
            i++;
            while(i < length && str[i] != '\n')
                i++;
        }
        //Parse multi line comments
        else if(str[i] == '/' && i+1 < length && str[i+1] == '*')
        {
            i+= 2;
            while(i < length)
            {
                if(str[i] == '*' && i+1 < length && str[i+1] == '/')
                    break;
                i++;
            }
            i+= 2;
        }
        //Safe check to see if it is in range
        if(i < length)
            ret~= str[i];
        i++;
    }
    return ret;
}


/**
 * Fixes SDL for being converted to JSON
 * Params:
 *   sdlData = Some SDL data may input extra \n. Those are currently in the process of being ignored by the JSON parsing as it may break.
 * Returns: SDL parse fixed.
 */
string fixSDLParsingBugs(string sdlData)
{
    import std.string:replace;

    version(Windows)
        enum lb = "\r\n";
    else
        enum lb = "\n";
    
    sdlData = stripComments(sdlData);
    sdlData = sdlData.replace("\\"~lb, " ");
    

    /*
      Now replace things like:
      test `
      lala`
      Since that will produce "test": "\nlala"

      This was also replacing more common things such as
      name "taggedalgebraic"
      description `something like that`
      author "sonke"
    */


    /** 
     * '\\' is considered a escape for the tags
     * Params:
     *   input = A string with '`' to match, for example description `test` - match the brackets
     *   startIndex = 
     * Returns: 
     */
    static bool findMatchingEnd(string input, out ptrdiff_t start, out ptrdiff_t end, ptrdiff_t startIndex = 0)
    {
      start = -1;
      end = -1;
      for(ptrdiff_t i = startIndex; i < input.length; i++)
      {
        switch(input[i])
        {
          case '\\':
            i++;
            break;
          case '`': //The implementation is also 
            if(start == -1)
              start = i;
            else
            {
              end = i;
              return true;
            }
            break;
          default:break;
        }
      }
      return false;
    }

    static string fixSdlStringLiteralBug(string input)
    {
      ptrdiff_t start, end;
      ptrdiff_t idx;
      string ret;
      while(findMatchingEnd(input, start, end, idx))
      {
        import std.stdio;
        ret~= input[idx..start];
        ret~= input[start..end].replace('`'~lb, "` ");
        idx = end;
      }
      if(idx == 0) return input;
      else if(idx != input.length)
        ret~= input[idx..$];
      return ret;
    }

    return fixSdlStringLiteralBug(sdlData);
}


unittest
{
enum testSdl =
q"ED
	preGenerateCommands `$DC -run scripts/generate_version.d` platform="posix-ldc"
	preGenerateCommands `$DC -run scripts/generate_version.d` platform="posix-dmd"

ED";
sdlToJSON(parseSDL(null, testSdl));
}


///Test conversion of a
unittest
{
enum testSdl =
q"ED
name "taggedalgebraic"
description `A "tagged union" implementation with transparent operator forwarding.`
authors "Sönke Ludwig"
copyright "Copyright © 2015, Sönke Ludiwg"
license "BSL-1.0"

buildType "unittest" {
    buildOptions "unittests" "debugMode" "debugInfo"
    dflags "-preview=dip1000"
}
ED";
	import hipjson;
	SDLNode[] nodes = parseSDL(null, testSdl);
	JSONValue v = sdlToJSON(nodes);
	assert(!parseJSON(v["description"].toString).hasErrorOccurred);

}

unittest
{
	import std.stdio;
	enum testSdl =
`
dependency "yyjson-d" path="../yyjson-d"
`;
	JSONValue v = sdlToJSON(parseSDL(null, testSdl));
	assert("dependencies" in v);
}


///Dmd package
unittest
{
enum testSdl =
q"ED
name "dmd"
description "The DMD compiler"
authors "Walter Bright"
copyright "Copyright © 1999-2018, The D Language Foundation"
license "BSL-1.0"

targetType "none"
dependency ":frontend" version="*"

subPackage {
  name "compiler"
  targetType "executable"
  targetName "dmd"
  sourcePaths "compiler/src/dmd"
  importPaths "compiler/src"
  stringImportPaths "compiler/src/dmd/res" "."
  dflags "-L/STACK:16777216" platform="windows"
  dflags "-preview=dip1000"
  preGenerateCommands "echo -n /etc > SYSCONFDIR.imp" platform="posix"
}

subPackage {
  name "root"
  targetType "library"
  importPaths "compiler/src"
  sourcePaths "compiler/src/dmd/common" "compiler/src/dmd/root"
}

subPackage {
  name "lexer"
  targetType "library"
  importPaths "compiler/src"
  sourcePaths

  sourceFiles \
    "compiler/src/dmd/console.d" \
    "compiler/src/dmd/entity.d" \
    "compiler/src/dmd/errors.d" \
    "compiler/src/dmd/file_manager.d" \
    "compiler/src/dmd/globals.d" \
    "compiler/src/dmd/id.d" \
    "compiler/src/dmd/identifier.d" \
    "compiler/src/dmd/lexer.d" \
    "compiler/src/dmd/location.d" \
    "compiler/src/dmd/tokens.d" \
    "compiler/src/dmd/utils.d" \
    "compiler/src/dmd/errorsink.d"

  versions \
    "CallbackAPI" \
    "DMDLIB"

  preGenerateCommands `
    "$${DUB_EXE}" \
    --arch=$${DUB_ARCH} \
    --compiler=$${DC} \
    --single "$${DUB_PACKAGE_DIR}config.d" \
    -- "$${DUB_PACKAGE_DIR}generated/dub" \
    "$${DUB_PACKAGE_DIR}VERSION" \
    /etc
   ` platform="posix"

  preGenerateCommands `"%DUB_EXE%" --arch=%DUB_ARCH% --compiler="%DC%" --single "%DUB_PACKAGE_DIR%config.d" -- "%DUB_PACKAGE_DIR%generated/dub" "%DUB_PACKAGE_DIR%VERSION"` platform="windows"

  stringImportPaths \
    "compiler/src/dmd/res" \
    "generated/dub"

  dependency "dmd:root" version="*"
}

subPackage {
  name "parser"
  targetType "library"
  importPaths "compiler/src"
  sourcePaths

  sourceFiles \
    "compiler/src/dmd/astbase.d" \
    "compiler/src/dmd/parse.d" \
    "compiler/src/dmd/transitivevisitor.d" \
    "compiler/src/dmd/permissivevisitor.d" \
    "compiler/src/dmd/strictvisitor.d"

  versions "CallbackAPI"

  dependency "dmd:lexer" version="*"
}

subPackage {
  name "frontend"
  targetType "library"
  importPaths "compiler/src"
  sourcePaths "compiler/src/dmd"
  stringImportPaths "compiler/src/dmd/res"

  versions \
    "NoBackend" \
    "GC" \
    "NoMain" \
    "MARS" \
    "CallbackAPI"

  excludedSourceFiles "compiler/src/dmd/backend/*"
  excludedSourceFiles "compiler/src/dmd/root/*"
  excludedSourceFiles "compiler/src/dmd/common/*"
  excludedSourceFiles "compiler/src/dmd/{\
    astbase,\
    console,\
    entity,\
    errors,\
    file_manager,\
    globals,\
    id,\
    identifier,\
    lexer,\
    parse,\
    permissivevisitor,\
    strictvisitor,\
    tokens,\
    transitivevisitor,\
    utf,\
    utils\
  }.d"
  excludedSourceFiles "compiler/src/dmd/{\
    dmsc,\
    e2ir,\
    eh,\
    glue,\
    iasmdmd,\
    iasmgcc,\
    irstate,\
    lib,\
    libelf,\
    libmach,\
    libmscoff,\
    libomf,\
    link,\
    objc_glue,\
    s2ir,\
    scanelf,\
    scanmach,\
    scanmscoff,\
    scanomf,\
    tocsym,\
    toctype,\
    tocvdebug,\
    toobj,\
    todt,\
    toir\
  }.d"

  dependency "dmd:parser" version="*"
}
ED";
	sdlToJSON(parseSDL(null, testSdl));
}



unittest
{
enum testSdl =q"ED

configuration "mkl-tbb-thread" {
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\ia32\vc_mt\"` platform="windows-x86-dmd"
}

}
ED";
stripComments(testSdl);
}

unittest
{

enum testSdl = q"ED
name "mir-blas"
description "ndslice wrapper for BLAS"
authors "Ilya Yaroshenko"
copyright "Copyright © 2017-2018, Symmetry Investments & Kaleidic Associates"
license "BSL-1.0"

dependency "cblas" version=">=2.0.4"
dependency "mir-algorithm" version=">=2.0.0-beta2 <4.0.0"

configuration "library" {
	platforms "posix" "windows-x86_64" "windows-x86"

	// Posix: "openblas" configuration

	versions "OPENBLAS" platform="posix"
	libs "openblas" platform="posix"
	lflags "-L/opt/homebrew/opt/openblas/lib" platform="darwin"

	// Windows: "mkl-sequential-ilp" configuration

	versions "INTEL_MKL" "BLASNATIVEINT" "LAPACKNATIVEINT" platform="windows"

	platforms "x86_64" "x86"
	libs "mkl_core" "mkl_sequential" "mkl_intel_c" platform="windows-x86"
	libs "mkl_core" "mkl_sequential" "mkl_intel_ilp64" platform="windows-x86_64"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64` platform="windows-x86_64-ldc"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32` platform="windows-x86-ldc"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64\"` platform="windows-x86_64-dmd"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32\"` platform="windows-x86-dmd"
}

configuration "openblas" {
	versions "OPENBLAS"
	libs "openblas"
	lflags "-L/opt/homebrew/opt/openblas/lib" platform="darwin"
}

configuration "blas" {
	libs "blas" # CBLAS API assumed to be in BLAS
}

configuration "cblas" {
	libs "cblas" # BLAS API assumed to be in CBLAS
}

configuration "twolib" {
	libs "blas" "cblas"
}

configuration "zerolib" {
	systemDependencies "mir-blas configuration 'zerolib' requires user to specify libraries to link."
}

configuration "mkl-sequential" {
	platforms "x86_64" "x86"
	versions "INTEL_MKL"
	libs "mkl_core" "mkl_sequential" "mkl_intel_c" platform="x86"
	libs "mkl_core" "mkl_sequential" "mkl_intel_lp64" platform="x86_64"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64` platform="windows-x86_64-ldc"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32` platform="windows-x86-ldc"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64\"` platform="windows-x86_64-dmd"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32\"` platform="windows-x86-dmd"
}
configuration "mkl-sequential-ilp" {
	platforms "x86_64" "x86"
	versions "INTEL_MKL" "BLASNATIVEINT" "LAPACKNATIVEINT"
	libs "mkl_core" "mkl_sequential" "mkl_intel_c" platform="x86"
	libs "mkl_core" "mkl_sequential" "mkl_intel_ilp64" platform="x86_64"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64` platform="windows-x86_64-ldc"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32` platform="windows-x86-ldc"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64\"` platform="windows-x86_64-dmd"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32\"` platform="windows-x86-dmd"
}
configuration "mkl-tbb-thread" {
	platforms "x86_64" "x86"
	versions "INTEL_MKL"
	libs "tbb" "mkl_core" "mkl_tbb_thread" "mkl_intel_c" platform="x86"
	libs "tbb" "mkl_core" "mkl_tbb_thread" "mkl_intel_lp64" platform="x86_64"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64` platform="windows-x86_64-ldc"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32` platform="windows-x86-ldc"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64\"` platform="windows-x86_64-dmd"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32\"` platform="windows-x86-dmd"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\intel64\vc_mt` platform="windows-x86_64-ldc"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\ia32\vc_mt` platform="windows-x86-ldc"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\intel64\vc_mt\"` platform="windows-x86_64-dmd"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\ia32\vc_mt\"` platform="windows-x86-dmd"
	copyFiles `C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\redist\intel64\tbb\vc_mt\tbb.dll` platform="windows-x86_64"
	copyFiles `C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\redist\ia32\tbb\vc_mt\tbb.dll` platform="windows-x86"
}
configuration "mkl-tbb-thread-ilp" {
	platforms "x86_64" "x86"
	versions "INTEL_MKL" "BLASNATIVEINT" "LAPACKNATIVEINT"
	libs "tbb" "mkl_core" "mkl_tbb_thread" "mkl_intel_c" platform="x86"
	libs "tbb" "mkl_core" "mkl_tbb_thread" "mkl_intel_ilp64" platform="x86_64"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64` platform="windows-x86_64-ldc"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32` platform="windows-x86-ldc"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64\"` platform="windows-x86_64-dmd"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32\"` platform="windows-x86-dmd"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\intel64\vc_mt` platform="windows-x86_64-ldc"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\ia32\vc_mt` platform="windows-x86-ldc"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\intel64\vc_mt\"` platform="windows-x86_64-dmd"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\ia32\vc_mt\"` platform="windows-x86-dmd"
	copyFiles `C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\redist\intel64\tbb\vc_mt\tbb.dll` platform="windows-x86_64"
	copyFiles `C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\redist\ia32\tbb\vc_mt\tbb.dll` platform="windows-x86"
}
configuration "mkl-sequential-dll" {
	platforms "x86_64" "x86"
	versions "INTEL_MKL"
	libs "mkl_core_dll" "mkl_sequential_dll" "mkl_intel_c_dll" platform="x86"
	libs "mkl_core_dll" "mkl_sequential_dll" "mkl_intel_lp64_dll" platform="x86_64"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64` platform="windows-x86_64-ldc"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32` platform="windows-x86-ldc"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64\"` platform="windows-x86_64-dmd"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32\"` platform="windows-x86-dmd"
}
configuration "mkl-sequential-ilp-dll" {
	platforms "x86_64" "x86"
	versions "INTEL_MKL" "BLASNATIVEINT" "LAPACKNATIVEINT"
	libs "mkl_core_dll" "mkl_sequential_dll" "mkl_intel_c_dll" platform="x86"
	libs "mkl_core_dll" "mkl_sequential_dll" "mkl_intel_ilp64_dll" platform="x86_64"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64` platform="windows-x86_64-ldc"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32` platform="windows-x86-ldc"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64\"` platform="windows-x86_64-dmd"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32\"` platform="windows-x86-dmd"
}
configuration "mkl-tbb-thread-dll" {
	platforms "x86_64" "x86"
	versions "INTEL_MKL"
	libs "tbb" "mkl_core_dll" "mkl_tbb_thread_dll" "mkl_intel_c_dll" platform="x86"
	libs "tbb" "mkl_core_dll" "mkl_tbb_thread_dll" "mkl_intel_lp64_dll" platform="x86_64"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64` platform="windows-x86_64-ldc"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32` platform="windows-x86-ldc"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64\"` platform="windows-x86_64-dmd"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32\"` platform="windows-x86-dmd"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\intel64\vc_mt` platform="windows-x86_64-ldc"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\ia32\vc_mt` platform="windows-x86-ldc"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\intel64\vc_mt\"` platform="windows-x86_64-dmd"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\ia32\vc_mt\"` platform="windows-x86-dmd"
	copyFiles `C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\redist\intel64\tbb\vc_mt\tbb.dll` platform="windows-x86_64"
	copyFiles `C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\redist\ia32\tbb\vc_mt\tbb.dll` platform="windows-x86"
}
configuration "mkl-tbb-thread-ilp-dll" {
	platforms "x86_64" "x86"
	versions "INTEL_MKL" "BLASNATIVEINT" "LAPACKNATIVEINT"
	libs "tbb" "mkl_core_dll" "mkl_tbb_thread_dll" "mkl_intel_c_dll" platform="x86"
	libs "tbb" "mkl_core_dll" "mkl_tbb_thread_dll" "mkl_intel_ilp64_dll" platform="x86_64"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64` platform="windows-x86_64-ldc"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32` platform="windows-x86-ldc"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\intel64\"` platform="windows-x86_64-dmd"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\mkl\lib\ia32\"` platform="windows-x86-dmd"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\intel64\vc_mt` platform="windows-x86_64-ldc"
	lflags `/LIBPATH:C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\ia32\vc_mt` platform="windows-x86-ldc"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\intel64\vc_mt\"` platform="windows-x86_64-dmd"
	lflags `/LIBPATH:\"C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\tbb\lib\ia32\vc_mt\"` platform="windows-x86-dmd"
	copyFiles `C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\redist\intel64\tbb\vc_mt\tbb.dll` platform="windows-x86_64"
	copyFiles `C:\Program Files (x86)\IntelSWTools\compilers_and_libraries\windows\redist\ia32\tbb\vc_mt\tbb.dll` platform="windows-x86"
}
ED";
assert(!sdlToJSON(parseSDL(null ,testSdl)).hasErrorOccurred);

}