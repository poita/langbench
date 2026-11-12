import struct

import pytest

from tessera import Database, crc32, run_script
from tessera.wal import LOG_HEADER, Wal, encode_record, recover

from helpers import check_database


def test_log_header_is_the_spec_constant():
    assert LOG_HEADER.hex() == "5445535357414c31000104000000000000000000000000000000000051e72153"


def test_record_headers_of_the_first_commit():
    db = Database.open()
    db.put("a", 1)
    log = db.wal_image()
    assert len(log) == 2152
    assert log[32:56].hex() == "01000000000000000000000100000001" "0000040076292e36"
    assert log[1080:1104].hex() == "01000000000000000000000100000002" "000004007 60d60f7".replace(" ", "")
    assert log[2128:2152].hex() == "02000000000000000000000100000002" "00000000a8a0aa22"


def test_encode_record_crc():
    rec = encode_record(2, 1, 2)
    assert rec[:20] == struct.pack(">B3xQII", 2, 1, 2, 0)
    assert struct.unpack(">I", rec[20:])[0] == crc32(rec[:20])


def build(commands: str):
    db = Database.open()
    run_script(db, commands)
    return db.wal_image(), db


def test_every_cut_of_a_log_keeps_exactly_the_complete_transactions():
    full, _ = build('put "a" 1\nput "b" 2\nput "c" [1,2,3]\n')
    ends = [32, 2152, 4272, 6392]      # transaction boundaries (two frames each)
    assert len(full) == ends[-1]
    fresh = Database.open().db_image()
    for cut in range(0, len(full) + 1):
        db = Database.open(fresh, full[:cut])
        expected_end = max((e for e in ends if e <= cut), default=32)
        assert db.wal_image() == (full[:expected_end] if cut >= 32 else LOG_HEADER)
        assert len(db) == ends.index(expected_end)
        assert db.db_image() == fresh                    # recovery never touches the main file
        if cut % 97 == 0:
            check_database(db)


def test_damaged_headers_discard_the_whole_log():
    full, _ = build('put "a" 1\n')
    for bad in [b"", b"x" * 10, b"y" * 10000, b"TESSWAL2" + full[8:], full[:28] + b"\0\0\0\0" + full[32:],
                full[:12] + b"\1" + full[13:]]:
        wal, overlay = recover(bad)
        assert wal.to_bytes() == LOG_HEADER and not overlay
    assert not recover(None)[1]


def test_later_page_image_wins_and_garbage_is_dropped():
    img = bytes([7]) * 1024
    img2 = bytes([9]) * 1024
    log = (LOG_HEADER + encode_record(1, 5, 4, img) + encode_record(1, 5, 4, img2)
           + encode_record(2, 5, 2))
    wal, overlay = recover(log + b"garbage")
    assert overlay == {4: img2}
    assert wal.to_bytes() == log


@pytest.mark.parametrize("records", [
    # frame count disagrees with the group
    [(1, 1, 2, bytes(1024)), (2, 1, 2, b"")],
    # commit with no group open
    [(2, 1, 1, b"")],
    # an image of another transaction interrupts the open group
    [(1, 1, 2, bytes(1024)), (1, 2, 3, bytes(1024)), (2, 2, 1, b"")],
    # page 0 does not exist
    [(1, 1, 0, bytes(1024)), (2, 1, 1, b"")],
])
def test_scan_stops_at_malformed_groups(records):
    log = LOG_HEADER + b"".join(encode_record(*r) for r in records)
    wal, overlay = recover(log)
    assert overlay == {} and wal.to_bytes() == LOG_HEADER


def test_nonzero_padding_and_bad_crc_stop_the_scan():
    good = LOG_HEADER + encode_record(1, 1, 2, bytes(1024)) + encode_record(2, 1, 1)
    bad_pad = bytearray(good)
    bad_pad[33] = 1
    assert recover(bytes(bad_pad))[1] == {}
    bad_crc = bytearray(good)
    bad_crc[-1] ^= 1
    assert recover(bytes(bad_crc))[1] == {}
    assert recover(good)[1] == {2: bytes(1024)}


def test_wal_size_accounting():
    wal = Wal()
    wal.append(1, [(1, bytes(1024)), (2, bytes(1024))])
    assert wal.size == 32 + 2 * 1048 + 24 == len(wal.to_bytes())
    wal.reset()
    assert wal.size == 32 and wal.to_bytes() == LOG_HEADER
