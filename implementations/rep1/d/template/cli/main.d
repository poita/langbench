/// Command-line tool: reads a JSON context and templates on stdin, prints the render.
module main;

import std.stdio : File, stderr, stdin, stdout;
import jinjalite;

int main()
{
    // Read all of stdin.
    char[] buffer;
    foreach (chunk; stdin.byChunk(1 << 16))
        buffer ~= cast(const(char)[]) chunk;
    const input = cast(string) buffer;

    string output;
    try
    {
        auto doc = parseDocument(input);
        auto env = new Environment;
        foreach (name; doc.names)
            env.addTemplate(name, doc.bodies[name]);
        output = env.render(doc.names[0], doc.context) ~ "\n";
    }
    catch (TemplateError e)
    {
        stderr.writeln(e.msg);
        output = "error: " ~ kindName(e.kind) ~ "\n";
    }
    catch (DocumentException e)
    {
        // Malformed input is not part of the language; report it as a syntax error.
        stderr.writeln(e.msg);
        output = "error: syntax\n";
    }
    stdout.rawWrite(output);
    return 0;
}
