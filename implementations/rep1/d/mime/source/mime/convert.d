/// The end-to-end conversion: a mailbox in, a dump directory out.
module mime.convert;

import std.file : mkdirRecurse, write;
import std.path : buildPath;

import mime.buffer;
import mime.mailbox;
import mime.message;
import mime.render;

/// Processes every message of the mailbox at `inputPath` and writes
/// `summary.txt`, `messages/NNNN.txt` and `parts/NNNN/PPP.bin` into
/// `outputDir`. Returns the number of messages.
size_t convertMailbox(string inputPath, string outputDir)
{
    auto mailbox = new Mailbox(inputPath);
    mkdirRecurse(buildPath(outputDir, "messages"));

    auto summary = ByteBuffer(4096);
    summary.put("messages ");
    summary.putUint(mailbox.length);
    summary.put('\n');

    auto dump = ByteBuffer(1 << 16);
    foreach (i; 0 .. mailbox.length)
    {
        immutable number = i + 1;
        auto raw = mailbox[i];
        auto msg = parseMessage(raw.data);

        dump.clear();
        renderMessage(dump, number, raw.sourceId, msg);
        write(buildPath(outputDir, "messages", fileNumber(number) ~ ".txt"), dump.data);

        if (msg.attachments.length > 0)
        {
            immutable dir = buildPath(outputDir, "parts", fileNumber(number));
            mkdirRecurse(dir);
            foreach (idx; msg.attachments)
                write(buildPath(dir, fileNumber(idx, 3) ~ ".bin"), msg.parts[idx].content);
        }
        putSummaryLine(summary, number, raw.sourceId, raw.data.length, msg);
    }
    write(buildPath(outputDir, "summary.txt"), summary.data);
    return mailbox.length;
}

private string fileNumber(size_t n, uint width = 4)
{
    auto b = ByteBuffer(8);
    b.putUint(n, width);
    return b.toString();
}
