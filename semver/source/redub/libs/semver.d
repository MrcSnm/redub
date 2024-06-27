module redub.libs.semver;
import redub.libs.version_parser;

import std.typecons;
import std.conv:to;


struct SemVer 
{
    private struct RawVersion
    {
        nint major;
        nint minor;
        nint patch;

        this(int M){major = M;}
        this(int M, int m){major = M; minor = m;}
        this(int M, int m, int p){major = M; minor = m; patch = p;}
        this(nint M){major = M;}
        this(nint M, nint m){major = M; minor = m;}
        this(nint M, nint m, nint p){major = M; minor = m; patch = p;}
       

        ComparisonResult[3] compare(const RawVersion other) const @nogc nothrow
        {
            return [cmp(major, other.major), cmp(minor, other.minor), cmp(patch, other.patch)];
        }

        ComparisonResult compareAtOnce(const RawVersion other) const @nogc nothrow
        {
            if(major != other.major) return cmp(major, other.major);
            if(minor != other.minor) return cmp(minor, other.minor);
            return cmp(patch, other.patch);
        }

        int opCmp(const RawVersion other) const @nogc nothrow
        {
            switch(compareAtOnce(other))
            {
                case ComparisonResult.greaterThan: return 1;
                case ComparisonResult.lessThan: return -1;
                case ComparisonResult.equal: return 0;
                default: assert(false, "Invalid value received");
            }
        }

        string toString() const
        {
            import std.conv;
            if(major.isNull) return null;
            if(minor.isNull) return major.get.to!string;
            
            auto majChars = major.get.toChars;
            auto minChars = minor.get.toChars;
            char[] ret;
            size_t length = majChars.length+minChars.length+1;
            typeof(toChars(patch.get)) patChars;
            
            if(!patch.isNull)
            {
                patChars = patch.get.toChars;
            	length+= 1+patChars.length;
            }
            ret = new char[](length);
            int i = 0;
            foreach(v; majChars) ret[i++] = v;
            ret[i++] = '.';
            foreach(v; minChars) ret[i++] = v;
            if(!patch.isNull)
            {
                ret[i++] = '.';
                foreach(v; patChars) ret[i++] = v;
            }
            return cast(string)ret;
        }

    }

    RawVersion ver;
    ComparisonResult[3] comparison = ComparisonTypes.mustBeEqual;
    private string versionStringRepresentation;
    private 
    {
        string buildPart;
        string metadata;
        bool invalid;
        string error;
    }


    this(nint M){ver = RawVersion(M);}
    this(nint M, nint m){ver = RawVersion(M, m);}
    this(nint M, nint m, nint p){ver = RawVersion(M, m, p);}

    this(int M){ver = RawVersion(M);}
    this(int M, int m){ver = RawVersion(M, m);}
    this(int M, int m, int p){ver = RawVersion(M, m, p);}

    private bool isUsingRange;
    private string rangeMax;

    this(string v) 
    {
        import std.string;
        import std.ascii:isDigit;
        import std.algorithm.searching;
        if(v == null) v = "*";
        versionStringRepresentation = v;
        v = strip(v);

        
        ///Take modifiers out (operators), e.g: ['*', '>=', '<=', '>', '<', '=', '~']
        ptrdiff_t modifierSeparator = v.indexOfFirstMatching(c => isDigit(c));
        string op;
        if(modifierSeparator != 0)
        {
            if(modifierSeparator == -1)
                op = v, v = null;
            else
            {
                op = strip(v[0..modifierSeparator]);
                v = strip(v[modifierSeparator..$]);
            }
        }
        ptrdiff_t afterVer;
        nint[3] versions = parseVersion(v, afterVer);
        if(op.length && !parseOperator(this, op, versionsCount(versions)))
        {
            setInvalid("Invalid operator");
            return;
        }
        if(versions[0].isNull) comparison[0] = ComparisonResult.any;
        if(versions[1].isNull) comparison[1] = ComparisonResult.any;
        if(versions[2].isNull) comparison[2] = ComparisonResult.any;
        ver = RawVersion(versions[0], versions[1], versions[2]);
        v = v[afterVer..$];

        //Take out build part, e.g: 1.9.2-alpha
        if(v.length > 0 && v[0] == '-')
        {
            ptrdiff_t lastIndex = std.string.indexOfAny(v, [' ', '<', '>', '+', '=']);
            if(lastIndex == -1)
                lastIndex = v.length;
            buildPart = v[1..lastIndex];
            v = v[lastIndex..$];
        }
        
        ///Take metadata out, e.g: 1.9.2+some_data
        if(v.length > 0 && v[0] == '+')
        {
            ptrdiff_t lastIndex = std.string.indexOfAny(v, [' ', '<', '>', '=']);
            if(lastIndex == -1)
                lastIndex = v.length;
            metadata = v[1..lastIndex];
            v = v[lastIndex..$];
        }


        
        ///Take ranges out, e.g: '>=1.9.2 < 2.0.0'
        ptrdiff_t rangesSeparator = v.indexOfFirstMatching(c => !isDigit(c) && c != '.' && c != '*' && c != 'x');
        if(rangesSeparator != -1)
        {
            isUsingRange = true;
            rangeMax = v[rangesSeparator..$];
            v = v[0..rangesSeparator];
        }
    }

