/// The `render.txt` job list and directory-level driver.
module svgraster.batch;

import std.conv : to;
import std.file : exists, isDir, mkdirRecurse, read, write;
import std.path : buildPath;
import svgraster.parse : isSpace;
import svgraster.render;
import svgraster.xml : parseXml;

/// One line of `render.txt`: render `name` at `width` x `height`.
struct Job
{
    /// File name in the input directory (ends in `.svg`).
    string name;
    /// Output width in pixels.
    int width;
    /// Output height in pixels.
    int height;

    /// The output file name: `name` without `.svg`, plus `.ppm`.
    string outputName() const pure nothrow @safe
    {
        auto stem = name.length >= 4 && name[$ - 4 .. $] == ".svg" ? name[0 .. $ - 4] : name;
        return stem ~ ".ppm";
    }
}

/// Parse the text of a `render.txt` file. Blank lines and `#` comments are
/// skipped; lines that do not have exactly three valid fields are ignored.
Job[] parseJobs(string text) pure @safe
{
    Job[] jobs;
    size_t i = 0;
    while (i <= text.length)
    {
        size_t j = i;
        while (j < text.length && text[j] != '\n')
            ++j;
        auto line = text[i .. j];
        i = j + 1;
        if (line.length && line[$ - 1] == '\r')
            line = line[0 .. $ - 1];
        string[3] f;
        size_t nf = 0;
        size_t p = 0;
        bool extra = false;
        while (true)
        {
            while (p < line.length && isSpace(line[p]))
                ++p;
            if (p >= line.length)
                break;
            size_t q = p;
            while (q < line.length && !isSpace(line[q]))
                ++q;
            if (nf == 0 && line[p] == '#')
                break;
            if (nf < 3)
                f[nf] = line[p .. q];
            else
                extra = true;
            ++nf;
            p = q;
        }
        if (nf == 3 && !extra)
        {
            int w, h;
            if (parseDim(f[1], w) && parseDim(f[2], h))
                jobs ~= Job(f[0], w, h);
        }
    }
    return jobs;
}

private bool parseDim(string s, out int v) pure nothrow @safe
{
    if (s.length == 0 || s.length > 9)
        return false;
    int r = 0;
    foreach (c; s)
    {
        if (c < '0' || c > '9')
            return false;
        r = r * 10 + (c - '0');
    }
    v = r;
    return r >= 1;
}

/// Render every job listed in `<inputDir>/render.txt` into `outputDir`.
/// Returns the names of jobs that could not be rendered (unreadable input).
string[] renderDirectory(string inputDir, string outputDir)
{
    auto listText = cast(string) read(buildPath(inputDir, "render.txt"));
    auto jobs = parseJobs(listText);
    if (!exists(outputDir))
        mkdirRecurse(outputDir);
    auto renderer = new Renderer;
    string[] failed;
    foreach (job; jobs)
    {
        string src;
        try
            src = cast(string) read(buildPath(inputDir, job.name));
        catch (Exception)
        {
            failed ~= job.name;
            continue;
        }
        auto img = renderer.render(parseXml(src), job.width, job.height);
        write(buildPath(outputDir, job.outputName), img.toPpm());
    }
    return failed;
}
