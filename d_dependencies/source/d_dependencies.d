module d_dependencies;

import std.system : OS, ISA, Endian, os, instructionSetArchitecture, endian;

struct ModuleDef
{
	//Ordered by alignment/size to keep the struct compact.
	string modName;
	string modPath;
	///Human-readable reasons behind isDoubtful().
	string[] doubts;
	ModuleDef[string] importedBy;
	ModuleDef[string] imports;
	///Approximate front-end work. Used only to decide whether probing a build
	///strategy is worth it.
	uint compileWeight;

	private enum ModuleFlag : uint
	{
		isExternal = 1 << 0,
		hasUnknownConditionals = 1 << 1,
		hasUnresolvedMixins = 1 << 2,
		hasUnresolvedStringMixins = 1 << 3,
		hasUnknownVersionIdentifiers = 1 << 4,
		conservativeWeight = 1 << 5,
		usedTrustedNoImportMixin = 1 << 6
	}
	private uint flags;

	private void setFlag(ModuleFlag flag, bool value) pure nothrow @safe
	{
		if(value)
			flags |= flag;
		else
			flags &= ~flag;
	}

	///Set when the module is only imported and has no source in the scanned package.
	@property bool isExternal() const pure nothrow @safe { return (flags & ModuleFlag.isExternal) != 0; }
	@property void isExternal(bool value) pure nothrow @safe { setFlag(ModuleFlag.isExternal, value); }
	///Some static if could not be decided; both branches were kept.
	@property bool hasUnknownConditionals() const pure nothrow @safe { return (flags & ModuleFlag.hasUnknownConditionals) != 0; }
	@property void hasUnknownConditionals(bool value) pure nothrow @safe { setFlag(ModuleFlag.hasUnknownConditionals, value); }
	///A mixin expansion could not be resolved, so its imports may be missing.
	@property bool hasUnresolvedMixins() const pure nothrow @safe { return (flags & ModuleFlag.hasUnresolvedMixins) != 0; }
	@property void hasUnresolvedMixins(bool value) pure nothrow @safe { setFlag(ModuleFlag.hasUnresolvedMixins, value); }
	///A string mixin could not be expanded at all.
	@property bool hasUnresolvedStringMixins() const pure nothrow @safe { return (flags & ModuleFlag.hasUnresolvedStringMixins) != 0; }
	@property void hasUnresolvedStringMixins(bool value) pure nothrow @safe { setFlag(ModuleFlag.hasUnresolvedStringMixins, value); }
	///A version/debug identifier wasn't present in the scan context.
	@property bool hasUnknownVersionIdentifiers() const pure nothrow @safe { return (flags & ModuleFlag.hasUnknownVersionIdentifiers) != 0; }
	@property void hasUnknownVersionIdentifiers(bool value) pure nothrow @safe { setFlag(ModuleFlag.hasUnknownVersionIdentifiers, value); }
	@property bool conservativeWeight() const pure nothrow @safe { return (flags & ModuleFlag.conservativeWeight) != 0; }
	@property void conservativeWeight(bool value) pure nothrow @safe { setFlag(ModuleFlag.conservativeWeight, value); }
	///A trusted no-import mixin template was expanded here.
	@property bool usedTrustedNoImportMixin() const pure nothrow @safe { return (flags & ModuleFlag.usedTrustedNoImportMixin) != 0; }
	@property void usedTrustedNoImportMixin(bool value) pure nothrow @safe { setFlag(ModuleFlag.usedTrustedNoImportMixin, value); }

	///True when the import list may be incomplete or conservative.
	bool isDoubtful() const
	{
		return doubts.length != 0 || hasUnknownConditionals || hasUnresolvedMixins ||
			hasUnresolvedStringMixins || hasUnknownVersionIdentifiers;
	}

	///We cannot evaluate these mixins; imports may be missing.
	bool isUnsupported() const { return hasUnresolvedMixins || hasUnresolvedStringMixins; }
	///A mixin has import evidence but could not be resolved; graph edges may be missing.
	bool isImportRisk() const { return hasUnresolvedMixins; }
	///An undecidable condition kept both branches; imports may be extra.
	bool isConservative() const { return hasUnknownConditionals; }
	///A version/debug flag wasn't in the scan context.
	bool isContextDependent() const { return hasUnknownVersionIdentifiers; }

	string getImportedByChain(int level = 1)
	{
		string chain = modName;
		foreach(string path, ModuleDef parent; importedBy)
		{
			// foreach(_; 0..level)
			// 	ident~= "\t";
			// chain~= "\n"~ident~parent.modName
			chain~= "<-"~parent.getImportedByChain();
		}
		return chain;
	}

	package void addImport(ref ModuleDef imported)
	{
		imported.importedBy[modPath] = this;
		imports[imported.modPath] = imported;
	}
}

class ModuleParsing
{
	ModuleDef[string] allModules;
	private ModuleDef*[string] modulesByModuleName;

	ModuleDef* getModuleInCache(string moduleName, string modulePath)
	{
		ModuleDef* ret = modulePath in allModules;
		if(!ret)
		{
			allModules[modulePath] = ModuleDef(moduleName, modulePath);
			modulesByModuleName[moduleName] = modulePath in allModules;
			ret = modulePath in allModules;
		}
		return ret;
	}

