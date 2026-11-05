/// Entry point for the `unittest` configuration. `dub test` replaces it with
/// its own generated runner; building the configuration by hand uses this one.
module runner;

void main()
{
    import std.stdio : writeln;

    writeln("all unit tests passed");
}
