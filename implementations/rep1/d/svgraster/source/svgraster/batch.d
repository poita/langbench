/// Batch rendering driven by a `render.txt` job list.
module svgraster.batch;

import std.algorithm : endsWith;
import std.array : split;
import std.conv : to, ConvException;
import std.file : exists, mkdirRecurse, read, write;
import std.path : buildPath;
import std.string : strip;
import svgraster.render;

/// One line of `render.txt`.
struct Job
{
    /// SVG file name relative to the input directory.
    string name;
    /// Output size in pixels.
    int width, height;

    /// Output file name: `name` without its `.svg` suffix plus `.ppm`.
    string outputName() const
    {
        return (name.endsWith(".svg") ? name[0 .. $ - 4] : name) ~ ".ppm";
    }
}

/// Parse the text of a `render.txt`: `NAME WIDTH HEIGHT` per line; blank lines
/// and lines starting (after spaces) with `#` are ignored.
/// Throws: `Exception` for a malformed line.
Job[] parseJobList(string text)
{
    Job[] jobs;
    foreach (raw; text.split('\n'))
    {
        auto line = raw.strip;
        if (line.length == 0 || line[0] == '#')
            continue;
        auto fields = line.split;
        if (fields.length != 3)
            throw new Exception("malformed render.txt line: " ~ line);
        try
            jobs ~= Job(fields[0], fields[1].to!int, fields[2].to!int);
        catch (ConvException)
            throw new Exception("malformed render.txt line: " ~ line);
        if (jobs[$ - 1].width < 1 || jobs[$ - 1].height < 1)
            throw new Exception("invalid size in render.txt line: " ~ line);
    }
    return jobs;
}

/// Render every job named in `<inputDir>/render.txt` into `outputDir`.
/// Returns: the number of jobs that failed (their errors are reported through
/// `onError`).
int renderDirectory(string inputDir, string outputDir, void delegate(string) onError)
{
    immutable text = cast(string) read(buildPath(inputDir, "render.txt"));
    auto jobs = parseJobList(text);
    mkdirRecurse(outputDir);
    int failures = 0;
    foreach (job; jobs)
    {
        try
        {
            immutable src = cast(string) read(buildPath(inputDir, job.name));
            auto canvas = renderSvg(src, job.width, job.height);
            write(buildPath(outputDir, job.outputName), canvas.toPpm());
        }
        catch (Exception e)
        {
            ++failures;
            onError(job.name ~ ": " ~ e.msg);
        }
    }
    return failures;
}

unittest
{
    auto jobs = parseJobList("# comment\n\n  # indented\nlogo.svg 64 32\r\nb.svg\t5   6\n");
    assert(jobs.length == 2);
    assert(jobs[0] == Job("logo.svg", 64, 32) && jobs[0].outputName == "logo.ppm");
    assert(jobs[1] == Job("b.svg", 5, 6));
    import std.exception : assertThrown;

    assertThrown(parseJobList("a.svg 10"));
    assertThrown(parseJobList("a.svg 0 10"));
}

unittest
{
    import std.file : tempDir, rmdirRecurse, mkdirRecurse, write, read;
    import std.path : buildPath;
    import std.process : thisProcessID;

    immutable base = buildPath(tempDir, "svgraster-batch-" ~ thisProcessID.to!string);
    scope (exit)
        rmdirRecurse(base);
    mkdirRecurse(buildPath(base, "in"));
    write(buildPath(base, "in", "render.txt"), "a.svg 4 2\nmissing.svg 1 1\n");
    write(buildPath(base, "in", "a.svg"), `<svg viewBox="0 0 4 2"><rect width="4" height="2" fill="#000"/></svg>`);
    string[] errors;
    immutable failed = renderDirectory(buildPath(base, "in"), buildPath(base, "out", "nested"),
            (string m) { errors ~= m; });
    assert(failed == 1 && errors.length == 1);
    const data = cast(const(ubyte)[]) read(buildPath(base, "out", "nested", "a.ppm"));
    assert(data.length == "P6\n4 2\n255\n".length + 24);
    assert(data[$ - 1] == 0);
}
