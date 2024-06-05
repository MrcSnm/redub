module redub.misc.match_glob;

/** 
 * Supports * and ? on glob.
 * Params:
 *   input = The input to be tested
 *   glob = The glob comparison
 * Returns: If it matches the glob
 */
bool matchesGlob(string input, string glob)
{
    if(glob.length == 0) return false;
    if(glob == "*") return true;


    int globIndex = 0;
    for(int i = 0; i < input.length; i++)
    {
        switch(glob[globIndex])
        {
            case '*':
                if(globIndex + 1 == glob.length)
                    return true;
                char nextControlCharacter = glob[globIndex+1];
                if(nextControlCharacter == '?')
                {
                    globIndex++;
                    continue;
                }
                while(i < input.length)
                {
                    if(input[i] == nextControlCharacter)
                    {
                        ///The loop will jump to the next character.
                        i--;
                        break;
                    }
                    i++;
                }
                if(i == input.length)
                    return false;
                break;
            case '?':
                break;
            default:
                if(input[i] != glob[globIndex])
                    return false;
                break;
        }
        globIndex++;
    }
    return true;
}

unittest
{
    assert("source/app.d".matchesGlob("*.d"));
    assert("source/app_v1.d".matchesGlob("*app_v?.d"));
}