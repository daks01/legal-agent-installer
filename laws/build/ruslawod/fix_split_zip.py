#!/usr/bin/env python3
"""Превращает склеенный multi-disk zip (RusLawOD) в обычный single-disk zip.

RusLawOD публикует split-zip (z01..z04 + .zip), где:
  * центральный каталог начинается внутри z04 и продолжается в .zip;
  * смещения локальных заголовков у дисков > 0 хранятся ОТНОСИТЕЛЬНО начала
    своего диска (по 300 МиБ), а не от начала архива;
  * EOCD/ZIP64 EOCD содержат ненулевые номера дисков.

Python zipfile такие архивы не читает ("zipfiles that span multiple disks are
not supported"), info-zip 7z — не у всех. Скрипт копирует архив и патчит:
  * у каждой записи каталога: offset -> абсолютный, disk -> 0;
  * ZIP64 EOCD: disk/cd_disk -> 0, cd_offset -> абсолютный;
  * классический EOCD: disk/cd_disk -> 0, cd_offset -> абсолютный.

Использование:
  python3 fix_split_zip.py <merged.zip> [--out fixed.zip] [--disk-size 314572800]
"""
from __future__ import annotations

import argparse
import shutil
import struct
import sys
import zipfile
from pathlib import Path

CD_SIG = b"PK\x01\x02"
Z64_SIG = b"PK\x06\x06"
EOCD_SIG = b"PK\x05\x06"


