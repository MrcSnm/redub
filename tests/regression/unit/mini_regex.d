module mini_regex_test;
import std.stdio;
import redub.misc.mini_regex;

void main()
{
    assert(matches("x86_64-unknown-linux-gnu", ".*linux"));
    assert(matches("wasm32-unknown-unknown", "^wasm(32|64)-"));
    assert(matches("", "^$"));
    assert(!matches("x", "^$"));
    assert(matches("1abc", "[0-9].*"));
    writeln("PASS");
}
