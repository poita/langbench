/// Entry point of the `datalog` command-line tool.
module app;

import datalog.cli : runCli;

int main(string[] args)
{
    return runCli(args);
}
