/// Command-line front end: reads perft/divide queries on stdin, prints answers.
module app.main;

import std.stdio : stdin, stdout;
import chessperft.query : answerLine;

int main()
{
    foreach (line; stdin.byLine)
    {
        if (line.length == 0)
            continue;
        stdout.write(answerLine(line));
    }
    return 0;
}