	ModuleDef* fromModuleName(const(char)[] moduleName)
	{
		ModuleDef** ret = (moduleName in modulesByModuleName);
		if(!ret)
			return null;
		return *ret;
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
		void findDependeesImpl(ModuleDef* input, ref ModuleDef[] ret, ref bool[string] visited)
		{
			foreach(modPath, ref modDef; input.importedBy)
			{
				if(!(modPath in visited))
				{
					visited[modPath] = true;
					///importedBy stores copies taken before the importer had
					///imports of its own, so use the live module from the graph.
					ModuleDef* live = modPath in allModules;
					ModuleDef* target = live is null ? &modDef : live;
					ret~= *target;
					findDependeesImpl(target, ret, visited);
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

private struct DSourceScanner
{
	string src;
	size_t pos;

	bool empty() const { return pos >= src.length; }
	char front() const { return src[pos]; }

	static bool isIdentStart(char c)
	{
		return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || cast(ubyte)c >= 0x80;
	}
	static bool isIdentPart(char c)
	{
		return isIdentStart(c) || (c >= '0' && c <= '9');
	}

	bool skipComment()
	{
		if(pos + 1 >= src.length || src[pos] != '/')
			return false;
		char next = src[pos + 1];
		if(next == '/')
		{
			pos += 2;
			while(!empty && src[pos] != '\n') pos++;
			return true;
		}
		if(next == '*')
		{
			pos += 2;
			while(pos + 1 < src.length && !(src[pos] == '*' && src[pos + 1] == '/')) pos++;
			pos = pos + 1 < src.length ? pos + 2 : src.length;
			return true;
		}
		if(next == '+')
		{
			pos += 2;
			int depth = 1;
			while(!empty && depth)
			{
				if(pos + 1 < src.length && src[pos] == '/' && src[pos + 1] == '+') { depth++; pos += 2; }
				else if(pos + 1 < src.length && src[pos] == '+' && src[pos + 1] == '/') { depth--; pos += 2; }
				else pos++;
			}
			return true;
		}
		return false;
	}

	void skipSpaceAndComments()
	{
		while(!empty)
		{
			char c = src[pos];
			if(c == ' ' || c == '\t' || c == '\r' || c == '\n' || c == '\v' || c == '\f') { pos++; continue; }
			if(skipComment()) continue;
			break;
		}
	}

	string readIdentifier()
	{
		size_t start = pos;
		pos++;
		while(!empty && isIdentPart(src[pos])) pos++;
		return src[start..pos];
	}

	///pos is at the opening quote.
	void skipEscapedQuoted(char quote)
	{
		pos++;
		while(!empty)
		{
			char c = src[pos];
			if(c == '\\') { pos += 2; continue; }
			pos++;
			if(c == quote) break;
		}
	}

	///pos is at the opening quote. Raw strings, backticks and x-strings have no escapes.
	void skipRawQuoted(char quote)
	{
		pos++;
		while(!empty && src[pos] != quote) pos++;
		if(!empty) pos++;
	}

	///pos is at 'q' followed by '"'.
	void skipQDelimited()
	{
		pos += 2;
		if(empty) return;
		char delim = src[pos];
		char closing = delim;
		switch(delim)
		{
			case '(': closing = ')'; break;
			case '[': closing = ']'; break;
			case '{': closing = '}'; break;
			case '<': closing = '>'; break;
			default: break;
		}
		string identDelim;
		if(isIdentStart(delim))
		{
			size_t start = pos;
			pos++;
			while(!empty && isIdentPart(src[pos])) pos++;
			identDelim = src[start..pos];
		}
		else
			pos++;

		if(identDelim.length)
		{
			while(pos + identDelim.length <= src.length)
			{
				if(src[pos..pos + identDelim.length] == identDelim && pos + identDelim.length < src.length && src[pos + identDelim.length] == '"')
				{
					pos += identDelim.length + 1;
					return;
				}
				pos++;
			}
			pos = src.length;
			return;
		}

		while(pos + 1 < src.length)
		{
			if(src[pos] == closing && src[pos + 1] == '"')
			{
				pos += 2;
				return;
			}
			pos++;
		}
		pos = src.length;
	}

	///pos is at 'q' followed by '{'.
	void skipQBrace()
	{
		pos += 2;
		int depth = 1;
		while(!empty && depth)
		{
			char c = src[pos];
			if(c == '"') { skipEscapedQuoted('"'); continue; }
			if(c == '`') { skipRawQuoted('`'); continue; }
			if(c == '\'') { skipEscapedQuoted('\''); continue; }
			if(skipComment()) continue;
			if(c == '{') depth++;
			else if(c == '}') depth--;
			pos++;
		}
	}

}

private enum DTokenKind : ubyte { ident, number, literal, punct }

private bool isExpressionPrecedingToken(string text)
{
	switch(text)
	{
		case "return", "throw", "=", ",", "(", "[", "~", "!", "+", "-", "*", "/", "%",
			"&&", "||", "==", "!=", "<", ">", "<=", ">=", "?", ":", ".", "&", "|", "^", "=>":
			return true;
		default:
			return false;
	}
}

private struct DToken
{
	private immutable(char)* ptr;
	private uint len;
	DTokenKind kind;

	this(string text, DTokenKind kind)
	{
		this.ptr = text.ptr;
		this.len = cast(uint)text.length;
		this.kind = kind;
	}

	@property string text() const { return ptr[0 .. len]; }
	bool isChar(char c) const { return len == 1 && ptr[0] == c; }
}
static assert(DToken.sizeof == 16, "DToken must stay 16 bytes");

private void appendToken(ref DToken[] arr, ref size_t n, string text, DTokenKind kind)
{
	if(n == arr.length)
		arr.length = arr.length ? arr.length * 2 : 16;
	arr[n++] = DToken(text, kind);
}

private DToken[] tokenizeDSource(string source)
{
	DSourceScanner sc = DSourceScanner(source);
	DToken[] tokens;
	tokens.length = source.length / 6 + 16;
	size_t n;
	while(true)
	{
		sc.skipSpaceAndComments();
		if(sc.empty) break;
		size_t start = sc.pos;
		char c = sc.front;

		if((c == 'r' || c == 'x') && sc.pos + 1 < source.length && source[sc.pos + 1] == '"')
		{
			sc.pos++;
			sc.skipRawQuoted('"');
			appendToken(tokens, n, source[start .. sc.pos], DTokenKind.literal);
			continue;
		}
		if(c == 'q' && sc.pos + 1 < source.length)
		{
			if(source[sc.pos + 1] == '"') { sc.skipQDelimited(); appendToken(tokens, n, source[start .. sc.pos], DTokenKind.literal); continue; }
			if(source[sc.pos + 1] == '{') { sc.skipQBrace(); appendToken(tokens, n, source[start .. sc.pos], DTokenKind.literal); continue; }
		}
		if(c == '"') { sc.skipEscapedQuoted('"'); appendToken(tokens, n, source[start .. sc.pos], DTokenKind.literal); continue; }
		if(c == '`') { sc.skipRawQuoted('`'); appendToken(tokens, n, source[start .. sc.pos], DTokenKind.literal); continue; }
		if(c == '\'') { sc.skipEscapedQuoted('\''); appendToken(tokens, n, source[start .. sc.pos], DTokenKind.literal); continue; }

		if(DSourceScanner.isIdentStart(c))
		{
			string ident = sc.readIdentifier();
			if(ident == "__EOF__")
				break;
			appendToken(tokens, n, ident, DTokenKind.ident);
			continue;
		}
		if(c >= '0' && c <= '9')
		{
			sc.pos++;
			while(!sc.empty && (DSourceScanner.isIdentPart(sc.front) || sc.front == '.')) sc.pos++;
			appendToken(tokens, n, source[start .. sc.pos], DTokenKind.number);
			continue;
		}

		char next = sc.pos + 1 < source.length ? source[sc.pos + 1] : '\0';
		string op;
		switch(c)
		{
			case '&': if(next == '&') op = "&&"; break;
			case '|': if(next == '|') op = "||"; break;
			case '=': if(next == '=') op = "=="; else if(next == '>') op = "=>"; break;
			case '!': if(next == '=') op = "!="; break;
			case '<': if(next == '=') op = "<="; else if(next == '<') op = "<<"; break;
			case '>': if(next == '=') op = ">="; else if(next == '>') op = ">>"; break;
			case '.': if(next == '.') op = ".."; break;
			case '^': if(next == '^') op = "^^"; break;
			default: break;
		}
		if(op.length)
		{
			appendToken(tokens, n, op, DTokenKind.punct);
			sc.pos += op.length;
			continue;
		}
		appendToken(tokens, n, source[sc.pos .. sc.pos + 1], DTokenKind.punct);
		sc.pos++;
	}
	tokens.length = n;
	return tokens;
}

private struct CompileWeight
{
	size_t value;
	bool conservative;
}

private long weightNumber(string text)
{
	import std.conv : to;
	import std.string : replace, endsWith;
	string value = text.replace("_", "");
	while(value.length && (value[$ - 1] == 'u' || value[$ - 1] == 'U'
		|| value[$ - 1] == 'l' || value[$ - 1] == 'L'))
		value = value[0 .. $ - 1];
	try
	{
		if(value.length > 1 && value[0 .. 2] == "0x")
			return to!long(value[2 .. $], 16);
		return to!long(value);
	}
	catch(Exception) { return -1; }
}

///Very rough compile-cost prior: tokens plus known expensive constructs.
///Unknown static foreach/mixin values are treated conservatively.
private CompileWeight computeCompileWeight(DToken[] tokens)
{
	enum size_t maxIterations = 10_000_000;
	CompileWeight ret;
	ret.value = tokens.length;
	foreach(i, tok; tokens)
	{
		if(tok.kind == DTokenKind.ident && tok.text == "static"
			&& i + 1 < tokens.length && tokens[i + 1].text == "foreach")
		{
			size_t open = i + 2;
			while(open < tokens.length && tokens[open].text != "(") open++;
			long start = -1;
			long end = -1;
			if(open < tokens.length)
			{
				for(size_t j = open + 1; j < tokens.length && tokens[j].text != ")"; j++)
				{
					if(tokens[j].text == "..")
					{
						if(j > open + 1 && tokens[j - 1].kind == DTokenKind.number)
							start = weightNumber(tokens[j - 1].text);
						if(j + 1 < tokens.length && tokens[j + 1].kind == DTokenKind.number)
							end = weightNumber(tokens[j + 1].text);
						break;
					}
				}
			}
			if(start >= 0 && end >= start)
			{
				size_t iterations = cast(size_t)end - cast(size_t)start;
				if(iterations > maxIterations) iterations = maxIterations;
				ret.value += iterations * 100;
			}
			else
			{
				ret.conservative = true;
				ret.value += maxIterations;
			}
		}
		else if(tok.kind == DTokenKind.ident && tok.text == "mixin")
		{
			if(i + 1 < tokens.length && tokens[i + 1].kind == DTokenKind.literal)
			{
				size_t payload = tokens[i + 1].text.length;
				if(payload > 100_000) payload = 100_000;
				ret.value += payload * 10;
			}
			else
			{
				ret.conservative = true;
				ret.value += 100_000;
			}
		}
	}
	return ret;
}

private string tokensText(DToken[] tokens)
{
	import std.array : join;
	string[] parts;
	foreach(tok; tokens)
		parts ~= tok.text;
	return join(parts, " ");
}

private string shorten(string text, size_t maxLength = 240)
{
	return text.length > maxLength ? text[0 .. maxLength] ~ "..." : text;
}

private enum ConditionValue : ubyte { no, yes, unknown }

private ConditionValue andValue(ConditionValue a, ConditionValue b)
{
	if(a == ConditionValue.no || b == ConditionValue.no) return ConditionValue.no;
	if(a == ConditionValue.unknown || b == ConditionValue.unknown) return ConditionValue.unknown;
	return ConditionValue.yes;
}

private ConditionValue orValue(ConditionValue a, ConditionValue b)
{
	if(a == ConditionValue.yes || b == ConditionValue.yes) return ConditionValue.yes;
	if(a == ConditionValue.unknown || b == ConditionValue.unknown) return ConditionValue.unknown;
	return ConditionValue.no;
}

private ConditionValue notValue(ConditionValue v)
{
	final switch(v)
	{
		case ConditionValue.yes: return ConditionValue.no;
		case ConditionValue.no: return ConditionValue.yes;
		case ConditionValue.unknown: return ConditionValue.unknown;
	}
}

///Manifest constants (enum/static const) used to resolve `static if` conditions.
private enum ConstantImportStatus
{
	unknown,
	safe,
}

private class ConstantTable
{
	private struct Entry
	{
		string name;
		DToken[] expr;
	}
	private Entry[string] entries;
	private bool[string] ambiguous;
	private ConditionValue[string] cache;
	private bool[string] resolving;
	private bool[string] resolvingImports;
	///Per-file tables delegate resolution to the package-wide table.
	ConstantTable parent;

	bool has(string name) const { return (name in entries) !is null || (parent !is null && parent.has(name)); }

	void add(string name, DToken[] expr)
	{
		if(name in entries)
		{
			auto old = entries[name].expr;
			bool same = old.length == expr.length;
			if(same)
				foreach(j; 0 .. expr.length)
					if(old[j].text != expr[j].text) { same = false; break; }
			if(!same)
				ambiguous[name] = true;
		}
		else
			entries[name] = Entry(name, expr);
		if(parent !is null)
			parent.add(name, expr);
	}

	ConditionValue resolve(string name)
	{
		if(name in cache) return cache[name];
		if(name in ambiguous) return ConditionValue.unknown;
		if(!(name in entries))
			return parent !is null ? parent.resolve(name) : ConditionValue.unknown;
		if(name in resolving) return ConditionValue.unknown;
		resolving[name] = true;
		StaticIfEvaluator evaluator = StaticIfEvaluator(entries[name].expr);
		evaluator.constants = this;
		// compilerVersion is not available here; constant expressions rarely use __VERSION__.

		ConditionValue value = evaluator.parse();
		resolving.remove(name);
		cache[name] = value;
		return value;
	}

	///Directories searched by import("file") in constant expressions.
	string[] stringImportPaths;
	private string[string] stringCache;
	private bool[string] resolvingStrings;

	bool readStringImport(string file, out string content)
	{
		import std.file : exists, readText;
		import std.path : isAbsolute, buildNormalizedPath;

		if(isAbsolute(file))
		{
			try
			{
				content = readText(file);
				return true;
			}
			catch(Exception)
				return false;
		}
		foreach(dir; stringImportPaths)
		{
			string path = buildNormalizedPath(dir, file);
			if(!exists(path)) continue;
			try
			{
				content = readText(path);
				return true;
			}
			catch(Exception) {}
		}
		if(exists(file))
		{
			try
			{
				content = readText(file);
				return true;
			}
			catch(Exception) {}
		}
		return false;
	}

	///Estimates imports for a constant whose initializer is not a simple
	///string (e.g. a CTFE function literal). Scans all string literals in the
	///initializer: complete imports are added, dynamic import evidence is
	///unknown, and no import evidence is safe.
	ConstantImportStatus importStatus(string name, ImportScanContext ctx,
		ref string[] imports)
	{
		import std.string : indexOf;
		if(name in ambiguous) return ConstantImportStatus.unknown;
		if(!(name in entries))
			return parent !is null ? parent.importStatus(name, ctx, imports)
				: ConstantImportStatus.unknown;
		if(name in resolvingImports) return ConstantImportStatus.unknown;
		resolvingImports[name] = true;
		scope(exit) resolvingImports.remove(name);
		DToken[] expr = entries[name].expr;
		string literals;
		foreach(size_t j; 0 .. expr.length)
		{
			auto token = expr[j];
			if(token.text == "mixin")
				return ConstantImportStatus.unknown;
			if(token.text == "import" && j + 1 < expr.length
				&& expr[j + 1].text == "(")
				return ConstantImportStatus.unknown;
			if(token.kind == DTokenKind.literal)
			{
				string decoded;
				if(decodeDLiteral(token.text, decoded))
					literals ~= decoded;
			}
			if(token.kind == DTokenKind.ident && token.text != name
				&& token.text in entries)
			{
				auto sub = importStatus(token.text, ctx, imports);
				if(sub != ConstantImportStatus.safe) return sub;
			}
		}
		if(indexOf(literals, "import") == -1)
			return ConstantImportStatus.safe;
		if(literalImports(literals, ctx, imports))
			return ConstantImportStatus.safe;
		return ConstantImportStatus.unknown;
	}

	bool resolveString(string name, out string value)
	{
		import std.array : join;

		if(name in stringCache)
		{
			value = stringCache[name];
			return true;
		}
		if(name in ambiguous) return false;
		if(!(name in entries))
			return parent !is null ? parent.resolveString(name, value) : false;
		if(name in resolvingStrings) return false;
		resolvingStrings[name] = true;
		string[] parts;
		bool ok = true;
		DToken[] expr = entries[name].expr;
		for(size_t j = 0; j < expr.length && ok;)
		{
			if(expr[j].text == "~") { j++; continue; }
			if(expr[j].kind == DTokenKind.literal)
			{
				string decoded;
				if(!decodeDLiteral(expr[j].text, decoded)) { ok = false; break; }
				parts ~= decoded;
				j++;
				continue;
			}
			if(expr[j].kind == DTokenKind.ident && expr[j].text == "import"
				&& j + 3 < expr.length && expr[j + 1].text == "("
				&& expr[j + 2].kind == DTokenKind.literal && expr[j + 3].text == ")")
			{
				string file, content;
				if(!decodeDLiteral(expr[j + 2].text, file) || !readStringImport(file, content))
				{
					ok = false;
					break;
				}
				parts ~= content;
				j += 4;
				continue;
			}
			if(expr[j].kind == DTokenKind.ident)
			{
				string sub;
				if(!resolveString(expr[j].text, sub)) { ok = false; break; }
				parts ~= sub;
				j++;
				continue;
			}
			ok = false;
		}
		resolvingStrings.remove(name);
		if(!ok) return false;
		value = join(parts, "");
		stringCache[name] = value;
		return true;
	}
}

private struct StaticIfEvaluator
{
	DToken[] tokens;
	size_t i;
	ConstantTable constants;
	int compilerVersion;

	bool empty() const { return i >= tokens.length; }
	string cur() const { return empty ? null : tokens[i].text; }
	bool eat(string text) { if(!empty && tokens[i].text == text) { i++; return true; } return false; }

	ConditionValue parse()
	{
		return parseOr();
	}

	ConditionValue parseOr()
	{
		ConditionValue v = parseAnd();
		while(eat("||"))
			v = orValue(v, parseAnd());
		return v;
	}

	ConditionValue parseAnd()
	{
		ConditionValue v = parseUnary();
		while(eat("&&"))
			v = andValue(v, parseUnary());
		return v;
	}

	ConditionValue parseUnary()
	{
		if(eat("!")) return notValue(parseUnary());
		return parsePrimary();
	}

	private bool parseIntegerToken(string text, out long value)
	{
		import std.conv : to;
		import std.string : replace;
		try
		{
			value = to!long(replace(text, "_", ""));
			return true;
		}
		catch(Exception)
			return false;
	}

	private int builtinSizeof(string type) const
	{
		switch(type)
		{
			case "bool": return bool.sizeof;
			case "byte", "ubyte", "char": return 1;
			case "short", "ushort", "wchar": return 2;
			case "int", "uint", "float", "dchar": return 4;
			case "long", "ulong", "double": return 8;
			case "size_t": return cast(int) size_t.sizeof;
			case "ptrdiff_t": return cast(int) ptrdiff_t.sizeof;
			case "real": return real.sizeof;
			default: return -1;
		}
	}

	private ConditionValue compareIntegers(long left, string op, long right) const
	{
		switch(op)
		{
			case "==": return left == right ? ConditionValue.yes : ConditionValue.no;
			case "!=": return left != right ? ConditionValue.yes : ConditionValue.no;
			case "<": return left < right ? ConditionValue.yes : ConditionValue.no;
			case "<=": return left <= right ? ConditionValue.yes : ConditionValue.no;
			case ">": return left > right ? ConditionValue.yes : ConditionValue.no;
			case ">=": return left >= right ? ConditionValue.yes : ConditionValue.no;
			default: return ConditionValue.unknown;
		}
	}

	private bool tryVersionComparison(out ConditionValue result)
	{
		if(compilerVersion == 0 || empty() || cur() != "__VERSION__") return false;
		if(i + 2 >= tokens.length) return false;
		long rhs;
		if(!parseIntegerToken(tokens[i + 2].text, rhs)) return false;
		result = compareIntegers(compilerVersion, tokens[i + 1].text, rhs);
		if(result == ConditionValue.unknown) return false;
		i += 3;
		return true;
	}

	private bool trySizeofComparison(out ConditionValue result)
	{
		if(empty() || tokens[i].kind != DTokenKind.ident) return false;
		int left = builtinSizeof(tokens[i].text);
		if(left < 0) return false;
		if(i + 4 >= tokens.length) return false;
		if(tokens[i + 1].text != "." || tokens[i + 2].text != "sizeof") return false;
		long rhs;
		if(!parseIntegerToken(tokens[i + 4].text, rhs)) return false;
		result = compareIntegers(left, tokens[i + 3].text, rhs);
		if(result == ConditionValue.unknown) return false;
		i += 5;
		return true;
	}

	ConditionValue parsePrimary()
	{
		if(empty()) return ConditionValue.unknown;
		ConditionValue targeted;
		if(tryVersionComparison(targeted) || trySizeofComparison(targeted))
			return targeted;
		if(eat("("))
		{
			ConditionValue v = parseOr();
			eat(")");
			return v;
		}
		if(eat("true")) return ConditionValue.yes;
		if(eat("false")) return ConditionValue.no;
		if(tokens[i].kind == DTokenKind.number)
		{
			import std.conv : to;
			string text = tokens[i].text;
			i++;
			try
				return to!long(text) != 0 ? ConditionValue.yes : ConditionValue.no;
			catch(Exception)
				return ConditionValue.unknown;
		}
		if(tokens[i].kind == DTokenKind.ident && constants !is null)
		{
			string name = tokens[i].text;
			bool callLike = i + 1 < tokens.length &&
				(tokens[i + 1].text == "(" || tokens[i + 1].text == "!" || tokens[i + 1].text == ".");
			if(!callLike && constants.has(name))
			{
				i++;
				return constants.resolve(name);
			}
		}
		// Anything else (is(...), __traits(...), template parameters...) is unknown.
		i++;
		if(!empty && cur() == "(")
			skipParens();
		return ConditionValue.unknown;
	}

	void skipParens()
	{
		int depth;
		while(!empty())
		{
			if(cur() == "(") depth++;
			else if(cur() == ")") { depth--; i++; if(depth == 0) return; continue; }
			i++;
		}
	}
}

/**
 * Compile-time information used to decide version/debug/static if branches.
 * versions and debugVersions are keys, not arrays, so lookups stay cheap.
 */
struct ImportScanContext
{
	bool[string] versions;
	bool[string] debugVersions;
	///Predefined names known to exist, even when their value is false.
	bool[string] knownVersions;
	///Debug identifiers known to exist, even when they are disabled.
	bool[string] knownDebugVersions;
	bool debugMode;
	bool unittestMode;
	bool releaseMode;
	bool coverageMode;
	bool profileMode;
	bool profileGCMode;
	bool noBoundsChecks;
	bool optimized;
	bool betterC;
	///Named mixin templates the user asserts import nothing.
	bool[string] trustedNoImportMixins;
	///Treat identifiers absent from known/active sets as known false, not doubtful.
	bool assumeUnknownVersionsKnown;
	///Value of __VERSION__ while compiling the scanned code.
	int compilerVersion;
	///Directories searched by import("file") expressions.
	string[] stringImportPaths;

	void addVersion(string name)
	{
		versions[name] = true;
		knownVersions[name] = true;
	}

	void addDebugVersion(string name)
	{
		debugVersions[name] = true;
	}

	///Marks a version as known-but-disabled, avoiding the unknown-version warning.
	void addKnownVersion(string name)
	{
		knownVersions[name] = true;
	}

	///Marks a debug identifier as known-but-disabled.
	void addKnownDebugVersion(string name)
	{
		knownDebugVersions[name] = true;
	}

	void addTrustedNoImportMixin(string name)
	{
		trustedNoImportMixins[name] = true;
	}
}

/**
 * Populates the context with the predefined version identifiers of the
 * platform running the scanner. Override it for cross-compilation.
 */
private void addOSVersions(ref ImportScanContext ctx, OS os, ISA isa)
{
	switch(os)
	{
		case OS.win32:
		case OS.win64:
			ctx.versions["Windows"] = true;
			if(os == OS.win32)
				ctx.versions["Win32"] = true;
			else
				ctx.versions["Win64"] = true;
			break;
		case OS.linux:
			ctx.versions["linux"] = true;
			ctx.versions["Posix"] = true;
			break;
		case OS.android:
			ctx.versions["Android"] = true;
			ctx.versions["linux"] = true;
			ctx.versions["Posix"] = true;
			break;
		case OS.osx:
			ctx.versions["OSX"] = true;
			ctx.versions["Posix"] = true;
			break;
		case OS.iOS:
			ctx.versions["iOS"] = true;
			ctx.versions["Posix"] = true;
			break;
		case OS.tvOS:
			ctx.versions["TVOS"] = true;
			ctx.versions["Posix"] = true;
			break;
		case OS.watchOS:
			ctx.versions["WatchOS"] = true;
			ctx.versions["Posix"] = true;
			break;
		case OS.freeBSD:
			ctx.versions["FreeBSD"] = true;
			ctx.versions["Posix"] = true;
			break;
		case OS.netBSD:
			ctx.versions["NetBSD"] = true;
			ctx.versions["Posix"] = true;
			break;
		case OS.openBSD:
			ctx.versions["OpenBSD"] = true;
			ctx.versions["Posix"] = true;
			break;
		case OS.dragonFlyBSD:
			ctx.versions["DragonFlyBSD"] = true;
			ctx.versions["Posix"] = true;
			break;
		case OS.solaris:
			ctx.versions["Solaris"] = true;
			ctx.versions["Posix"] = true;
			break;
		static if (__traits(hasMember, OS, "haiku"))
		{
			case OS.haiku:
				ctx.versions["Haiku"] = true;
				ctx.versions["Posix"] = true;
				break;
		}
		case OS.otherPosix:
			ctx.versions["Posix"] = true;
			break;
		case OS.unknown:
			break;
		default:
			break;
	}
}

private void addISAVersions(ref ImportScanContext ctx, ISA isa, OS os)
{
	bool is64;
	switch(isa)
	{
		case ISA.x86:
			ctx.versions["X86"] = true;
			ctx.versions["D_InlineAsm_X86"] = true;
			break;
		case ISA.x86_64:
			ctx.versions["X86_64"] = true;
			ctx.versions["D_InlineAsm_X86_64"] = true;
			is64 = true;
			break;
		case ISA.arm:
			ctx.versions["ARM"] = true;
			break;
		case ISA.aarch64:
			ctx.versions["AArch64"] = true;
			is64 = true;
			break;
		case ISA.ppc:
			ctx.versions["PPC"] = true;
			ctx.versions["PPC_Any"] = true;
			break;
		case ISA.ppc64:
			ctx.versions["PPC64"] = true;
			ctx.versions["PPC_Any"] = true;
			is64 = true;
			break;
		case ISA.ia64:
			ctx.versions["IA64"] = true;
			is64 = true;
			break;
		case ISA.mips32:
			ctx.versions["MIPS32"] = true;
			ctx.versions["MIPS_Any"] = true;
			break;
		case ISA.mips64:
			ctx.versions["MIPS64"] = true;
			ctx.versions["MIPS_Any"] = true;
			is64 = true;
			break;
		case ISA.riscv32:
			ctx.versions["RISCV32"] = true;
			ctx.versions["RISCV_Any"] = true;
			break;
		case ISA.riscv64:
			ctx.versions["RISCV64"] = true;
			ctx.versions["RISCV_Any"] = true;
			is64 = true;
			break;
		case ISA.sparc:
			ctx.versions["SPARC"] = true;
			ctx.versions["SPARC_Any"] = true;
			break;
		case ISA.sparc64:
			ctx.versions["SPARC64"] = true;
			ctx.versions["SPARC_Any"] = true;
			is64 = true;
			break;
		case ISA.s390:
			ctx.versions["S390"] = true;
			ctx.versions["IBMZ_Any"] = true;
			break;
		case ISA.systemZ:
			ctx.versions["SystemZ"] = true;
			ctx.versions["IBMZ_Any"] = true;
			is64 = true;
			break;
		case ISA.hppa:
			ctx.versions["HPPA"] = true;
			ctx.versions["HPPA_Any"] = true;
			break;
		case ISA.hppa64:
			ctx.versions["HPPA64"] = true;
			ctx.versions["HPPA_Any"] = true;
			is64 = true;
			break;
		case ISA.sh:
			ctx.versions["SH"] = true;
			break;
		case ISA.alpha:
			ctx.versions["Alpha"] = true;
			break;
		static if (__traits(hasMember, ISA, "loongArch32"))
		{
			case ISA.loongArch32:
				ctx.versions["LoongArch_Any"] = true;
				break;
		}
		static if (__traits(hasMember, ISA, "loongArch64"))
		{
			case ISA.loongArch64:
				ctx.versions["LoongArch64"] = true;
				ctx.versions["LoongArch_Any"] = true;
				is64 = true;
				break;
		}
		static if (__traits(hasMember, ISA, "xtensa"))
		{
			case ISA.xtensa:
				ctx.versions["Xtensa"] = true;
				break;
		}
		case ISA.webAssembly:
			ctx.versions["WebAssembly"] = true;
			break;
		case ISA.asmJS:
			ctx.versions["Emscripten"] = true;
			break;
		case ISA.avr:
		case ISA.epiphany:
		case ISA.msp430:
		case ISA.nvptx:
		case ISA.nvptx64:
		case ISA.unknown:
			break;
		default:
			break;
	}
	if(is64)
		ctx.versions["D_LP64"] = true;
}

private void addCompilerVersions(ref ImportScanContext ctx, string compiler)
{
	if(compiler.length == 0)
	{
		version(DigitalMars) ctx.versions["DigitalMars"] = true;
		else version(LDC) ctx.versions["LDC"] = true;
		else version(GNU) ctx.versions["GNU"] = true;
		else version(Clang) ctx.versions["Clang"] = true;
		return;
	}
	import std.string : toLower, startsWith;
	string c = compiler.toLower;
	if(c.startsWith("dmd") || c.startsWith("digitalmars"))
		ctx.versions["DigitalMars"] = true;
	else if(c.startsWith("ldc") || c.startsWith("ldmd"))
		ctx.versions["LDC"] = true;
	else if(c.startsWith("gdc") || c.startsWith("gcc") || c.startsWith("gnu"))
		ctx.versions["GNU"] = true;
	else if(c.startsWith("sdc"))
		ctx.versions["SDC"] = true;
	else if(c.startsWith("clang"))
		ctx.versions["Clang"] = true;
}

private void addCRuntimeVersions(ref ImportScanContext ctx, OS os, string cRuntime)
{
	if(cRuntime.length)
	{
		import std.string : startsWith;
		string name = cRuntime.startsWith("CRuntime_") ? cRuntime : "CRuntime_" ~ cRuntime;
		ctx.versions[name] = true;
		return;
	}
	switch(os)
	{
		case OS.win32:
		case OS.win64:
			ctx.versions["CRuntime_Microsoft"] = true;
			break;
		case OS.linux:
			ctx.versions["CRuntime_Glibc"] = true;
			break;
		case OS.android:
			ctx.versions["CRuntime_Bionic"] = true;
			break;
		case OS.osx:
		case OS.iOS:
		case OS.tvOS:
		case OS.watchOS:
			break;
		case OS.freeBSD:
			ctx.versions["CRuntime_FreeBSD"] = true;
			break;
		case OS.netBSD:
			ctx.versions["CRuntime_NetBSD"] = true;
			break;
		case OS.openBSD:
			ctx.versions["CRuntime_OpenBSD"] = true;
			break;
		case OS.dragonFlyBSD:
			ctx.versions["CRuntime_DragonFlyBSD"] = true;
			break;
		case OS.solaris:
			ctx.versions["CRuntime_Solaris"] = true;
			break;
		static if (__traits(hasMember, OS, "haiku"))
		{
			case OS.haiku:
				ctx.versions["CRuntime_Haiku"] = true;
				break;
		}
		case OS.otherPosix:
		case OS.unknown:
			break;
		default:
			break;
	}
}

private void addEndianVersions(ref ImportScanContext ctx, Endian endian)
{
	if(endian == Endian.littleEndian)
		ctx.versions["LittleEndian"] = true;
	else
		ctx.versions["BigEndian"] = true;
}

/**
 * Builds a scan context for a target. This is what cross-compilation needs:
 * version(...) identifiers must follow the target OS/ISA/compiler, not the host.
 */
ImportScanContext importScanContextFor(OS targetOS, ISA targetISA,
	string targetCompiler = null, string cRuntime = null, int targetCompilerVersion = 0)
{
	Endian targetEndian = endian;
	switch(targetISA)
	{
		case ISA.s390, ISA.systemZ, ISA.sparc, ISA.sparc64:
			targetEndian = Endian.bigEndian;
			break;
		default:
			break;
	}
	return importScanContextFor(targetOS, targetISA, targetCompiler, cRuntime,
		targetCompilerVersion, targetEndian);
}

ImportScanContext importScanContextFor(OS targetOS, ISA targetISA,
	string targetCompiler, string cRuntime, int targetCompilerVersion, Endian targetEndian)
{
	ImportScanContext ctx;
	static immutable string[] predefinedVersions = [
		// OS / platform
		"Windows", "Win32", "Win64", "linux", "FreeBSD", "OSX", "iOS", "TVOS", "WatchOS",
		"VisionOS", "Android", "Solaris", "Haiku", "DragonFlyBSD", "NetBSD", "OpenBSD",
		"Posix", "AIX", "WASI", "Emscripten", "MinGW", "FreeStanding",
		// Architecture
		"X86", "X86_64", "ARM", "AArch64", "PPC", "PPC64", "s390", "SPARC", "SPARC64",
		"RISCV64", "HPPA", "IA64", "MIPS32", "MIPS64", "MSP430", "WebAssembly", "Wasm64",
		"ARM_HardFloat", "ARM_SoftFloat", "PPC_HardFloat", "PPC_SoftFloat",
		"MIPS_HardFloat", "MIPS_SoftFloat",
		"ARM_Any", "SPARC_Any", "PPC_Any", "MIPS_Any", "RISCV_Any", "HPPA_Any",
		"IBMZ_Any", "LoongArch_Any", "RISCV32", "S390", "SystemZ", "HPPA64", "LoongArch64",
		"Darwin", "Hurd", "POSIX", "WASIp1", "iOSDerived",
		"InlineAsm_X86_Any", "InlineAsm_X87", "InlineAsm_X87_MSVC",
		"D_X32", "Supported", "SH", "Alpha", "LoongArch32", "Xtensa",
		// Endianness
		"LittleEndian", "BigEndian",
		// Compiler
		"DigitalMars", "LDC", "GNU", "Clang", "SDC",
		"MARS", "SCPP", "SPP", "COMPILE", "HTOD", "IN_LLVM", "IN_GCC", "DMDLIB", "NoBackend",
		"__GNUC__", "_WIN32", "_WIN64", "_WINDLL", "_OS2",
		// Standard library / runtime build flags
		"StdUnittest", "StdDdoc", "CoreUnittest", "CoreDdoc", "D_Ddoc",
		// Language / runtime features
		"D_Version2", "D_Exceptions", "D_BetterC", "D_ModuleInfo", "D_TypeInfo",
		"D_InlineAsm_X86", "D_InlineAsm_X86_64", "D_SIMD", "D_LP64", "D_HardFloat",
		"D_SoftFloat", "D_PIC", "D_GC", "D_NoBoundsChecks", "D_Coverage", "D_Profile",
		"D_ProfileGC", "D_Optimized", "D_Invariants", "D_Asserts", "D_PreConditions",
		"D_PostConditions", "D_ObjectiveC", "D_NoMain", "D_Colors", "D_ErrorMessages",
		// C runtime
		"CRuntime_Microsoft", "CRuntime_Glibc", "CRuntime_Musl", "CRuntime_Bionic",
		"CRuntime_Newlib", "CRuntime_UClibc", "CRuntime_DigitalMars", "CRuntime_Android",
		"CRuntime_FreeBSD", "CRuntime_WASI", "CRuntime_OSX", "CRuntime_DragonFlyBSD",
		"CRuntime_NetBSD", "CRuntime_OpenBSD", "CRuntime_Solaris", "CRuntime_Haiku",
		"CppRuntime_Gcc", "CppRuntime_Clang", "CppRuntime_Microsoft", "CppRuntime_Sun",
		"CppRuntime_GNU", "CppRuntime_LLVM",
		// Special
		"all", "none", "unittest", "assert",
	];
	foreach(name; predefinedVersions)
		ctx.knownVersions[name] = true;

	addOSVersions(ctx, targetOS, targetISA);
	addISAVersions(ctx, targetISA, targetOS);
	addCompilerVersions(ctx, targetCompiler);
	addCRuntimeVersions(ctx, targetOS, cRuntime);
	addEndianVersions(ctx, targetEndian);

	version(D_SIMD) ctx.versions["D_SIMD"] = true;
	version(D_HardFloat) ctx.versions["D_HardFloat"] = true;
	version(D_SoftFloat) ctx.versions["D_SoftFloat"] = true;
	version(D_PIC) ctx.versions["D_PIC"] = true;
	version(D_BetterC) ctx.versions["D_BetterC"] = true;
	ctx.versions["D_Version2"] = true;
	ctx.compilerVersion = targetCompilerVersion ? targetCompilerVersion : __VERSION__;
	///Well-known standard library mixin templates. Their imports are limited to
	///standard library modules, so they cannot hide project dependencies.
	///Local definitions are still expanded first, so a project template with
	///the same name keeps its real body.
	static immutable string[] builtinTrustedNoImportMixins = [
		"basicExceptionCtors",
		"Proxy",
		"AllocatorState",
		"Signal",
		"ForwardStrings",
		"MSVCLinkDirectives",
		"SimpleDllMain",
	];
	foreach(name; builtinTrustedNoImportMixins)
		ctx.trustedNoImportMixins[name] = true;
	return ctx;
}

ImportScanContext defaultImportScanContext()
{
	return importScanContextFor(os, instructionSetArchitecture);
}

ImportScanContext defaultImportScanContext(OS targetOS, ISA targetISA)
{
	return importScanContextFor(targetOS, targetISA);
}

ImportScanContext defaultImportScanContext(OS targetOS, ISA targetISA,
	string targetCompiler, string cRuntime, int targetCompilerVersion, Endian targetEndian)
{
	return importScanContextFor(targetOS, targetISA, targetCompiler, cRuntime,
		targetCompilerVersion, targetEndian);
}

private struct MixinTemplateBody
{
	DToken[] tokens;
	///Keeps the source the token pointers refer to alive.
	string source;
	///Template parameter names, in declaration order.
	string[] params;
}

///Body of a string-returning function, used to prove simple mixin helpers do
///not emit imports without running CTFE.
private struct StringFunctionBody
{
	DToken[] tokens;
	///Keeps the source the token pointers refer to alive.
	string source;
	///Function parameter names, in declaration order.
	string[] params;
}

private struct DImportParser
{
	DToken[] tokens;
	size_t i;
	ImportScanContext ctx;
	MixinTemplateBody[string] templates;
	StringFunctionBody[][string] functions;
	bool[string] expandingTemplates;
	string[] imports;
	string moduleName;
	bool hasUnknownConditionals;
	bool hasUnresolvedMixins;
	bool hasUnresolvedStringMixins;
	bool hasUnknownVersionIdentifiers;
	bool usedTrustedNoImportMixin;
	string[] doubts;
	ConstantTable constants;
	bool collectConstants;
	///Collecting constants only: skip imports/doubts and local scopes, so
	///undecidable local `static if`s keep both branches (conservative).
	bool constantsOnly;
	string[string] stringParams;
	string[][string] arrayParams;

	this(DToken[] tokens, ImportScanContext ctx, MixinTemplateBody[string] templates)
	{
		this.tokens = tokens;
		//Share the read-only context; version/debug declarations copy on write.
		this.ctx = ctx;
		this.templates = templates;
	}

	bool eof() const { return i >= tokens.length; }
	string cur() const { return i < tokens.length ? tokens[i].text : null; }
	bool curIs(string text) const { return i < tokens.length && tokens[i].text == text; }

	void addImport(string name)
	{
		foreach(imp; imports)
			if(imp == name) return;
		imports ~= name;
	}

	void addDoubt(string reason)
	{
		if(constantsOnly) return;
		reason = shorten(reason);
		foreach(doubt; doubts)
			if(doubt == reason) return;
		doubts ~= reason;
	}

	bool isConstantType(string text) const
	{
		switch(text)
		{
			case "bool", "byte", "ubyte", "short", "ushort", "int", "uint", "long", "ulong",
				"cent", "ucent", "size_t", "ptrdiff_t", "char", "wchar", "dchar",
				"string", "wstring", "dstring", "float", "double", "real":
				return true;
			default:
				return false;
		}
	}

	bool tryParseConstantDeclaration(bool active)
	{
		if(!collectConstants || !active || eof) return false;
		string name;
		size_t exprStart;
		if(curIs("enum"))
		{
			size_t j = i + 1;
			if(j >= tokens.length || tokens[j].kind != DTokenKind.ident) return false;
			if(j + 1 < tokens.length && tokens[j + 1].text == "=")
			{
				name = tokens[j].text;
				exprStart = j + 2;
			}
			else if(j + 2 < tokens.length && tokens[j + 1].kind == DTokenKind.ident
				&& tokens[j + 2].text == "=" && isConstantType(tokens[j].text))
			{
				name = tokens[j + 1].text;
				exprStart = j + 3;
			}
			else
				return false;
		}
		else if(curIs("static") && i + 1 < tokens.length && tokens[i + 1].text == "const")
		{
			size_t j = i + 2;
			if(j >= tokens.length || tokens[j].kind != DTokenKind.ident) return false;
			if(j + 1 < tokens.length && tokens[j + 1].text == "=")
			{
				name = tokens[j].text;
				exprStart = j + 2;
			}
			else if(j + 2 < tokens.length && tokens[j + 1].kind == DTokenKind.ident
				&& tokens[j + 2].text == "=" && isConstantType(tokens[j].text))
			{
				name = tokens[j + 1].text;
				exprStart = j + 3;
			}
			else
				return false;
		}
		else if(curIs("const"))
		{
			size_t j = i + 1;
			if(j >= tokens.length || tokens[j].kind != DTokenKind.ident) return false;
			if(j + 1 < tokens.length && tokens[j + 1].text == "=")
			{
				name = tokens[j].text;
				exprStart = j + 2;
			}
			else if(j + 2 < tokens.length && tokens[j + 1].kind == DTokenKind.ident
				&& tokens[j + 2].text == "=" && isConstantType(tokens[j].text))
			{
				name = tokens[j + 1].text;
				exprStart = j + 3;
			}
			else
				return false;
		}
		else if(curIs("immutable") || (curIs("static") && i + 1 < tokens.length && tokens[i + 1].text == "immutable"))
		{
			size_t j = curIs("static") ? i + 2 : i + 1;
			if(j >= tokens.length || tokens[j].kind != DTokenKind.ident) return false;
			if(j + 1 < tokens.length && tokens[j + 1].text == "=")
			{
				name = tokens[j].text;
				exprStart = j + 2;
			}
			else if(j + 2 < tokens.length && tokens[j + 1].kind == DTokenKind.ident
				&& tokens[j + 2].text == "=" && isConstantType(tokens[j].text))
			{
				name = tokens[j + 1].text;
				exprStart = j + 3;
			}
			else
				return false;
		}
		else
			return false;

		size_t k = exprStart;
		int depth;
		while(k < tokens.length)
		{
			string t = tokens[k].text;
			if(t == "(" || t == "[" || t == "{") depth++;
			else if(t == ")" || t == "]" || t == "}")
			{
				depth--;
				if(depth < 0) return false;
			}
			else if(t == ";" && depth == 0) break;
			k++;
		}
		if(k >= tokens.length || tokens[k].text != ";" || k == exprStart)
			return false;
		constants.add(name, tokens[exprStart .. k]);
		i = k + 1;
		return true;
	}

	void parseAll()
	{
		while(i < tokens.length)
		{
			if(tokens[i].isChar('}')) { i++; continue; }
			parseDeclaration(true);
		}
	}

	void collectBlockTokens(out DToken[] bodyTokens)
	{
		size_t start = i + 1;
		int depth = 1;
		size_t j = start;
		for(; j < tokens.length; j++)
		{
			if(tokens[j].text == "{") depth++;
			else if(tokens[j].text == "}")
			{
				depth--;
				if(depth == 0) break;
			}
		}
		bodyTokens = tokens[start .. j];
		i = j < tokens.length ? j + 1 : j;
	}

	void collectToSemicolonTokens(out DToken[] bodyTokens)
	{
		size_t start = i;
		int depth;
		while(i < tokens.length)
		{
			string text = tokens[i].text;
			if(text == "(" || text == "[" || text == "{") depth++;
			else if(text == ")" || text == "]" || text == "}") depth--;
			i++;
			if(text == ";" && depth == 0) break;
		}
		bodyTokens = tokens[start .. i];
	}

	void parseStaticForeach(bool active)
	{
		i += 2; // static foreach
		if(!curIs("(")) return;
		DToken[] header;
		collectParens(header);
		size_t semi = header.length;
		int depth;
		for(size_t j = 0; j < header.length; j++)
		{
			string text = header[j].text;
			if(text == "(" || text == "[" || text == "{") depth++;
			else if(text == ")" || text == "]" || text == "}") depth--;
			else if(text == ";" && depth == 0) { semi = j; break; }
		}
		if(semi == header.length) return;
		string var;
		for(size_t j = 0; j < semi; j++)
			if(header[j].kind == DTokenKind.ident)
				var = header[j].text;
		string iterable;
		if(semi + 2 == header.length && header[semi + 1].kind == DTokenKind.ident)
			iterable = header[semi + 1].text;

		string[] iterableValues;
		bool hasIterableValues;
		if(iterable.length && (iterable in arrayParams))
		{
			iterableValues = arrayParams[iterable];
			hasIterableValues = true;
		}
		else if(semi + 1 < header.length && header[semi + 1].text == "["
			&& header[$ - 1].text == "]")
		{
			bool ok = true;
			foreach(tok; header[semi + 2 .. $ - 1])
			{
				if(tok.text == ",") continue;
				string value;
				if(tok.kind != DTokenKind.literal || !decodeDLiteral(tok.text, value))
				{
					ok = false;
					break;
				}
				iterableValues ~= value;
			}
			hasIterableValues = ok;
		}

		DToken[] bodyTokens;
		if(curIs("{")) collectBlockTokens(bodyTokens);
		else collectToSemicolonTokens(bodyTokens);

		if(hasIterableValues)
		{
			foreach(value; iterableValues)
			{
				DImportParser sub = DImportParser(bodyTokens, ctx, templates);
				sub.expandingTemplates = expandingTemplates;
				sub.constants = constants;
				sub.stringParams = stringParams.dup;
				sub.arrayParams = arrayParams.dup;
				if(var.length) sub.stringParams[var] = value;
				sub.parseAll();
				mergeFrom(sub);
			}
		}
		else
		{
			DImportParser sub = DImportParser(bodyTokens, ctx, templates);
			sub.expandingTemplates = expandingTemplates;
			sub.constants = constants;
			sub.stringParams = stringParams.dup;
			sub.arrayParams = arrayParams.dup;
			sub.parseAll();
			mergeFrom(sub);
		}
	}

	bool parseUnittestBlock(bool active)
	{
		if(i + 1 >= tokens.length || !tokens[i + 1].isChar('{'))
			return false;
		i++;
		if(active && ctx.unittestMode) parseBlock(true);
		else skipBlock();
		return true;
	}

	void parseDeclaration(bool active)
	{
		if(i >= tokens.length) return;
		string t = tokens[i].text;
		if(tryParseConstantDeclaration(active)) return;
		if(collectConstants && t == "template") { skipMixinTemplateDeclaration(); return; }
		if(tokens[i].isChar('{')) { if(active && !constantsOnly) parseBlock(true); else skipBlock(); return; }
		if(t == "version" || t == "debug") { parseVersionOrDebug(active); return; }
		if(t == "static" && i + 1 < tokens.length && tokens[i + 1].text == "if") { parseStaticIf(active); return; }
		if(t == "static" && i + 1 < tokens.length && tokens[i + 1].text == "foreach")
		{
			if(constantsOnly) skipStaticForeach();
			else parseStaticForeach(active);
			return;
		}
		if(t == "module")
		{
			if(constantsOnly) skipToSemicolon();
			else parseModuleDeclaration(active);
			return;
		}
		if(t == "import") { if(active && !constantsOnly) parseImport(); else skipToSemicolon(); return; }
		if(t == "mixin") { parseMixin(active, i > 0 && isExpressionPrecedingToken(tokens[i - 1].text)); return; }
		if(t == "unittest" && parseUnittestBlock(active)) return;
		i++;
	}

	void parseModuleDeclaration(bool active)
	{
		i++;
		if(active)
		{
			string name = readDottedName();
			if(name !is null) moduleName = name;
		}
		else
			skipToSemicolon();
	}

	void parseBlock(bool active)
	{
		i++;
		while(i < tokens.length && !tokens[i].isChar('}'))
			parseDeclaration(active);
		if(i < tokens.length) i++;
	}

	void skipBlock()
	{
		int depth;
		while(i < tokens.length)
		{
			if(tokens[i].isChar('{')) depth++;
			else if(tokens[i].isChar('}')) { depth--; i++; if(depth <= 0) return; continue; }
			i++;
		}
	}

	void skipStaticForeach()
	{
		i += 2; // static foreach
		if(i < tokens.length && tokens[i].isChar('(')) skipParens();
		if(i < tokens.length && tokens[i].isChar('{')) skipBlock();
		else skipToSemicolon();
	}

	void parseControlledStatement(bool active)
	{
		if(i >= tokens.length) return;
		if(tokens[i].isChar('{')) { if(active) parseBlock(true); else skipBlock(); return; }
		parseSingleDeclaration(active);
	}

	void parseSingleDeclaration(bool active)
	{
		while(i < tokens.length)
		{
			string t = tokens[i].text;
			if(tryParseConstantDeclaration(active)) return;
			if(tokens[i].isChar(';')) { i++; return; }
			if(tokens[i].isChar('{')) { if(active) parseBlock(true); else skipBlock(); return; }
			if(t == "version" || t == "debug") { parseVersionOrDebug(active); return; }
			if(t == "static" && i + 1 < tokens.length && tokens[i + 1].text == "if") { parseStaticIf(active); return; }
			if(t == "static" && i + 1 < tokens.length && tokens[i + 1].text == "foreach")
			{
				if(constantsOnly) skipStaticForeach();
				else parseStaticForeach(active);
				return;
			}
			if(t == "import") { if(active && !constantsOnly) parseImport(); else skipToSemicolon(); return; }
			if(t == "mixin") { parseMixin(active, i > 0 && isExpressionPrecedingToken(tokens[i - 1].text)); return; }
			if(t == "unittest" && parseUnittestBlock(active)) return;
			i++;
		}
	}

	ConditionValue evalVersion(string id, bool isDebug, bool active)
	{
		if(isDebug)
		{
			if(id in ctx.debugVersions) return ConditionValue.yes;
			if(active && !(id in ctx.knownDebugVersions) && !ctx.assumeUnknownVersionsKnown)
			{
				hasUnknownVersionIdentifiers = true;
				addDoubt("debug: " ~ id);
			}
			return ConditionValue.no;
		}
		if(id == "unittest") return ctx.unittestMode ? ConditionValue.yes : ConditionValue.no;
		if(id == "assert" || id == "D_Asserts") return ctx.releaseMode ? ConditionValue.no : ConditionValue.yes;
		if(id == "all") return ConditionValue.yes;
		if(id == "none") return ConditionValue.no;
		if(id == "D_Coverage") return ctx.coverageMode ? ConditionValue.yes : ConditionValue.no;
		if(id == "D_Profile") return ctx.profileMode ? ConditionValue.yes : ConditionValue.no;
		if(id == "D_ProfileGC") return ctx.profileGCMode ? ConditionValue.yes : ConditionValue.no;
		if(id == "D_NoBoundsChecks") return ctx.noBoundsChecks ? ConditionValue.yes : ConditionValue.no;
		if(id == "D_Optimized") return ctx.optimized ? ConditionValue.yes : ConditionValue.no;
		if(id == "D_BetterC") return ctx.betterC ? ConditionValue.yes : ConditionValue.no;
		if(id == "D_Exceptions" || id == "D_ModuleInfo" || id == "D_TypeInfo")
			return ctx.betterC ? ConditionValue.no : ConditionValue.yes;
		if(id == "D_Invariants" || id == "D_PreConditions" || id == "D_PostConditions")
			return ctx.releaseMode ? ConditionValue.no : ConditionValue.yes;
		if(id in ctx.versions) return ConditionValue.yes;
		if(active && !(id in ctx.knownVersions) && !ctx.assumeUnknownVersionsKnown)
		{
			hasUnknownVersionIdentifiers = true;
			addDoubt("version: " ~ id);
		}
		return ConditionValue.no;
	}

	void parseVersionOrDebug(bool active)
	{
		bool isDebug = curIs("debug");
		i++;
		if(i >= tokens.length) return;
		if(tokens[i].isChar('='))
		{
			i++;
			if(i < tokens.length && tokens[i].kind == DTokenKind.ident && active)
			{
				//Version/debug declarations are local to this parser; duplicate before writing.
				if(isDebug)
				{
					ctx.debugVersions = ctx.debugVersions.dup;
					ctx.debugVersions[tokens[i].text] = true;
				}
				else
				{
					ctx.versions = ctx.versions.dup;
					ctx.versions[tokens[i].text] = true;
				}
			}
			skipToSemicolon();
			return;
		}

		ConditionValue cond;
		if(curIs("("))
		{
			DToken[] inner;
			collectParens(inner);
			if(inner.length == 1 && inner[0].kind == DTokenKind.ident)
				cond = evalVersion(inner[0].text, isDebug, active);
			else
				cond = ConditionValue.no;
		}
		else
			cond = isDebug ? (ctx.debugMode ? ConditionValue.yes : ConditionValue.no) : ConditionValue.no;

		if(curIs(":"))
		{
			i++;
			if(!active || cond != ConditionValue.yes)
				skipToScopeEnd();
			return;
		}
		parseControlledStatement(active && cond == ConditionValue.yes);
		if(curIs("else"))
		{
			i++;
			parseControlledStatement(active && cond != ConditionValue.yes);
		}
	}

	void parseStaticIf(bool active)
	{
		i += 2; // static if
		ConditionValue cond = ConditionValue.unknown;
		string conditionText;
		DToken[] inner;
		if(curIs("("))
		{
			collectParens(inner);
			StaticIfEvaluator evaluator = StaticIfEvaluator(inner);
			evaluator.constants = constants;
			evaluator.compilerVersion = ctx.compilerVersion;
			cond = evaluator.parse();
		}
		if(curIs(":"))
		{
			i++;
			if(!active || cond == ConditionValue.no)
				skipToScopeEnd();
			else if(cond == ConditionValue.unknown && !constantsOnly)
			{
				hasUnknownConditionals = true;
				if(conditionText.length == 0) conditionText = tokensText(inner);
				addDoubt("static if: " ~ conditionText);
			}
			return;
		}
		size_t importsBefore = imports.length;
		// Unknown conditions keep both branches: an union is safer than dropping an import.
		parseControlledStatement(active && cond != ConditionValue.no);
		if(curIs("else"))
		{
			i++;
			parseControlledStatement(active && cond != ConditionValue.yes);
		}
		//Only doubtful if the undecidable condition actually gates an import.
		if(active && cond == ConditionValue.unknown && imports.length != importsBefore)
		{
			hasUnknownConditionals = true;
			if(conditionText.length == 0) conditionText = tokensText(inner);
			addDoubt("static if: " ~ conditionText);
		}
	}

	void collectParens(out DToken[] inner)
	{
		i++; // (
		size_t start = i;
		int depth = 1;
		while(i < tokens.length)
		{
			if(tokens[i].isChar('(')) depth++;
			else if(tokens[i].isChar(')')) { depth--; if(depth == 0) break; }
			i++;
		}
		inner = tokens[start .. i];
		if(i < tokens.length) i++; // )
	}

	void skipParens()
	{
		int depth;
		while(i < tokens.length)
		{
			if(tokens[i].isChar('(')) depth++;
			else if(tokens[i].isChar(')')) { depth--; i++; if(depth == 0) return; continue; }
			i++;
		}
	}

	void skipToSemicolon()
	{
		while(i < tokens.length)
		{
			if(tokens[i].isChar(';')) { i++; return; }
			if(tokens[i].isChar('{')) { skipBlock(); continue; }
			i++;
		}
	}

	///A false `version(X):` disables the rest of the current scope.
	void skipToScopeEnd()
	{
		int depth;
		while(i < tokens.length)
		{
			if(tokens[i].isChar('{')) depth++;
			else if(tokens[i].isChar('}'))
			{
				if(depth == 0) return;
				depth--;
				i++;
				continue;
			}
			i++;
		}
	}

	string readDottedName()
	{
		if(i >= tokens.length || tokens[i].kind != DTokenKind.ident) return null;
		size_t start = i;
		size_t k = i + 1;
		size_t len = tokens[start].text.length;
		while(k + 1 < tokens.length && tokens[k].isChar('.') && tokens[k + 1].kind == DTokenKind.ident)
		{
			len += 1 + tokens[k + 1].text.length;
			k += 2;
		}
		char[] buf = new char[len];
		auto first = tokens[start].text;
		buf[0 .. first.length] = first[];
		size_t pos = first.length;
		k = start + 1;
		while(k + 1 < tokens.length && tokens[k].isChar('.') && tokens[k + 1].kind == DTokenKind.ident)
		{
			buf[pos++] = '.';
			auto seg = tokens[k + 1].text;
			buf[pos .. pos + seg.length] = seg[];
			pos += seg.length;
			k += 2;
		}
		i = k;
		return cast(string) buf;
	}

	void parseImport()
	{
		if(constantsOnly) { skipToSemicolon(); return; }
		i++; // import
		if(i >= tokens.length) return;
		if(tokens[i].isChar('(')) { skipParens(); return; } // import("file") expression
		while(i < tokens.length)
		{
			if(tokens[i].isChar(';')) { i++; return; }
			if(tokens[i].isChar(':')) { skipToSemicolon(); return; }
			if(tokens[i].isChar(',')) { i++; continue; }
			if(tokens[i].kind == DTokenKind.ident)
			{
				string name = readDottedName();
				if(i < tokens.length && tokens[i].isChar('='))
				{
					i++;
					string target = readDottedName();
					if(target !is null) name = target;
				}
				addImport(name);
				continue;
			}
			skipToSemicolon();
			return;
		}
	}

	void parseMixin(bool active, bool expressionContext)
	{
		size_t mixinStart = i;
		i++; // mixin
		if(i >= tokens.length) return;
		if(curIs("template"))
		{
			skipMixinTemplateDeclaration();
			return;
		}
		if(curIs("("))
		{
			DToken[] args;
			collectParens(args);
			if(active) expandStringMixin(args, expressionContext);
			return;
		}
		if(tokens[i].kind == DTokenKind.ident)
		{
			string name = tokens[i].text;
			i++;
			DToken[] templateArgs;
			if(i < tokens.length && tokens[i].isChar('!'))
			{
				i++;
				if(i < tokens.length && tokens[i].isChar('(')) collectParens(templateArgs);
				else if(i < tokens.length) { templateArgs ~= tokens[i]; i++; }
			}
			if(i < tokens.length && tokens[i].kind == DTokenKind.ident) i++; // mixin identifier
			if(i < tokens.length && tokens[i].isChar(';')) i++;
			if(active) expandTemplateMixin(name, templateArgs);
			return;
		}
		if(active && !constantsOnly)
		{
			hasUnresolvedMixins = true;
			addDoubt("mixin: " ~ tokensText(tokens[mixinStart .. i]));
		}
		skipToSemicolon();
	}

	void skipMixinTemplateDeclaration()
	{
		i++; // template
		while(i < tokens.length && !tokens[i].isChar('{')) i++;
		if(i < tokens.length) skipBlock();
	}

	DToken[][] splitTemplateArgs(DToken[] args)
	{
		DToken[][] chunks;
		size_t start;
		int depth;
		for(size_t j = 0; j < args.length; j++)
		{
			string text = args[j].text;
			if(text == "(" || text == "[" || text == "{") depth++;
			else if(text == ")" || text == "]" || text == "}") depth--;
			else if(text == "," && depth == 0)
			{
				chunks ~= args[start .. j];
				start = j + 1;
			}
		}
		if(start < args.length) chunks ~= args[start .. $];
		return chunks;
	}

	bool lookupString(string name, out string value)
	{
		if(name in stringParams)
		{
			value = stringParams[name];
			return true;
		}
		return constants !is null && constants.resolveString(name, value);
	}

	string[] splitLines(string text)
	{
		import std.array : split;
		import std.string : strip;
		string[] ret;
		foreach(line; split(text, "\n"))
		{
			line = strip(line);
			if(line.length) ret ~= line;
		}
		return ret;
	}

	void applyTemplateArgs(MixinTemplateBody* body, DToken[] args,
		ref string[string] strings, ref string[][string] arrays)
	{
		DToken[][] chunks = splitTemplateArgs(args);
		foreach(idx, param; body.params)
		{
			if(idx >= chunks.length) break;
			DToken[] chunk = chunks[idx];
			if(chunk.length == 0) continue;
			if(chunk.length == 1 && chunk[0].kind == DTokenKind.literal)
			{
				string value;
				if(decodeDLiteral(chunk[0].text, value)) strings[param] = value;
			}
			else if(chunk[0].text == "[" && chunk[$ - 1].text == "]")
			{
				string[] values;
				bool ok = true;
				foreach(tok; chunk[1 .. $ - 1])
				{
					if(tok.text == ",") continue;
					if(tok.kind != DTokenKind.literal) { ok = false; break; }
					string value;
					if(!decodeDLiteral(tok.text, value)) { ok = false; break; }
					values ~= value;
				}
				if(ok) arrays[param] = values;
			}
			else if(chunk.length == 4 && chunk[0].text == "splitLines"
				&& chunk[1].text == "(" && chunk[3].text == ")")
			{
				string text;
				bool ok;
				if(chunk[2].kind == DTokenKind.ident)
					ok = lookupString(chunk[2].text, text);
				else if(chunk[2].kind == DTokenKind.literal)
					ok = decodeDLiteral(chunk[2].text, text);
				if(ok) arrays[param] = splitLines(text);
			}
			else if(chunk.length == 1 && chunk[0].kind == DTokenKind.ident)
			{
				string value;
				if(lookupString(chunk[0].text, value)) strings[param] = value;
				else if(chunk[0].text in arrays) arrays[param] = arrays[chunk[0].text];
			}
		}
	}

	void expandTemplateMixin(string name, DToken[] args)
	{
		MixinTemplateBody* body = name in templates;
		if(body is null)
		{
			if(name in ctx.trustedNoImportMixins)
			{
				usedTrustedNoImportMixin = true;
				return;
			}
			if(!constantsOnly)
			{
				hasUnresolvedMixins = true;
				addDoubt("mixin template: " ~ name);
			}
			return;
		}
		if(name in expandingTemplates) return;
		expandingTemplates[name] = true;
		scope(exit) expandingTemplates.remove(name);
		string[string] strings = stringParams.dup;
		string[][string] arrays = arrayParams.dup;
		applyTemplateArgs(body, args, strings, arrays);
		DImportParser sub = DImportParser(body.tokens, ctx, templates);
		sub.expandingTemplates = expandingTemplates;
		sub.constants = constants;
		sub.functions = functions;
		sub.collectConstants = true;
		sub.constantsOnly = constantsOnly;
		sub.stringParams = strings;
		sub.arrayParams = arrays;
		sub.parseAll();
		mergeFrom(sub);
	}

	void expandStringMixin(DToken[] args, bool expressionContext)
	{
		import std.string : indexOf;
		string content;
		if(!extractMixinString(args, stringParams, constants, content))
		{
			//An unresolved string mixin cannot contribute constants.
			if(constantsOnly) return;
			///Literal/stringof-style expressions, complete literal imports, or
			///trusted/verified project helpers cannot introduce hidden imports.
			bool[string] visited;
			string[] foundImports;
			MixinExpressionStatus status = mixinExpressionStatus(args, functions,
				visited, ctx, constants, foundImports);
			if(args.length >= 2 && args[0].kind == DTokenKind.ident
				&& (args[1].text == "(" || args[1].text == "!"))
				if(args[0].text in ctx.trustedNoImportMixins)
				{
					usedTrustedNoImportMixin = true;
					status = MixinExpressionStatus.safe;
				}
			bool mayImport = status == MixinExpressionStatus.mayImport;
			bool unknown = status == MixinExpressionStatus.unknown;

			//Plain imports inside a delegate/lambda in the expression are real imports.
			DImportParser sub = DImportParser(args, ctx, templates);
			sub.expandingTemplates = expandingTemplates;
			sub.constants = constants;
			sub.functions = functions;
			sub.stringParams = stringParams.dup;
			sub.arrayParams = arrayParams.dup;
			sub.parseAll();
			mergeFrom(sub);
			if(sub.hasUnresolvedMixins || sub.hasUnresolvedStringMixins)
				unknown = true;

			foreach(imp; foundImports)
				addImport(imp);

			if(mayImport)
			{
				hasUnresolvedMixins = true;
				hasUnresolvedStringMixins = true;
				addDoubt("string mixin import: " ~ tokensText(args));
			}
			else if(unknown && !expressionContext)
			{
				hasUnresolvedStringMixins = true;
				addDoubt("string mixin: " ~ tokensText(args));
			}
			return;
		}
		DToken[] generated = tokenizeDSource(content);
		collectMixinTemplates(generated, content, templates);
		DImportParser sub = DImportParser(generated, ctx, templates);
		sub.expandingTemplates = expandingTemplates;
		sub.constants = constants;
		sub.functions = functions;
		sub.collectConstants = true;
		sub.constantsOnly = constantsOnly;
		sub.stringParams = stringParams.dup;
		sub.arrayParams = arrayParams.dup;
		sub.parseAll();
		mergeFrom(sub);
	}

	void mergeFrom(ref DImportParser sub)
	{
		if(constantsOnly) return;
		foreach(imp; sub.imports) addImport(imp);
		if(sub.hasUnknownConditionals) hasUnknownConditionals = true;
		if(sub.hasUnresolvedMixins) hasUnresolvedMixins = true;
		if(sub.hasUnresolvedStringMixins) hasUnresolvedStringMixins = true;
		if(sub.hasUnknownVersionIdentifiers) hasUnknownVersionIdentifiers = true;
		if(sub.usedTrustedNoImportMixin) usedTrustedNoImportMixin = true;
		foreach(doubt; sub.doubts)
			addDoubt(doubt);
	}
}

private string[] mixinLiterals(DToken[] args)
{
	string[] ret;
	foreach(tok; args)
	{
		if(tok.kind != DTokenKind.literal) continue;
		string decoded;
		if(decodeDLiteral(tok.text, decoded)) ret ~= decoded;
	}
	return ret;
}

private enum MixinExpressionStatus
{
	safe,
	mayImport,
	unknown,
}

private DToken[][] splitTopLevelCommas(DToken[] tokens)
{
	DToken[][] chunks;
	size_t start;
	int depth;
	for(size_t j = 0; j < tokens.length; j++)
	{
		string text = tokens[j].text;
		if(text == "(" || text == "[" || text == "{") depth++;
		else if(text == ")" || text == "]" || text == "}")
		{
			if(depth > 0) depth--;
		}
		else if(text == "," && depth == 0)
		{
			chunks ~= tokens[start .. j];
			start = j + 1;
		}
	}
	if(start < tokens.length)
		chunks ~= tokens[start .. $];
	return chunks;
}

///Resolves a call like `gen("name")` or `gen(KnownConstant)` to literal strings.
private bool literalCallArgs(DToken[] args, size_t openIndex, ConstantTable constants,
	out string[] literalArgs)
{
	int depth;
	size_t close = size_t.max;
	for(size_t j = openIndex; j < args.length; j++)
	{
		if(args[j].text == "(") depth++;
		else if(args[j].text == ")")
		{
			depth--;
			if(depth == 0) { close = j; break; }
		}
	}
	if(close == size_t.max)
		return false;
	literalArgs = new string[0];
	foreach(chunk; splitTopLevelCommas(args[openIndex + 1 .. close]))
	{
		string value;
		if(chunk.length == 1 && chunk[0].kind == DTokenKind.literal)
		{
			if(!decodeDLiteral(chunk[0].text, value))
				return false;
			literalArgs ~= value;
		}
		else if(chunk.length == 1 && chunk[0].kind == DTokenKind.ident
			&& constants !is null && constants.resolveString(chunk[0].text, value))
			literalArgs ~= value;
		else
			return false;
	}
	return true;
}

///Extracts imports from a literal snippet. Returns false when the snippet has
///import evidence that is not a complete declaration (e.g. `"import " ~ name`).
private bool literalImports(string text, ImportScanContext ctx, ref string[] imports)
{
	import std.string : indexOf;
	if(indexOf(text, "import") == -1)
		return true;
	auto info = scanDImportInfo(text, ctx);
	if(info.imports.length == 0)
		return false;
	foreach(imp; info.imports)
	{
		bool exists;
		foreach(existing; imports)
			if(existing == imp) { exists = true; break; }
		if(!exists) imports ~= imp;
	}
	return !info.hasUnresolvedMixins && !info.hasUnresolvedStringMixins;
}

///Classifies an unresolved mixin expression without running CTFE. Literal-only
///expressions and calls to verified project helpers are safe; known helpers
///that emit imports are `mayImport`; anything else (unknown calls/templates) is
///`unknown`.
private MixinExpressionStatus mixinExpressionStatus(DToken[] args,
	StringFunctionBody[][string] functions, bool[string] visited,
	ImportScanContext ctx, ConstantTable constants, ref string[] foundImports)
{
	///A bare/qualified identifier is a runtime string unless it was already
	///resolved above: it can be anything, including an import.
	bool simpleIdentifier = args.length == 1 && args[0].kind == DTokenKind.ident;
	if(!simpleIdentifier && args.length >= 3 && args.length % 2 == 1)
	{
		simpleIdentifier = true;
		for(size_t k = 0; k < args.length; k++)
		{
			if(k % 2 == 0)
			{
				if(args[k].kind != DTokenKind.ident) { simpleIdentifier = false; break; }
			}
			else if(args[k].text != ".") { simpleIdentifier = false; break; }
		}
	}
	if(simpleIdentifier)
	{
		if(args.length == 1 && constants !is null)
		{
			auto constantStatus = constants.importStatus(args[0].text, ctx, foundImports);
			if(constantStatus == ConstantImportStatus.safe)
				return MixinExpressionStatus.safe;
		}
		return MixinExpressionStatus.unknown;
	}

	MixinExpressionStatus status = MixinExpressionStatus.safe;
	for(size_t j = 0; j < args.length; j++)
	{
		auto token = args[j];
		if(token.kind == DTokenKind.literal)
		{
			string text;
			if(decodeDLiteral(token.text, text)
				&& !literalImports(text, ctx, foundImports))
				return MixinExpressionStatus.mayImport;
			continue;
		}
		if(token.text == "import" || token.text == "mixin")
			return MixinExpressionStatus.mayImport;
		if(token.kind != DTokenKind.ident || j + 1 >= args.length)
			continue;
		string next = args[j + 1].text;
		if(next != "(" && next != "!")
			continue;
		if(token.text == "cast" || token.text == "typeof"
			|| token.text == "__traits" || token.text == "is")
			continue;
		if(auto bodies = token.text in functions)
		{
			if(token.text in visited) continue;
			visited[token.text] = true;
			string[] literalArgs;
			bool knownArgs = next == "(" && literalCallArgs(args, j + 1,
				constants, literalArgs);
			if(functionMayImport(*bodies, functions, visited, ctx, constants,
				knownArgs ? literalArgs : null, foundImports))
				return MixinExpressionStatus.mayImport;
		}
		else
			status = MixinExpressionStatus.unknown;
	}
	return status;
}

///Scans a project string-returning function without CTFE. Only string literals
///and dynamic mixins count as import evidence; the function's own local imports
///do not end up in the returned code. Calls to other known project functions are
///followed recursively; unknown calls are assumed not to emit imports.
private bool functionMayImport(StringFunctionBody[] bodies,
	StringFunctionBody[][string] functions, bool[string] visited,
	ImportScanContext ctx, ConstantTable constants, string[] literalArgs,
	ref string[] foundImports)
{
	foreach(body; bodies)
	{
		///With literal arguments we can evaluate a simple `return a ~ b;`
		///without running CTFE.
		if(literalArgs !is null && body.params.length == literalArgs.length)
		{
			string[string] bound;
			foreach(i, param; body.params)
				bound[param] = literalArgs[i];
			size_t returnIndex = size_t.max;
			int returnCount;
			int depth;
			for(size_t j = 0; j < body.tokens.length; j++)
			{
				string text = body.tokens[j].text;
				if(text == "(" || text == "[" || text == "{") depth++;
				else if(text == ")" || text == "]" || text == "}")
				{
					if(depth > 0) depth--;
				}
				if(depth == 0 && text == "return")
				{
					returnCount++;
					returnIndex = j;
				}
			}
			if(returnCount == 1)
			{
				size_t end = returnIndex + 1;
				int d;
				for(; end < body.tokens.length; end++)
				{
					string text = body.tokens[end].text;
					if(text == "(" || text == "[" || text == "{") d++;
					else if(text == ")" || text == "]" || text == "}")
					{
						if(d > 0) d--;
					}
					else if(d == 0 && text == ";")
						break;
				}
				if(end < body.tokens.length)
				{
					string content;
					if(extractMixinString(body.tokens[returnIndex + 1 .. end],
						bound, constants, content))
					{
						auto info = scanDImportInfo(content, ctx);
						foreach(imp; info.imports)
						{
							bool exists;
							foreach(existing; foundImports)
								if(existing == imp) { exists = true; break; }
							if(!exists) foundImports ~= imp;
						}
						if(info.hasUnresolvedMixins || info.hasUnresolvedStringMixins)
							return true;
						return false;
					}
				}
			}
		}

		for(size_t j = 0; j < body.tokens.length; j++)
		{
			auto token = body.tokens[j];
			if(token.kind == DTokenKind.literal)
			{
				string text;
				if(decodeDLiteral(token.text, text)
					&& !literalImports(text, ctx, foundImports))
					return true;
				continue;
			}
			if(token.text == "mixin")
				return true;
			if(token.text == "import" && j + 1 < body.tokens.length
				&& body.tokens[j + 1].text == "(")
				return true;
			if(token.kind != DTokenKind.ident || j + 1 >= body.tokens.length)
				continue;
			string next = body.tokens[j + 1].text;
			if(next != "(" && next != "!")
				continue;
			if(token.text == "cast" || token.text == "typeof"
				|| token.text == "__traits" || token.text == "is")
				continue;
			if(auto callees = token.text in functions)
			{
				if(token.text in visited) continue;
				visited[token.text] = true;
				if(functionMayImport(*callees, functions, visited, ctx, constants,
					null, foundImports))
					return true;
			}
		}
	}
	return false;
}

private bool extractMixinString(DToken[] args, string[string] stringParams,
	ConstantTable constants, out string content)
{
	import std.array : join;

	//mixin(import("file")) pulls the file contents directly.
	if(args.length == 4 && args[0].text == "import" && args[1].text == "("
		&& args[2].kind == DTokenKind.literal && args[3].text == ")")
	{
		string file, fileContent;
		if(constants !is null && decodeDLiteral(args[2].text, file)
			&& constants.readStringImport(file, fileContent))
		{
			content = fileContent;
			return true;
		}
		return false;
	}

	string[] parts;
	foreach(tok; args)
	{
		if(tok.text == "~" || tok.text == ",") continue;
		if(tok.kind == DTokenKind.literal)
		{
			string decoded;
			if(!decodeDLiteral(tok.text, decoded)) return false;
			parts ~= decoded;
			continue;
		}
		if(tok.kind == DTokenKind.ident)
		{
			if(tok.text in stringParams)
			{
				parts ~= stringParams[tok.text];
				continue;
			}
			string resolved;
			if(constants !is null && constants.resolveString(tok.text, resolved))
			{
				parts ~= resolved;
				continue;
			}
		}
		return false;
	}
	if(parts.length == 0) return false;
	content = join(parts, "");
	return true;
}

private bool decodeDLiteral(string raw, out string content)
{
	if(raw.length < 2) return false;
	if(raw[0] == '"')
	{
		char[] buf;
		for(size_t j = 1; j + 1 < raw.length; j++)
		{
			char c = raw[j];
			if(c == '\\' && j + 2 < raw.length)
			{
				char n = raw[++j];
				switch(n)
				{
					case 'n': buf ~= '\n'; break;
					case 'r': buf ~= '\r'; break;
					case 't': buf ~= '\t'; break;
					case '"': buf ~= '"'; break;
					case '\'': buf ~= '\''; break;
					case '\\': buf ~= '\\'; break;
					case '0': buf ~= '\0'; break;
					default: buf ~= n; break;
				}
			}
			else
				buf ~= c;
		}
		content = cast(string)buf;
		return true;
	}
	if(raw[0] == '`')
	{
		if(raw[$ - 1] != '`') return false;
		content = raw[1 .. $ - 1];
		return true;
	}
	if(raw.length >= 3 && (raw[0] == 'r' || raw[0] == 'x') && raw[1] == '"')
	{
		if(raw[$ - 1] != '"') return false;
		content = raw[2 .. $ - 1];
		return true;
	}
	if(raw.length >= 4 && raw[0] == 'q' && raw[1] == '{')
	{
		if(raw[$ - 1] != '}') return false;
		content = raw[2 .. $ - 1];
		return true;
	}
	if(raw.length >= 4 && raw[0] == 'q' && raw[1] == '"')
	{
		if(DSourceScanner.isIdentStart(raw[2]))
		{
			size_t j = 2;
			while(j < raw.length && DSourceScanner.isIdentPart(raw[j])) j++;
			string identDelim = raw[2 .. j];
			if(raw[$ - 1] != '"') return false;
			size_t closeStart = raw.length - 1 - identDelim.length;
			if(closeStart < j || raw[closeStart .. closeStart + identDelim.length] != identDelim)
				return false;
			content = raw[j .. closeStart];
			return true;
		}
		char delim = raw[2];
		char closing = delim;
		switch(delim)
		{
			case '(': closing = ')'; break;
			case '[': closing = ']'; break;
			case '{': closing = '}'; break;
			case '<': closing = '>'; break;
			default: break;
		}
		if(raw.length < 4 || raw[$ - 2] != closing || raw[$ - 1] != '"') return false;
		content = raw[3 .. $ - 2];
		return true;
	}
	return false;
}

private string[] templateParamNames(DToken[] tokens)
{
	string[] ret;
	size_t start;
	int depth;
	void processChunk(size_t end)
	{
		size_t eq = end;
		int d;
		for(size_t j = start; j < end; j++)
		{
			string text = tokens[j].text;
			if(text == "(" || text == "[" || text == "{") d++;
			else if(text == ")" || text == "]" || text == "}") d--;
			else if(text == "=" && d == 0) { eq = j; break; }
		}
		string name;
		for(size_t j = start; j < eq; j++)
			if(tokens[j].kind == DTokenKind.ident)
				name = tokens[j].text;
		if(name.length) ret ~= name;
	}
	for(size_t j = 0; j < tokens.length; j++)
	{
		string text = tokens[j].text;
		if(text == "(" || text == "[" || text == "{") depth++;
		else if(text == ")" || text == "]" || text == "}") depth--;
		else if(text == "," && depth == 0)
		{
			processChunk(j);
			start = j + 1;
		}
	}
	processChunk(tokens.length);
	return ret;
}

private void collectMixinTemplates(DToken[] tokens, string source, ref MixinTemplateBody[string] templates)
{
	for(size_t j = 0; j + 1 < tokens.length; j++)
	{
		bool isMixinTemplate = tokens[j].text == "mixin" && tokens[j + 1].text == "template";
		bool isPlainTemplate = tokens[j].text == "template"
			&& (j == 0 || tokens[j - 1].text != "mixin");
		if(!isMixinTemplate && !isPlainTemplate) continue;
		size_t nameIndex = isMixinTemplate ? j + 2 : j + 1;
		if(nameIndex >= tokens.length || tokens[nameIndex].kind != DTokenKind.ident) continue;
		string name = tokens[nameIndex].text;
		string[] params;
		size_t k = nameIndex + 1;
		if(k < tokens.length && tokens[k].text == "(")
		{
			size_t open = k;
			int parenDepth;
			for(; k < tokens.length; k++)
			{
				if(tokens[k].text == "(") parenDepth++;
				else if(tokens[k].text == ")")
				{
					parenDepth--;
					if(parenDepth == 0) break;
				}
			}
			if(k < tokens.length)
			{
				params = templateParamNames(tokens[open + 1 .. k]);
				k++;
			}
		}
		while(k < tokens.length && tokens[k].text != "{") k++;
		if(k >= tokens.length) continue;
		size_t start = k + 1;
		int depth = 1;
		k++;
		while(k < tokens.length)
		{
			if(tokens[k].text == "{") depth++;
			else if(tokens[k].text == "}") depth--;
			if(depth == 0) break;
			k++;
		}
		MixinTemplateBody body;
		body.tokens = tokens[start .. k];
		body.source = source;
		body.params = params;
		templates[name] = body;
	}
}

private bool isFunctionParamType(string text)
{
	switch(text)
	{
		case "string", "wstring", "dstring", "int", "uint", "long", "ulong",
			"short", "ushort", "byte", "ubyte", "char", "wchar", "dchar",
			"bool", "float", "double", "real", "size_t", "ptrdiff_t",
			"auto", "alias", "const", "immutable", "shared", "inout", "scope",
			"ref", "out", "lazy", "in", "static", "void":
			return true;
		default:
			return false;
	}
}

///Extract parameter names from one balanced parameter list.
private string[] functionParamNames(DToken[] tokens)
{
	string[] names;
	size_t start;
	int depth;
	void process(size_t end)
	{
		if(end <= start) return;
		size_t eq = size_t.max;
		int d;
		for(size_t j = start; j < end; j++)
		{
			string text = tokens[j].text;
			if(text == "(" || text == "[" || text == "{") d++;
			else if(text == ")" || text == "]" || text == "}") d--;
			else if(d == 0 && text == "=") { eq = j; break; }
		}
		size_t stop = eq == size_t.max ? end : eq;
		size_t last = size_t.max;
		int d2;
		for(size_t j = start; j < stop; j++)
		{
			string text = tokens[j].text;
			if(text == "(" || text == "[" || text == "{") d2++;
			else if(text == ")" || text == "]" || text == "}") d2--;
			if(d2 == 0 && tokens[j].kind == DTokenKind.ident)
				last = j;
		}
		if(last != size_t.max && !isFunctionParamType(tokens[last].text))
			names ~= tokens[last].text;
	}
	for(size_t j = 0; j < tokens.length; j++)
	{
		string text = tokens[j].text;
		if(text == "(" || text == "[" || text == "{") depth++;
		else if(text == ")" || text == "]" || text == "}")
		{
			if(depth > 0) depth--;
		}
		else if(text == "," && depth == 0)
		{
			process(j);
			start = j + 1;
		}
	}
	process(tokens.length);
	return names;
}

///Collects string-returning function bodies so mixin helpers defined in the
///project can be checked for import evidence without running CTFE.
private void collectStringFunctions(DToken[] tokens, string source,
	ref StringFunctionBody[][string] functions)
{
	int parenDepth;
	for(size_t j = 0; j + 1 < tokens.length; j++)
	{
		if(tokens[j].text == "(")
		{
			parenDepth++;
			continue;
		}
		if(tokens[j].text == ")")
		{
			if(parenDepth > 0) parenDepth--;
			continue;
		}
		if(parenDepth != 0 || tokens[j].text != "string")
			continue;
		size_t nameIndex = j + 1;
		if(nameIndex >= tokens.length || tokens[nameIndex].kind != DTokenKind.ident)
			continue;
		string name = tokens[nameIndex].text;
		size_t k = nameIndex + 1;
		int depth;
		bool sawParens;
		size_t groupStart = size_t.max;
		string[] params;
		size_t bodyStart = size_t.max;
		for(; k < tokens.length; k++)
		{
			string text = tokens[k].text;
			if(text == "(")
			{
				if(depth == 0) groupStart = k;
				depth++;
				sawParens = true;
			}
			else if(text == ")")
			{
				if(depth > 0)
				{
					depth--;
					if(depth == 0 && groupStart != size_t.max)
					{
						params = functionParamNames(tokens[groupStart + 1 .. k]);
						groupStart = size_t.max;
					}
				}
			}
			else if(depth == 0 && text == "{")
			{
				bodyStart = k;
				break;
			}
			else if(depth == 0 && text == ";")
				break;
		}
		if(!sawParens || bodyStart == size_t.max)
			continue;
		int braceDepth = 1;
		size_t end = bodyStart + 1;
		for(; end < tokens.length; end++)
		{
			if(tokens[end].text == "{") braceDepth++;
			else if(tokens[end].text == "}")
			{
				braceDepth--;
				if(braceDepth == 0) break;
			}
		}
		if(end >= tokens.length)
			continue;
		StringFunctionBody body;
		body.tokens = tokens[bodyStart + 1 .. end];
		body.source = source;
		body.params = params;
		functions[name] ~= body;
	}
}

///Everything a source scan found, including how trustworthy the import list is.
struct ImportScanInfo
{
	string[] imports;
	string moduleName;
	bool hasUnknownConditionals;
	bool hasUnresolvedMixins;
	bool hasUnresolvedStringMixins;
	bool hasUnknownVersionIdentifiers;
	string[] doubts;

	bool isDoubtful() const
	{
		return doubts.length != 0 || hasUnknownConditionals || hasUnresolvedMixins ||
			hasUnresolvedStringMixins || hasUnknownVersionIdentifiers;
	}

	bool isUnsupported() const { return hasUnresolvedMixins || hasUnresolvedStringMixins; }
	bool isImportRisk() const { return hasUnresolvedMixins; }
	bool isConservative() const { return hasUnknownConditionals; }
	bool isContextDependent() const { return hasUnknownVersionIdentifiers; }
}

/**
 * Extracts the imports declared in a D source file. Comments, string literals
 * and token strings are ignored, version/debug are evaluated with ctx, static if
 * is evaluated when decidable, and mixin/mixin template bodies are expanded.
 * shortcut: static if only understands literals/!/&&/|| (unknown keeps both
 * branches); string mixins need literal-only concatenation; mixin templates are
 * resolved by name package-wide and not instantiated per template parameter.
 * Cases that could hide imports are reported by isDoubtful().
 * Params:
 *   source = D source code
 *   ctx = Compile-time versions/debug flags
 * Returns: The imports and the confidence flags
 */
ImportScanInfo scanDImportInfo(string source, ImportScanContext ctx)
{
	MixinTemplateBody[string] templates;
	StringFunctionBody[][string] functions;
	DToken[] tokens = tokenizeDSource(source);
	collectMixinTemplates(tokens, source, templates);
	collectStringFunctions(tokens, source, functions);
	ConstantTable constants = new ConstantTable();
	constants.stringImportPaths = ctx.stringImportPaths;
	{
		DImportParser collector = DImportParser(tokens, ctx, templates);
		collector.constants = constants;
		collector.functions = functions;
		collector.collectConstants = true;
		collector.constantsOnly = true;
		collector.parseAll();
	}
	DImportParser parser = DImportParser(tokens, ctx, templates);
	parser.constants = constants;
	parser.functions = functions;
	parser.parseAll();
	ImportScanInfo ret;
	ret.imports = parser.imports;
	ret.moduleName = parser.moduleName;
	ret.hasUnknownConditionals = parser.hasUnknownConditionals;
	ret.hasUnresolvedMixins = parser.hasUnresolvedMixins;
	ret.hasUnresolvedStringMixins = parser.hasUnresolvedStringMixins;
	ret.hasUnknownVersionIdentifiers = parser.hasUnknownVersionIdentifiers;
	ret.doubts = parser.doubts;
	return ret;
}

string[] scanDImports(string source, out string moduleName)
{
	ImportScanInfo info = scanDImportInfo(source, defaultImportScanContext());
	moduleName = info.moduleName;
	return info.imports;
}

string[] scanDImports(string source, out string moduleName, ImportScanContext ctx,
	out bool hasUnknownConditionals, out bool hasUnresolvedMixins)
{
	ImportScanInfo info = scanDImportInfo(source, ctx);
	moduleName = info.moduleName;
	hasUnknownConditionals = info.hasUnknownConditionals;
	hasUnresolvedMixins = info.hasUnresolvedMixins;
	return info.imports;
}

///Import graph for a single package. Used to decide module compilation order.
struct SourceImportGraph
{
	ModuleDef[] modules;
	ModuleDef[string] byName;
	string[] externalImports;
	string[] compileOrder;
	///Files that could not be read or whose module name could not be inferred.
	string[] skippedFiles;

	bool isExternal(string moduleName) const { return !(moduleName in byName); }

	bool isDoubtful() const
	{
		if(skippedFiles.length) return true;
		foreach(_, mod; byName)
			if(mod.isDoubtful) return true;
		return false;
	}

	///Any module has dynamic imports we couldn't resolve; incremental needs full rebuild.
	bool hasImportRisk() const
	{
		foreach(_, mod; byName)
			if(mod.isImportRisk) return true;
		return false;
	}

	///Transitive modules that import moduleName, sorted. Used for incremental builds.
	string[] findDependents(string moduleName) const
	{
		import std.algorithm : sort;
		string[] ret;
		bool[string] visited;
		void visit(string name)
		{
			const(ModuleDef)* mod = name in byName;
			if(mod is null) return;
			foreach(_, importer; mod.importedBy)
			{
				if(importer.isExternal || importer.modName in visited) continue;
				visited[importer.modName] = true;
				ret ~= importer.modName;
				visit(importer.modName);
			}
		}
		visit(moduleName);
		ret.sort();
		return ret;
	}
}

private string inferModuleName(string filePath, string sourceRoot)
{
	import std.path : relativePath, stripExtension;
	import std.string : replace, startsWith, endsWith;

	string rel;
	try
		rel = relativePath(filePath, sourceRoot);
	catch(Exception)
		return null;
	if(rel.length == 0 || rel.startsWith(".."))
		return null;
	rel = stripExtension(rel).replace("\\", ".").replace("/", ".");
	if(rel == "package")
		return null;
	if(rel.endsWith(".package"))
		return rel[0 .. $ - ".package".length];
	return rel;
}

/**
 * Builds the import graph of a single package from its D sources, without
 * invoking the compiler.
 * Params:
 *   sourceDirectories = Directories containing the package sources
 *   excludePatterns = Glob patterns of files to ignore
 * Returns: The graph, with a dependency-first compilation order
 */
SourceImportGraph parseSourceImportGraph(string[] sourceDirectories, string[] excludePatterns = null)
{
	return parseSourceImportGraph(sourceDirectories, null, excludePatterns, defaultImportScanContext());
}

/**
 * Same as the overload above, but with an explicit compile-time context for
 * version/debug/static if evaluation.
 */
SourceImportGraph parseSourceImportGraph(string[] sourceDirectories, string[] excludePatterns, ImportScanContext ctx)
{
	return parseSourceImportGraph(sourceDirectories, null, excludePatterns, ctx);
}

/**
 * Scans source directories plus explicitly listed source files (BuildConfiguration.sourceFiles).
 */
SourceImportGraph parseSourceImportGraph(string[] sourceDirectories, string[] sourceFiles,
	string[] excludePatterns, ImportScanContext ctx, bool computeWeights = false)
{
	import std.file : dirEntries, SpanMode, isDir, exists, readText;
	import std.path : extension, globMatch, dirName;
	import std.string : startsWith;
	import std.algorithm : sort;

	struct TokenizedFile
	{
		string path;
		string root;
		string source;
		DToken[] tokens;
	}
	struct FileEntry
	{
		string path;
		string root;
	}
	FileEntry[] entries;
	string[] skippedFiles;
	bool[string] seenPaths;
	foreach(root; sourceDirectories)
	{
		if(!exists(root) || !isDir(root))
			continue;
		foreach(entry; dirEntries(root, SpanMode.depth))
		{
			if(entry.isDir || extension(entry.name) != ".d")
				continue;
			string path = entry.name;
			bool excluded;
			foreach(pattern; excludePatterns)
				if(path.globMatch(pattern)) { excluded = true; break; }
			if(excluded)
				continue;
			entries ~= FileEntry(path, root);
			seenPaths[path] = true;
		}
	}

	if(sourceFiles !is null)
	foreach(filePath; sourceFiles)
	{
		if(filePath.length == 0 || filePath in seenPaths)
			continue;
		bool excluded;
		foreach(pattern; excludePatterns)
			if(filePath.globMatch(pattern)) { excluded = true; break; }
		if(excluded)
			continue;
		string root;
		foreach(r; sourceDirectories)
			if(filePath.startsWith(r)) { root = r; break; }
		if(root.length == 0)
			root = dirName(filePath);
		entries ~= FileEntry(filePath, root);
		seenPaths[filePath] = true;
	}

	TokenizedFile[] files;
	files.length = entries.length;
	ubyte[] readFailed;
	readFailed.length = entries.length;

	void readAndTokenize(size_t index)
	{
		string text;
		try
			text = readText(entries[index].path);
		catch(Exception)
		{
			readFailed[index] = 1;
			return;
		}
		files[index] = TokenizedFile(entries[index].path, entries[index].root, text,
			tokenizeDSource(text));
	}

	//shortcut: a local 8-worker pool avoids touching redub's shared task pool;
	//raise the threshold only if pool startup starts to show up in profiles.
	enum parallelFileThreshold = 32;
	enum parallelWorkerCount = 8;
	import std.range : iota;
	if(entries.length >= parallelFileThreshold)
	{
		import std.parallelism : TaskPool;
		auto pool = new TaskPool(parallelWorkerCount);
		scope(exit) pool.stop();
		foreach(i; pool.parallel(iota(entries.length)))
			readAndTokenize(i);
	}
	else
	{
		foreach(i; iota(entries.length))
			readAndTokenize(i);
	}

	bool anyFailed;
	foreach(failed; readFailed)
		if(failed) { anyFailed = true; break; }
	if(anyFailed)
	{
		TokenizedFile[] okFiles;
		okFiles.reserve(entries.length);
		foreach(i, entry; entries)
		{
			if(readFailed[i])
			{
				skippedFiles ~= entry.path;
				continue;
			}
			okFiles ~= files[i];
		}
		files = okFiles;
	}

	///Mixin templates and string helpers are resolved package-wide, so a mixin
	///can be used from a different module than the one that declares it.
	MixinTemplateBody[string] templates;
	StringFunctionBody[][string] functions;
	foreach(f; files)
	{
		collectMixinTemplates(f.tokens, f.source, templates);
		collectStringFunctions(f.tokens, f.source, functions);
	}

	///Collect enum/static const values first so static if can use them across modules.
	ConstantTable constants = new ConstantTable();
	constants.stringImportPaths = ctx.stringImportPaths;
	foreach(f; files)
	{
		DImportParser collector = DImportParser(f.tokens, ctx, templates);
		collector.constants = constants;
		collector.functions = functions;
		collector.collectConstants = true;
		collector.constantsOnly = true;
		collector.parseAll();
	}

	struct ParsedFile
	{
		string path;
		string moduleName;
		string[] imports;
		bool hasUnknownConditionals;
		bool hasUnresolvedMixins;
		bool hasUnresolvedStringMixins;
		bool hasUnknownVersionIdentifiers;
		string[] doubts;
		size_t compileWeight;
		bool conservativeWeight;
		bool usedTrustedNoImportMixin;
	}
	ParsedFile[] parsed;
	foreach(f; files)
	{
		DImportParser parser = DImportParser(f.tokens, ctx, templates);
		parser.constants = constants;
		parser.functions = functions;
		parser.parseAll();
		string moduleName = parser.moduleName;
		if(moduleName.length == 0)
			moduleName = inferModuleName(f.path, f.root);
		if(moduleName.length == 0)
		{
			skippedFiles ~= f.path;
			continue;
		}
		CompileWeight weight;
		if(computeWeights)
			weight = computeCompileWeight(f.tokens);
		parsed ~= ParsedFile(f.path, moduleName, parser.imports,
			parser.hasUnknownConditionals, parser.hasUnresolvedMixins,
			parser.hasUnresolvedStringMixins, parser.hasUnknownVersionIdentifiers,
			parser.doubts, weight.value, weight.conservative,
			parser.usedTrustedNoImportMixin);
	}

	///Reuse the same ModuleDef/ModuleParsing graph that the compiler .deps
	///parser fills, so both paths share traversal helpers.
	ModuleParsing parsing = new ModuleParsing();
	foreach(p; parsed)
	{
		ModuleDef* mod = parsing.getModuleInCache(p.moduleName, p.path);
		mod.hasUnknownConditionals = p.hasUnknownConditionals;
		mod.hasUnresolvedMixins = p.hasUnresolvedMixins;
		mod.hasUnresolvedStringMixins = p.hasUnresolvedStringMixins;
		mod.hasUnknownVersionIdentifiers = p.hasUnknownVersionIdentifiers;
		mod.doubts = p.doubts;
		mod.compileWeight = cast(uint)p.compileWeight;
		mod.conservativeWeight = p.conservativeWeight;
		mod.usedTrustedNoImportMixin = p.usedTrustedNoImportMixin;
	}
	foreach(p; parsed)
	{
		ModuleDef* mod = parsing.fromModuleName(p.moduleName);
		if(mod is null) continue;
		foreach(imp; p.imports)
		{
			ModuleDef* imported = parsing.fromModuleName(imp);
			if(imported is null)
			{
				imported = parsing.getModuleInCache(imp, "<external>:" ~ imp);
				imported.isExternal = true;
			}
			mod.addImport(*imported);
		}
	}

	SourceImportGraph graph;
	foreach(_, ref mod; parsing.allModules)
	{
		if(mod.isExternal)
			graph.externalImports ~= mod.modName;
		else
		{
			graph.byName[mod.modName] = mod;
			graph.modules ~= mod;
		}
	}
	graph.externalImports.sort();
	graph.modules.sort!((a, b) => a.modName < b.modName);

	bool[string] visited;
	bool[string] inStack;
	void visit(ModuleDef* mod)
	{
		if(mod is null || mod.isExternal) return;
		if(mod.modPath in visited || mod.modPath in inStack) return;
		inStack[mod.modPath] = true;
		ModuleDef*[] dependencies;
		foreach(_, ref imported; mod.imports)
			if(!imported.isExternal) dependencies ~= &imported;
		dependencies.sort!((a, b) => a.modName < b.modName);
		foreach(dependency; dependencies)
			visit(dependency);
		inStack.remove(mod.modPath);
		visited[mod.modPath] = true;
		graph.compileOrder ~= mod.modName;
	}
	foreach(mod; graph.modules)
		visit(parsing.fromModuleName(mod.modName));

	graph.skippedFiles = skippedFiles;
	return graph;
}

unittest
{
	import std.conv : to;
	immutable source = q{
		module foo.bar;
		// import fake.line;
		/* import fake.block; */
		/+ import fake.nested; +/
		import std.stdio;
		static import core.thread;
		public import a.b, c.d;
		import std.algorithm : map, filter;
		import alias = x.y.z;
		enum s = "import fake.string;";
		enum t = q{ import fake.token; };
		enum u = r"import fake.raw;";
		enum v = `import fake.backtick;`;
	};
	string mod;
	string[] imports = scanDImports(source, mod);
	assert(mod == "foo.bar", mod);
	assert(imports == ["std.stdio", "core.thread", "a.b", "c.d", "std.algorithm", "x.y.z"], imports.to!string);
}

unittest
{
	import std.conv : to;
	ImportScanContext ctx;
	ctx.addVersion("Windows");
	ctx.addVersion("UseFoo");
	immutable source = q{
		module foo;
		version(Windows) import win.mod;
		version(linux) import linux.mod;
		version(UseFoo) { import used.mod; }
		version(Other) { import other.mod; } else { import fallback.mod; }
		version = LocalVersion;
		version(LocalVersion) import local.mod;
		debug import no.debug;
		debug = Dbg;
		debug(Dbg) import dbg.mod;
		debug(MissingDbg) import no.dbg2;
		static if(true) import yes.mod; else import no.mod;
		static if(false) import never.mod; else import always.mod;
		static if(1 && !0) import combined.mod;
		static if(SomeTemplateParam) { import branch.a; } else { import branch.b; }
		mixin("import mixin.string;");
		mixin(q"EOS
import from.qident;
EOS");
		mixin(import("generated.d"));
		mixin(someEnumString);
		mixin(q{
			mixin template Generated() { import generated.tpl; }
		});
		mixin Generated;
		mixin template Tpl() { import tpl.mod; }
		mixin Tpl;
		mixin template Tpl2() { static if(Param) import tpl2.a; else import tpl2.b; }
		mixin Tpl2;
		mixin("import " ~ someName ~ ";");
		unittest { import from.unittestblock; }
	};
	ImportScanInfo info = scanDImportInfo(source, ctx);
	string[] expected = [
		"win.mod", "used.mod", "fallback.mod", "local.mod",
		"dbg.mod", "yes.mod", "always.mod", "combined.mod", "branch.a", "branch.b",
		"mixin.string", "from.qident", "generated.tpl", "tpl.mod", "tpl2.a", "tpl2.b"
	];
	assert(info.imports == expected, info.imports.to!string);
	assert(info.hasUnknownConditionals, "static if with a template parameter should be flagged as unknown");
	assert(info.hasUnresolvedMixins, "mixin built from an identifier should be flagged as unresolved");
	assert(info.hasUnresolvedStringMixins, "non-literal string mixins should be flagged");
	assert(info.hasUnknownVersionIdentifiers, "unknown version/debug identifiers should be flagged");
	assert(info.doubts.length != 0);
	assert(info.isDoubtful);
}

unittest
{
	ImportScanInfo info = scanDImportInfo(q{
		module expr.mixin;
		void f() { return mixin("getopt(args, " ~ genGetoptCall!(T)("_") ~ ")"); }
		void g() { setEnvVariable("x", mixin("dubVars.", member)); }
	}, ImportScanContext.init);
	assert(info.imports.length == 0);
	assert(!info.isDoubtful);
}

unittest
{
	import std.conv : to;
	import std.algorithm.searching : canFind;
	//Known standard-library mixin templates are trusted by default.
	ImportScanInfo stdMixins = scanDImportInfo(q{
		module trusted.std;
		import std.exception;
		class E : Exception { mixin basicExceptionCtors; }
	}, defaultImportScanContext());
	assert(!stdMixins.hasUnresolvedMixins, stdMixins.doubts.to!string);

	//Literal/stringof concatenations with no calls cannot emit imports.
	ImportScanInfo literals = scanDImportInfo(q{
		module trusted.literals;
		void f(T)() { mixin("alias set" ~ T.stringof ~ " = int;"); }
	}, defaultImportScanContext());
	assert(!literals.hasUnresolvedStringMixins, literals.doubts.to!string);

	//A project helper that returns a complete literal import is resolved.
	ImportScanInfo importingHelper = scanDImportInfo(q{
		module trusted.importing;
		string gen() { return "import generated;"; }
		mixin(gen());
	}, defaultImportScanContext());
	assert(!importingHelper.hasUnresolvedStringMixins, importingHelper.doubts.to!string);
	assert(importingHelper.imports.canFind("generated"), importingHelper.imports.to!string);

	//A helper that builds the import from a runtime value stays unresolved.
	ImportScanInfo dynamicHelper = scanDImportInfo(q{
		module trusted.dynamic;
		string gen(string name) { return "import " ~ name ~ ";"; }
		void f(string runtimeName) { mixin(gen(runtimeName)); }
	}, defaultImportScanContext());
	assert(dynamicHelper.hasUnresolvedStringMixins, dynamicHelper.doubts.to!string);

	//The same helper with a literal argument is resolved.
	ImportScanInfo literalArg = scanDImportInfo(q{
		module trusted.literal_arg;
		string gen(string name) { return "import " ~ name ~ ";"; }
		mixin(gen("generated"));
	}, defaultImportScanContext());
	assert(!literalArg.hasUnresolvedStringMixins, literalArg.doubts.to!string);
	assert(literalArg.imports.canFind("generated"), literalArg.imports.to!string);

	//Module-level const strings are compile-time constants too.
	ImportScanInfo constString = scanDImportInfo(q{
		module trusted.const_string;
		const string pkg = "generated";
		mixin("import " ~ pkg ~ ";");
	}, defaultImportScanContext());
	assert(!constString.hasUnresolvedStringMixins, constString.doubts.to!string);
	assert(constString.imports.canFind("generated"), constString.imports.to!string);

	//A CTFE enum with no import evidence in its body is safe.
	ImportScanInfo ctfeSafe = scanDImportInfo(q{
		module trusted.ctfe_safe;
		enum generated = ({ string s; s ~= "int x;"; return s; }());
		mixin(generated);
	}, defaultImportScanContext());
	assert(!ctfeSafe.hasUnresolvedStringMixins, ctfeSafe.doubts.to!string);

	//A complete import assembled from literals can be estimated.
	ImportScanInfo ctfeImport = scanDImportInfo(q{
		module trusted.ctfe_import;
		enum generated = ({ string s = "import "; s ~= "created;"; return s; }());
		mixin(generated);
	}, defaultImportScanContext());
	assert(!ctfeImport.hasUnresolvedStringMixins, ctfeImport.doubts.to!string);
	assert(ctfeImport.imports.canFind("created"), ctfeImport.imports.to!string);

	//Import evidence with a dynamic piece cannot be resolved.
	ImportScanInfo ctfeDynamic = scanDImportInfo(q{
		module trusted.ctfe_dynamic;
		enum generated(string name) = ({ string s = "import "; s ~= name; return s; }());
		void f(string runtime) { mixin(generated!(runtime)); }
	}, defaultImportScanContext());
	assert(ctfeDynamic.hasUnresolvedStringMixins, ctfeDynamic.doubts.to!string);

	//A mixin template fed a runtime string stays unresolved.
	ImportScanInfo dynamicTemplate = scanDImportInfo(q{
		module trusted.dynamic_template;
		mixin template Dynamic(string s) { mixin(s); }
		void f(string runtime) { mixin Dynamic!(runtime); }
	}, defaultImportScanContext());
	assert(dynamicTemplate.hasUnresolvedStringMixins, dynamicTemplate.doubts.to!string);

	//The same template with a literal argument resolves the import.
	ImportScanInfo literalTemplate = scanDImportInfo(q{
		module trusted.literal_template;
		mixin template Dynamic(string s) { mixin(s); }
		mixin Dynamic!("import generated;");
	}, defaultImportScanContext());
	assert(!literalTemplate.hasUnresolvedStringMixins, literalTemplate.doubts.to!string);
	assert(literalTemplate.imports.canFind("generated"), literalTemplate.imports.to!string);

	//A project helper that returns no import is safe.
	ImportScanInfo safeHelper = scanDImportInfo(q{
		module trusted.safe;
		string safeGen() { return "int x;"; }
		mixin(safeGen());
	}, defaultImportScanContext());
	assert(!safeHelper.hasUnresolvedStringMixins, safeHelper.doubts.to!string);

	//User-provided trust overrides an unknown helper.
	ImportScanContext ctx = defaultImportScanContext();
	ctx.addTrustedNoImportMixin("gen");
	ImportScanInfo trustedHelper = scanDImportInfo(q{
		module trusted.user;
		mixin(gen());
	}, ctx);
	assert(!trustedHelper.hasUnresolvedStringMixins, trustedHelper.doubts.to!string);

	//A local template with a built-in trusted name keeps its real body.
	ImportScanInfo localProxy = scanDImportInfo(q{
		module trusted.local_proxy;
		mixin template Proxy() { import local.from_proxy; }
		mixin Proxy;
	}, defaultImportScanContext());
	assert(localProxy.imports.canFind("local.from_proxy"), localProxy.imports.to!string);
}

unittest
{
	import std.file : tempDir, mkdirRecurse, write, rmdirRecurse, exists;
	import std.path : buildNormalizedPath;
	string root = buildNormalizedPath(tempDir, "d_dependencies_explicit_sources");
	string src = buildNormalizedPath(root, "src");
	string outside = buildNormalizedPath(root, "outside");
	if(!exists(src)) mkdirRecurse(src);
	if(!exists(outside)) mkdirRecurse(outside);
	write(buildNormalizedPath(src, "a.d"), "module a; import b;");
	string bPath = buildNormalizedPath(outside, "b.d");
	write(bPath, "module b;");
	scope(exit) rmdirRecurse(root);

	SourceImportGraph graph = parseSourceImportGraph([src], [bPath], null,
		defaultImportScanContext());
	assert("a" in graph.byName);
	assert("b" in graph.byName);
	bool importsB;
	foreach(_, imported; graph.byName["a"].imports)
		if(imported.modName == "b") importsB = true;
	assert(importsB);

}

unittest
{
	ImportScanContext win = importScanContextFor(OS.win64, ISA.x86_64, "dmd");
	assert("Windows" in win.versions);
	assert("Win64" in win.versions);
	assert("DigitalMars" in win.versions);
	assert("CRuntime_Microsoft" in win.versions);
	assert(!("Posix" in win.versions));
	assert("D_LP64" in win.versions);

	ImportScanContext arm = importScanContextFor(OS.linux, ISA.aarch64, "ldc2");
	assert("linux" in arm.versions);
	assert("AArch64" in arm.versions);
	assert("LDC" in arm.versions);
	assert("D_LP64" in arm.versions);
	assert(!("Windows" in arm.versions));

	ImportScanContext z = importScanContextFor(OS.linux, ISA.systemZ, "gdc",
		null, 0, Endian.bigEndian);
	assert("SystemZ" in z.versions);
	assert("BigEndian" in z.versions);
	assert("GNU" in z.versions);
}

unittest
{
	import std.conv : to;
	import std.file : tempDir, mkdirRecurse, write, rmdirRecurse, exists;
	import std.path : buildNormalizedPath;
	string dir = buildNormalizedPath(tempDir, "d_dependencies_string_import_test");
	if(!exists(dir)) mkdirRecurse(dir);
	write(buildNormalizedPath(dir, "mods.txt"), "from.a\nfrom.b\n");
	scope(exit) rmdirRecurse(dir);
	ImportScanContext ctx;
	ctx.stringImportPaths = [dir];
	immutable source = q{
		module stringimport.test;
		immutable string Mods = import("mods.txt");
		mixin template LoadReferencedAssets(string[] modules)
		{
			static foreach(m; modules)
				mixin("import " ~ m ~ ";");
		}
		mixin template LoadAllAssets(string modules)
		{
			mixin LoadReferencedAssets!(splitLines(modules));
		}
		mixin LoadAllAssets!(Mods);
	};
	ImportScanInfo info = scanDImportInfo(source, ctx);
	assert(info.imports == ["from.a", "from.b"], info.imports.to!string);
}

unittest
{
	import std.conv : to;
	immutable source = q{
		module constants.test;
		static const bool isWeb = true;
		enum bool isTesting = false;
		enum isWebServer = true;
		enum CustomRuntime = false;
		static if(CustomRuntime) enum HipConcurrency = false;
		else enum HipConcurrency = true;
		static if(isWeb) import web.dep;
		static if(isTesting) import test.dep;
		static if(isWebServer || !isWeb) import server.dep;
		static if(HipConcurrency) import concurrency.dep;
	};
	ImportScanInfo info = scanDImportInfo(source, ImportScanContext.init);
	assert(info.imports == ["web.dep", "server.dep", "concurrency.dep"], info.imports.to!string);
	assert(!info.hasUnknownConditionals, info.doubts.to!string);
}

unittest
{
	immutable source = q{
		module template.test;
		template Panel(T) { import panel.dep; }
		mixin Panel!int;
	};
	ImportScanInfo info = scanDImportInfo(source, ImportScanContext.init);
	assert(info.imports == ["panel.dep"]);
	assert(!info.hasUnresolvedMixins);
	assert(!info.isDoubtful);
}

unittest
{
	ImportScanInfo info = scanDImportInfo(q{
		module staticif.noimport;
		static if(is(int == int)) { int x; }
		import unconditional;
	}, ImportScanContext.init);
	assert(info.imports == ["unconditional"]);
	assert(!info.hasUnknownConditionals);
}

unittest
{
	import std.conv : to;
	immutable source = "module eof.test;\nimport before.eof;\n__EOF__\nimport after.eof;\n";
	ImportScanInfo info = scanDImportInfo(source, defaultImportScanContext());
	assert(info.imports == ["before.eof"], info.imports.to!string);
}

unittest
{
	immutable source = q{
		module ut;
		unittest { import in.ut; }
	};
	ImportScanContext off;
	assert(scanDImportInfo(source, off).imports.length == 0);
	ImportScanContext on;
	on.unittestMode = true;
	assert(scanDImportInfo(source, on).imports == ["in.ut"]);
}

unittest
{
	ImportScanContext ctx;
	ctx.knownVersions["DisabledFeature"] = true;
	ImportScanInfo known = scanDImportInfo("module k; version(DisabledFeature) import no;", ctx);
	assert(known.imports.length == 0);
	assert(!known.hasUnknownVersionIdentifiers);
	ImportScanInfo unknown = scanDImportInfo("module k; version(MysteryFeature) import no;", ctx);
	assert(unknown.hasUnknownVersionIdentifiers);
}

unittest
{
	ImportScanInfo info = scanDImportInfo(q{
		module debugfix;
		debug = Foo;
		debug(Foo) import yes.debug;
		debug import no.debug;
	}, ImportScanContext.init);
	assert(info.imports == ["yes.debug"]);
}

unittest
{
	import std.conv : to;
	immutable source = q{
		module features;
		version(D_Coverage) import cov;
		version(D_Optimized) import opt;
		version(D_Invariants) import inv;
	};
	ImportScanInfo off = scanDImportInfo(source, ImportScanContext.init);
	assert(off.imports == ["inv"], off.imports.to!string);
	ImportScanContext ctx;
	ctx.coverageMode = true;
	ctx.optimized = true;
	ImportScanInfo on = scanDImportInfo(source, ctx);
	assert(on.imports == ["cov", "opt", "inv"], on.imports.to!string);
}

unittest
{
	import std.conv : to;
	ImportScanContext ctx;
	ctx.versions["UseFoo"] = true;
	bool unknown;
	bool unresolved;
	immutable source = q{
		module colon.test;
		version(UseFoo):
		import yes.colon;
		version(Other):
		import no.colon;
		import also.no;
	};
	string mod;
	string[] imports = scanDImports(source, mod, ctx, unknown, unresolved);
	assert(imports == ["yes.colon"], imports.to!string);
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
