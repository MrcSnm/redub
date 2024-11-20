module dub_sdl_to_json;
public import hipjson;
import sdlite;

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
				string depVer;

				enforce(v.attributes.length > 0, "A dependency must have at least one attribute. (Parsing "~depName~")");
				if(v.attributes.length == 1)
				{
					enforce(v.attributes[0].name == "version", "Whenever dependency has a single attribute, it must be a version. (Parsing "~depName~")");
					SDLValue versionValue = v.getAttribute("version");
					enforce(versionValue.isText, "version must be a string.");
					depVer = versionValue.textValue;
					dependencies[depName]  = JSONValue(depVer);
				}
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
			case "subConfiguration":
				enforce(v.values.length == 2, "subConfiguration must contain a two values.");
				enforce(v.values[0].isText, "subConfiguration value 1 must be a text.");
				enforce(v.values[1].isText, "subConfiguration value 2 must be a text.");
				enforce(!(v.values[0].textValue in subConfigurations), "Subconfiguration "~v.values[0].textValue~" is already present in subConfigurations.");
				subConfigurations[v.values[0].textValue] = JSONValue(v.values[1].textValue);

				break;
			case "subPackage":
				enforce(v.values.length > 0, "subPackage must have at least one value.");
				if(v.values.length == 1)
				{
					enforce(v.values[0].isText, "Whenever a subPackage has a single value, it must be a text.");
					subPackages.jsonArray~= JSONValue(v.values[0].textValue);
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
	if(dependencies.data.object.value !is null)
		ret["dependencies"] = dependencies;
	if(subConfigurations.data.object.value !is null)
		ret["subConfigurations"] = subConfigurations;
	if(buildTypes.data.object.value !is null)
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
        if(str[i] == '"')
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
    import std.file;
    import std.string:replace;

    version(Windows)
        enum lb = "\r\n";
    else
        enum lb = "\n";
    return stripComments(sdlData).replace("\\"~lb, " ").replace("`"~lb, "`");
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

	JSONValue v = sdlToJSON(parseSDL(null, testSdl));

	import std.stdio;
	writeln = v["description"].toString;

}