    /** 
     * 
     * Params:
     *   ver = Just a string representation
     * Returns: A SemVer that can match anything.
     */
    static SemVer matchAll(string ver)
    {
        SemVer ret = SemVer(ver);
        ret.comparison = ComparisonTypes.any;
        return ret;
    }
    
    bool isInvalid(){return invalid;}
    private void setInvalid(string errMessage)
    {
        error = errMessage;
        invalid = true;
    }
    string getErrorMessage() const { return error; }
    string getMetadata() const {return metadata;}


    int opCmp(const SemVer other) const
    {
        return ver.opCmp(other.ver);
    }

    bool satisfies(const SemVer requirement) const 
    {
        if(comparison == ComparisonTypes.any) return true;
        if(invalid) return false;

        if(requirement.isUsingRange)
        {
            SemVer copy = cast()requirement;
            copy.isUsingRange = false;
            return this.satisfies(copy) && this.satisfies(SemVer(requirement.rangeMax));
        }

        if(requirement.comparison[0] == ComparisonResult.atOnce)
            return (requirement.comparison[1] & ver.compareAtOnce(requirement.ver)) != 0;
        else if(requirement.comparison[1] == ComparisonResult.atOnce)
        {
            SemVer thisMinPatch = SemVer(ver.minor, ver.patch);
            SemVer reqMinPatch = SemVer(requirement.ver.minor, requirement.ver.patch);

            bool[3] res = cmp(requirement.comparison, ver.compare(requirement.ver));
            return res[0] && (requirement.comparison[2] & thisMinPatch.ver.compareAtOnce(reqMinPatch.ver)) != 0;
        }
        return cmp(requirement.comparison, ver.compare(requirement.ver)) == [true, true, true];
    }

    string toString() const @safe pure nothrow
    {
        return versionStringRepresentation;
    }
}



private alias cr = ComparisonResult;
enum ComparisonTypes : ComparisonResult[3] 
{
    /// Implementation when directly specified version, or `=` is used.
    mustBeEqual = [cr.equal, cr.equal, cr.equal],
    /// Implementation when using `~`
    greaterPatchesOnly = [cr.equal, cr.equal, cr.gtEqual],
    /// Implementation when using `*`
    any = [cr.any, cr.any, cr.any],
}


private alias indexOfFirstMatchingDg = @nogc nothrow bool function(char);
private ptrdiff_t indexOfFirstMatching(string str, scope indexOfFirstMatchingDg cmp) @nogc nothrow
{
    foreach(i; 0..str.length)
        if(cmp(str[i])) return i;
    return -1;
}

/** 
 * Operator `-` not included since it can't be described as a a ComparisonType
 * Params:
 *   sv = Semver which will be populated
 *   op = Semver which will be populated
 */
