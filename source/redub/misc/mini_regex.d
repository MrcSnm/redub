module redub.misc.mini_regex;


bool matches(string input, string rlike)
{
    if(rlike.length == 0)
        return true;
    
    import std.string;
    import std.exception;
    static enum RegType
    {
        range,
        characters,
        matchAll,
        multiMatch
    }
    static struct RegAlgo
    {
        int delegate(string) fn;
        RegType type;
        string characters;
        bool optional;
        ///Keep that algorithm while it is matching
        bool greedy;


        ptrdiff_t matches(string input)
        {
            if(type == RegType.characters)
                return input == this.characters ? characters.length : -1;
            if(type == RegType.matchAll)
                return 1;
            ptrdiff_t ret = fn(input);
            if(optional && ret == -1)
                return 0;
            return ret;
        }
    }
    RegAlgo[] builtRegexMatch;
    int regIndex;



    static int delegate(string) inRange(char left, char right)
    {
        return (string input)
        {
            return (input[0] >= left && input[0] <= right) ? 1 : -1;
        };
    }

    static int delegate(string) getParenthesisHandling(string parenthesisExp)
    {
        import std.string:split;
        string[] references = parenthesisExp.split("|");
        return (string input)
        {
            foreach(r; references)
            {
                if(input == r)
                    return cast(int)input.length;
            }
            return -1;
        };
    }

    ptrdiff_t startCharIndex = -1;
    for(ptrdiff_t i = 0; i < rlike.length; i++)
    {
        char ch = rlike[i];
        if(ch == '^' || ch == '$') continue;
        if(startCharIndex == -1)
            startCharIndex = i;
        bool found = true;
        ptrdiff_t currI = i;
        switch(rlike[i])
        {
            case '.':
                builtRegexMatch~= RegAlgo(null, RegType.matchAll);
                break;
            case '*':
                enforce(builtRegexMatch.length > 0, "Can't start a mini regex with a greedy optional '*'"~rlike);
                builtRegexMatch[$-1].greedy = true;
                builtRegexMatch[$-1].optional = true;
                break;
            case '?':
                enforce(builtRegexMatch.length > 0, "Can't start a mini regex with a wildcard '?'"~rlike);
                enforce(!builtRegexMatch[$-1].optional, "Can't double set as optional (??) on mini regex "~rlike);
                builtRegexMatch[$-1].optional = true;
                break;
            case '[':
                ptrdiff_t n = indexOf(rlike, ']', i);
                enforce(n != -1, "End of range ']' not found on "~rlike);
                string[] splitted = split(rlike[i+1..n], '-');
                enforce(splitted.length == 2, "Range is not separated by a '-' at "~rlike);
                char left = splitted[0][0], right = splitted[1][0];

                enforce(right > left, "Can't create a range where right parameter '"~right~"' is not bigger than left '"~left~"'");

                builtRegexMatch~= RegAlgo(inRange(splitted[0][0], splitted[1][0]), RegType.range);
                i = n;
                break;
            case '(':
                ptrdiff_t n = indexOf(rlike, ')', i);
                enforce(n != -1, "End of multiple match character ')' not found on "~rlike);
                builtRegexMatch~= RegAlgo(getParenthesisHandling(rlike[i+1..n]), RegType.multiMatch);
                i = n;
                break;
            default:
                found = false;
                break;
        }
        if(found)
        {
            if(startCharIndex != currI)
            {
                RegAlgo temp = builtRegexMatch[$-1];
                builtRegexMatch[$-1] = RegAlgo(null, RegType.characters, rlike[startCharIndex..currI]);
                builtRegexMatch~= temp;
            }
            startCharIndex = -1;
        }
    }
    if(startCharIndex != -1 && startCharIndex < rlike.length)
        builtRegexMatch~=  RegAlgo(null, RegType.characters, rlike[startCharIndex..rlike.length]);


    int lastMatchStart = 0;
    for(int i = 0; i <= input.length; i++)
    {
        import std.stdio;
        string temp = input[lastMatchStart..i];
        RegAlgo a = builtRegexMatch[regIndex];
        if(a.characters && temp.length > a.characters.length)
            return false;

        if(a.greedy && a.type == RegType.matchAll && a.optional)
        {
            if(regIndex == builtRegexMatch.length - 1)
                return true;
            RegAlgo next = builtRegexMatch[regIndex+1];

            ptrdiff_t nextRes = -1;
            ptrdiff_t start = i;
            while(i < input.length && nextRes == -1)
            {
                i++;
                string futureInput = input[start..i];
                if(next.type == RegType.characters && futureInput.length > next.characters.length)
                    futureInput = input[++start..i];
                nextRes = next.matches(futureInput);
                // writeln("Testing ", futureInput, " against ", next.characters);
            }
            if(nextRes != -1)
            {
                // writeln("Matched:  ", next.characters, " curret  index ", i);
                regIndex+= 2;
                continue;
            }

        } 

        ptrdiff_t res = a.matches(temp);

        // writeln("Testing ", temp, " against ", builtRegexMatch[regIndex].type, ": ", res);
        if(res != -1)
        {
            lastMatchStart = i;
            regIndex++;
            if(regIndex == builtRegexMatch.length)
                return true;
        }
    }
    
    return regIndex == builtRegexMatch.length;
}

unittest
{
    assert(matches("default", "default"));
    assert(matches("wasm32-unknown-unknown", "^wasm(32|64)-"));
    assert(matches("i686-unknown-windows-msvc", "i[3-6]86-.*-windows-msvc"));
    assert(matches("arm-none-linux-gnueabihf", "arm.*-linux-gnueabihf"));

}