def find_signature(f, where_from: int, where_to: int, sig: bytes) -> int:
    """Ищет подпись sig в файле между where_from и where_to (с конца)."""
    chunk = 1 << 20
    pos = where_to
    while pos > where_from:
        start = max(where_from, pos - chunk)
        f.seek(start)
        buf = f.read(pos - start)
        idx = buf.rfind(sig)
        if idx >= 0:
            return start + idx
        pos = start
    return -1


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("archive", type=Path, help="склеенный multi-disk zip")
    ap.add_argument("--out", type=Path, default=None, help="куда писать (по умолчанию <архив>_single.zip)")
    ap.add_argument("--disk-size", type=int, default=314572800, help="размер одного диска (300 МиБ)")
    args = ap.parse_args()

    src: Path = args.archive
    dst: Path = args.out or src.with_name(src.stem + "_single.zip")
    size = src.stat().st_size

    if dst.exists():
        try:
            already = zipfile.is_zipfile(dst)
        except zipfile.BadZipFile:
            already = False
        if already:
            print(f"= {dst} уже существует и читается — пропускаю")
            return 0

    print(f"▸ Копирую {src.name} → {dst.name} ({size/1024/1024:.0f} МБ)…")
    shutil.copyfile(src, dst)

    with dst.open("r+b") as f:
        # --- найти EOCD и ZIP64 EOCD ---
        eocd_pos = find_signature(f, max(0, size - 65536), size, EOCD_SIG)
        if eocd_pos < 0:
            print("✗ не найден EOCD", file=sys.stderr)
            return 1
        z64_pos = find_signature(f, max(0, eocd_pos - 65536), eocd_pos, Z64_SIG)
        if z64_pos < 0:
            print("✗ не найден ZIP64 EOCD", file=sys.stderr)
            return 1

        f.seek(z64_pos)
        z = struct.unpack("<4sQHHLLQQQQ", f.read(56))
        n_total, cd_size, cd_off_decl, disk_no, cd_disk_no = z[7], z[8], z[9], z[4], z[5]
        cd_start = z64_pos - cd_size
        print(f"  ZIP64: записей={n_total}, cd@{cd_start}, дисков={disk_no+1}, cd_disk={cd_disk_no}")

        f.seek(cd_start)
        if f.read(4) != CD_SIG:
            print("✗ по вычисленному адресу нет начала каталога", file=sys.stderr)
            return 1

        # --- патчим записи каталога ---
        patched = 0
        f.seek(cd_start)
        for _ in range(n_total):
            entry_pos = f.tell()
            hdr = f.read(46)
            if len(hdr) < 46 or hdr[:4] != CD_SIG:
                print("✗ сломалась цепочка записей каталога", file=sys.stderr)
                return 1
            (_sig, _vm, _vn, _flags, _method, _mt, _md, _crc, csize, usize,
             nl, el, cl, dsk, _ia, _ea, off) = struct.unpack("<4s6H3L5H2L", hdr)
            name = f.read(nl)
            extra_pos = f.tell()
            extra = f.read(el)
            f.seek(cl, 1)
            next_pos = f.tell()

            z_off = z_dsk = None
            if el:
                b = 0
                while b + 4 <= len(extra):
                    hid, hsz = struct.unpack_from("<HH", extra, b)
                    b += 4
                    if hid == 1:
                        bb = b
                        if usize == 0xFFFFFFFF:
                            bb += 8
                        if csize == 0xFFFFFFFF:
                            bb += 8
                        if off == 0xFFFFFFFF:
                            z_off = struct.unpack_from("<Q", extra, bb)[0]
                            bb += 8
                        if dsk == 0xFFFF:
                            z_dsk = struct.unpack_from("<L", extra, bb)[0]
                        break
                    b += hsz

            eff_off = z_off if z_off is not None else off
            eff_dsk = z_dsk if z_dsk is not None else dsk
            if eff_dsk != 0 or eff_off != off:
                abs_off = eff_off + eff_dsk * args.disk_size
                # патчим disk (2 байта @34) и, если нужно, offset (4 байта @42)
                f.seek(entry_pos + 34)
                f.write(struct.pack("<H", 0))
                if z_off is None:
                    f.seek(entry_pos + 42)
                    f.write(struct.pack("<L", abs_off))
                else:
                    # правим zip64-extra: offset следует после usize/csize-полей
                    pos_in_extra = 4
                    if usize == 0xFFFFFFFF:
                        pos_in_extra += 8
                    if csize == 0xFFFFFFFF:
                        pos_in_extra += 8
                    f.seek(extra_pos + pos_in_extra)
                    f.write(struct.pack("<Q", abs_off))
                f.seek(next_pos)
                patched += 1

        # --- патчим ZIP64 EOCD (disk@16, cd_disk@20, cd_off@48) ---
        f.seek(z64_pos + 16)
        f.write(struct.pack("<L", 0))       # disk
        f.write(struct.pack("<L", 0))       # cd_disk
        f.seek(z64_pos + 48)
        f.write(struct.pack("<Q", cd_start))

        # --- патчим ZIP64 LOCATOR (disk@4, кол-во дисков@16) ---
        loc_pos = z64_pos + 56
        f.seek(loc_pos)
        if f.read(4) != b"PK\x06\x07":
            loc_pos = find_signature(f, z64_pos, min(z64_pos + 65536, size), b"PK\x06\x07")
            if loc_pos < 0:
                print("✗ не найден ZIP64 locator", file=sys.stderr)
                return 1
        f.seek(loc_pos + 4)
        f.write(struct.pack("<L", 0))       # disk с ZIP64 EOCD
        f.seek(loc_pos + 16)
        f.write(struct.pack("<L", 1))       # всего дисков

        # --- патчим классический EOCD (disk@4, cd_disk@6, cd_off@16) ---
        f.seek(eocd_pos + 4)
        f.write(struct.pack("<H", 0))
        f.write(struct.pack("<H", 0))
        f.seek(eocd_pos + 16)
        f.write(struct.pack("<L", cd_start))

    print(f"  записей с исправленным диском/смещением: {patched}")

    # --- проверка ---
    with zipfile.ZipFile(dst) as z:
        names = z.namelist()
        print(f"✓ читается как обычный zip: {len(names)} записей (пример: {names[1]})")
        data = z.read(names[1])
        print(f"✓ пробное чтение: {names[1]} — {len(data)} байт")
    return 0


if __name__ == "__main__":
    sys.exit(main())