private bool parseOperator(ref SemVer sv, string op, size_t partsLength) @nogc nothrow
{
    switch(op) with(ComparisonResult)
    {
        case "*":  sv.comparison = [any, any, any]; break;
        case "=", "==":  
            sv.comparison = [equal, equal, equal]; break;
        case "^":  sv.comparison = [equal, atOnce, gtEqual];  break;
        case "~", "~>":  
            if(partsLength <= 2)
                sv.comparison = [equal, atOnce, gtEqual];
            else
                sv.comparison = [equal, equal, gtEqual]; 
            break;
        case ">":  sv.comparison = [atOnce, greaterThan, greaterThan]; break;
        case ">=": sv.comparison = [atOnce, gtEqual, gtEqual]; break;
        case "<":  sv.comparison = [atOnce, lessThan, lessThan]; break;
        case "<=": sv.comparison = [atOnce, ltEqual, ltEqual]; break;
        default: return false;
    }
    return true;
}

enum ComparisonResult
{
    invalid,
    lessThan    = 1 << 0,
    greaterThan = 1 << 1,
    equal       = 1 << 2,
    gtEqual     = greaterThan | equal,
    ltEqual     = lessThan | equal,
    any         = lessThan | greaterThan | equal,
    atOnce      = 1 << 31
}

private bool[3] cmp(const ComparisonResult[3] a, const ComparisonResult[3] b) @nogc nothrow
{
    bool[3] ret;
    foreach(i; 0..a.length)
        ret[i] = (a[i] & b[i]) != 0;
    return ret;
}

private ComparisonResult cmp(inout nint a, inout nint b) @nogc nothrow
{
    with(ComparisonResult)
    {
        if(a.isNull && b.isNull) return equal;
        if(a.isNull) return lessThan;
        if(b.isNull) return greaterThan;
        return cmp(a.get, b.get);
    }
}

private ComparisonResult cmp(int a, int b) @nogc nothrow
{
    with(ComparisonResult)
    {
        if(a > b) return greaterThan;
        if(a < b) return lessThan;
        return equal;
    }
}


@("Compare Equal Versions")
unittest
{
    SemVer a = SemVer("=1.2.3");
    assert(SemVer("1.2.3").satisfies(a));
    assert(!SemVer("1.2.4").satisfies(a));
}

@("Compare Using ~")
unittest 
{
    SemVer gtPatches = SemVer("~1.2.3");

    assert(SemVer("1.2.3").satisfies(gtPatches));
    assert(SemVer("1.2.4").satisfies(gtPatches));
    assert(!SemVer("1.2.2").satisfies(gtPatches));
    assert(SemVer("1.2.10").satisfies(gtPatches));
    assert(!SemVer("1.0.10").satisfies(gtPatches));

    assert(!SemVer("0.10.0").satisfies(SemVer("~>0.9.0")));

    // assert(SemVer("~5").satisfies("5.0.0"));
}

@("Compare Using Metadata")
unittest
{
    string meta = "anything.is.accepted.here!";
    SemVer a = SemVer("1.2.3+"~meta);
    assert(SemVer("1.2.3").satisfies(a));
    assert(a.getMetadata == meta);
}

@("Compare using build part")
unittest
{
    SemVer a = SemVer("1.2.3-beta1");
    assert(SemVer("1.2.3").satisfies(a));
}

@("Compare Using ^")
unittest
{
    SemVer a = SemVer("^1.2.3");
    assert(!a.isInvalid);
    assert(SemVer("1.9.9").satisfies(a));
}

@("Compare using *")
unittest
{
    SemVer a = SemVer("*");
    assert(SemVer("*").satisfies(a));
    assert(SemVer("9.9.9").satisfies(a));
    assert(SemVer("15.50.109").satisfies(a));

    assert(SemVer("1.55.9").satisfies(SemVer("1.*.9")));
    assert(SemVer("*.*.9").isInvalid);
    assert(SemVer("99.55.9").satisfies(SemVer("*")));
}

@("Compare using <")
unittest
{
    assert(!SemVer("0.10.0").satisfies(SemVer("<0.10.0")));
    assert(SemVer("2.0.5").satisfies(SemVer("<3.0.0")));
}

@("Compare using >")
unittest
{
    assert(SemVer("0.10.1").satisfies(SemVer(">0.10.0")));
}

@("Compare using Ranges")
unittest
{
    assert(SemVer("2.0.5").satisfies(SemVer(">=2.0.5 < 3.0.0")));
    assert(!SemVer("0.10.0").satisfies(SemVer(">=0.9.7-alpha.3 < 0.10.0")));
    assert(SemVer("0.9.8").satisfies(SemVer(">=0.9.0 <0.10.0")));
}