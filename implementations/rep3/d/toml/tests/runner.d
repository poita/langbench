/// Entry point for `dub test`: the D runtime runs every `unittest` block
/// before `main`, so there is nothing left to do here.
module tests.runner;

void main()
{
    import std.stdio : writeln;
    writeln("all unit tests passed");
}
